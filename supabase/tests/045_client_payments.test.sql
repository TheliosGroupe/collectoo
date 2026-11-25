-- M2c-7c-1 « client payments and refunds » (plan docs/design/m2c-7-plan.md §5.0–§5.2.6, §5.2.8, §5.7; design §7.3,
-- §12, §14.1, §16; ADR-0014 « M2c-7c-1 »). What a client pays the servicer, and what the servicer pays back:
--   cat   the books 419 « Mandants — sommes à leur rembourser » and 7714 « Rentrées sur avances passées en perte »
--         (Collectoo's labels: OQ-88, OQ-98) and the entry types that may touch them;
--   j     ([check 1] gap 2) the shapes: a payment wholly a credit (−419 only), a recovery (−7714, −4112 + −7714), the
--         refund of a client credit (+419 / −5122) post; a debit on 419, two 419 lines, both +4111 and +419 in a
--         refund are refused LG001 (7714 or 419 on another type LG002); the nightly identities client_credit_ledger and
--         written_off_recovery_ledger see a planted posting without its row;
--   p     record_client_payment (« Règlement du client », own account): roles and aal2, every refusal (review round 1:
--         no_own_account too), the default
--         order (a due invoice, an advance, an invoice not due), VAT moved pro rata and in full on the closing part,
--         the entry (+5122 / −4111 / −4112 / VAT pair; its document the evidence), the settlements, replay and a key
--         reused for another request, 4111 = open invoices and 4112 = open advances after (I18), the 7b guard;
--         (review round 4) a payment settles only what existed on its date: an invoice issued, an advance born or a
--         loss passed later is skipped by the default order (a credit owed back that day), refused bad_date if named;
--   p2    a named order with the client's designation; named documents in flight refused, skipped by the default
--         order; (switch on) a run cancelled after download no longer holds its documents;
--   b     ([critic] M7-MONEY-10) 365,00 € for 360,00 € open → 360,00 € settled and a credit owed back of 5,00 € (I9,
--         I18, I19 clean), client_credit_owed after 15 days, record_client_refund of the credit stops it; the export
--         balances and lists 419; a payment for an advance a run already took back → all of it a credit; a written-off
--         advance repaid → 7714 (advance_write_off_recovery), capped at what was written off;
--   l, c  ([check 1] gap 11, [critic] L21) a client in a proceeding: the default order skips the pre-opening invoice,
--         pays the post-opening one, holds the rest for the procedure (cause procedure, a P0 alert at once); a
--         designated pre-opening invoice is held for the procedure, the invoice still open, its P0 alert at once;
--         (review round 1, MONEY-1) a designated advance passed as a loss, born before the opening, the same: never
--         7714, on the own account and on the dedicated one; (review round 2) a liquidation recorded alone opens the
--         procedure as a proceeding_opened does (L641-3 al. 1): its pre-judgment invoice and advance skipped by the
--         default order, held for the procedure when designated (own and dedicated account), marked on the page;
--         (review round 3) its pre-judgment advance without a claw-back clause never said to be repaid
--         (barred_proceeding on every page and the nightly) — (M2c-7d-2) a claw-back clause no longer takes it either
--         (advance_recovery_of reads client_opening_date: barred_proceeding whatever the clause); a credit
--         dated by the money's receipt (its entry's value or booking date), its recording day apart;
--   k([check 1] gap 8) at most one client_credit per cause of a payment: two causes on one entry, a replay creates
--         none, a second row of a cause refused;
--   d, e  book_client_payment_line (the dedicated account): a client's credit (its confirmed IBAN; [critic]
--         M7-MONEY-12: a rejected proposal never attributes it; ambiguous_client), a label naming the invoice counts
--         as the designation ([critic] L16), the entry (+5120 / −4679 ‖ +4689 / −4111 / −419 ‖ VAT), its
--         bank_line_booking, the review gone, I9/I19 clean, the next file's sweep includes it; kinds refused (a
--         debtor's credit, an own credit, a line naming our transfer or our top-up), a line booked or linked;
--         (review round 4) a line booked before an invoice's issue never settles it (its label no designation then);
--   r     record_client_refund: a credit note's refund owed (credit_refund_owed stops), partial, in flight, refusals;
--         (review round 4) never dated before a credit's receipt or a credit note's issue (bad_date, that day);
--   o     client_open_documents and client_payment_preview: the page's read, staff only;
--   i     ([critic] F18) the new tables: RLS (the client's whole-client members read their credits; restricted
--         viewers, collectors, other tenants none; recoveries staff only), append-only, the change log; the client
--         space's credits; the evidence kinds (client_payment_evidence, client_refund_evidence,
--         payment_designation_evidence) registered by money staff, read — row and file — by money staff only;
--   x     the full list of codes run_advance_checks emits (043 #33 / 044 h F12 extended by 7c-1's three).
-- The cancellation-after-download switch stays off: its case (p2) runs in its own rolled-back scenario with it on
-- (pg_temp.iso(…, true)); a guard at the end checks it is off.
begin;
select plan(32);

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


-- cat. The books and the types (§5.0 (1), (2)) --------------------------------------------------------------------------
select is((select jsonb_agg(jsonb_build_array(b.code, b.account_number, b.label_fr, b.dimension, b.money_of, b.normal_side,
                                              b.client_visible) order by b.code)
           from public.ledger_book b where b.code in ('client_credit_owed', 'written_off_recovered')),
  '[["client_credit_owed", "419", "Mandants — sommes à leur rembourser", "client", "servicer", -1, false],
    ["written_off_recovered", "7714", "Rentrées sur avances passées en perte", "pooled", "servicer", -1, false]]'::jsonb,
  'cat: two books of the servicer''s fund, 419 per client and 7714 pooled, neither client-visible (Collectoo''s labels)');
select is((select jsonb_object_agg(t.code, jsonb_build_array('client_credit_owed' = any (t.allowed_books),
                                                             'written_off_recovered' = any (t.allowed_books)))
           from public.ledger_entry_type t
           where 'client_credit_owed' = any (t.allowed_books) or 'written_off_recovered' = any (t.allowed_books)),
  '{"client_payment_own": [true, true], "client_payment_dedicated": [true, true],
    "client_refund_own": [true, false]}'::jsonb,
  'cat: only the two client payments may post 419 and 7714, the refund 419');


-- j. The shapes (§5.0 (3)–(5), [check 1] gap 2) ---------------------------------------------------------------------------
create or replace function pg_temp.sj() returns jsonb language plpgsql as $$
declare w jsonb;
begin
  w := jsonb_build_object(
    'credit_only', pg_temp.post('client_payment_own', 'j1', '[["own_cash", 500], ["client_credit_owed", -500]]'),
    'recovery_only', pg_temp.post('client_payment_own', 'j2',
                                  '[["own_cash", 700], ["written_off_recovered", -700]]'),
    'advance_and_recovery', pg_temp.post('client_payment_own', 'j3',
      '[["own_cash", 900], ["client_advance_receivable", -400], ["written_off_recovered", -500]]'),
    'all_five', pg_temp.post('client_payment_own', 'j4',
      '[["own_cash", 1500], ["commission_receivable", -600], ["client_advance_receivable", -400],
        ["client_credit_owed", -300], ["written_off_recovered", -200], ["vat_pending", 100], ["vat_collected", -100]]'),
    'dedicated_credit_only', pg_temp.post('client_payment_dedicated', 'j5',
      '[["client_money_cash", 500], ["due_to_servicer", -500], ["due_from_client_funds", 500],
        ["client_credit_owed", -500]]'),
    'refund_of_a_credit', pg_temp.post('client_refund_own', 'j6', '[["client_credit_owed", 300], ["own_cash", -300]]'),
    'refund_of_a_credit_note', pg_temp.post('client_refund_own', 'j7',
                                            '[["commission_receivable", 300], ["own_cash", -300]]'),
    -- malformed
    'debit_on_419', pg_temp.post('client_payment_own', 'j8',
      '[["own_cash", 500], ["client_credit_owed", 100], ["commission_receivable", -600]]'),
    'two_419_lines', pg_temp.post('client_payment_own', 'j9',
      '[["own_cash", 500], ["client_credit_owed", -200], ["client_credit_owed", -300]]'),
    'debit_on_7714', pg_temp.post('client_payment_own', 'j10',
      '[["own_cash", 500], ["written_off_recovered", 100], ["commission_receivable", -600]]'),
    'two_7714_lines', pg_temp.post('client_payment_own', 'j11',
      '[["own_cash", 500], ["written_off_recovered", -200], ["written_off_recovered", -300]]'),
    'refund_both', pg_temp.post('client_refund_own', 'j12',
      '[["commission_receivable", 100], ["client_credit_owed", 200], ["own_cash", -300]]'),
    'refund_credit_side', pg_temp.post('client_refund_own', 'j13', '[["client_credit_owed", -300], ["own_cash", 300]]'),
    'refund_7714', pg_temp.post('client_refund_own', 'j14', '[["written_off_recovered", 300], ["own_cash", -300]]', null),
    'settlement_7714', pg_temp.post('client_settlement', 'j15',
      '[["client_payable", 500], ["due_to_servicer", -500], ["due_from_client_funds", 500],
        ["commission_receivable", -300], ["written_off_recovered", -200]]'),
    'write_off_419', pg_temp.post('advance_write_off', 'j16', '[["servicer_losses", 300], ["client_credit_owed", -300]]'),
    'no_client_line_419', pg_temp.post('client_payment_own', 'j17', '[["own_cash", 500], ["client_credit_owed", -500]]',
                                       null));
  -- a 419 posting and a 7714 posting planted without their rows: the nightly's identities see them
  perform pg_temp.plant('client_payment_own', 'j18', '[["own_cash", 500], ["client_credit_owed", -500]]');
  perform pg_temp.plant('client_payment_own', 'j19', '[["own_cash", 700], ["written_off_recovered", -700]]');
  return w || jsonb_build_object('nightly', pg_temp.cchecks(),
    'shape', (select jsonb_agg(jsonb_build_array(la.book, la.client_organization_id = pg_temp.c('a1'),
                                                 la.portfolio_id is null and la.bank_account_id is null)
                               order by la.book)
              from public.ledger_account la
              where la.organization_id = '00000000-0000-0000-0000-0000000000aa'
                and la.book in ('client_credit_owed', 'written_off_recovered')),
    'pooled_client', pg_temp.state($q$ insert into public.ledger_account (organization_id, book, currency,
                                         client_organization_id)
                                       values ('00000000-0000-0000-0000-0000000000aa', 'written_off_recovered', 'EUR',
                                               '00000000-0000-0000-0000-0000000000a1') $q$),
    'per_client_none', pg_temp.state($q$ insert into public.ledger_account (organization_id, book, currency)
                                         values ('00000000-0000-0000-0000-0000000000aa', 'client_credit_owed', 'EUR') $q$));
end $$;
select is(pg_temp.iso('sj'),
  '{"credit_only": "ok", "recovery_only": "ok", "advance_and_recovery": "ok", "all_five": "ok",
    "dedicated_credit_only": "ok", "refund_of_a_credit": "ok", "refund_of_a_credit_note": "ok",
    "debit_on_419": "LG001", "two_419_lines": "LG001", "debit_on_7714": "LG001", "two_7714_lines": "LG001",
    "refund_both": "LG001", "refund_credit_side": "LG001", "refund_7714": "LG002", "settlement_7714": "LG002",
    "write_off_419": "LG002", "no_client_line_419": "LG002",
    "nightly": [["client_credit_ledger", "violation", 500, null, null],
                ["written_off_recovery_ledger", "violation", 700, null, null]],
    "shape": [["client_credit_owed", true, true], ["written_off_recovered", null, true]],
    "pooled_client": "23514", "per_client_none": "23514"}'::jsonb,
  'j: a payment wholly a credit, a recovery, the refund of a client credit post; a debit on 419 or 7714, two lines on '
  'either, a refund with +4111 and +419 are refused (LG001); 7714 on a refund, a settlement or 419 on a write-off LG002; '
  '419 per client, 7714 pooled; a planted posting without its row seen by the nightly');


-- p. « Règlement du client » on the own account (§5.2.4) --------------------------------------------------------------
-- Martin: FC-1 (36 000 TTC, 6 000 VAT pending) due today, FC-2 (18 000, 3 000) due in 30 days, and an advance A (20 000,
-- born d − 2): the default order FC-1, A, FC-2
create or replace function pg_temp.martin() returns jsonb language plpgsql as $$
declare v_f1 uuid; v_f2 uuid; a public.client_advance;
begin
  v_f1 := pg_temp.inv('a1', '20', 200000, '201');
  perform pg_temp.due(v_f1, private.paris_today());
  v_f2 := pg_temp.inv('a1', '21', 100000, '211');
  a := pg_temp.adv('a1', '22', 20000, '221');
  return jsonb_build_object('f1', v_f1, 'f2', v_f2, 'a', a.id);
end $$;
create or replace function pg_temp.sp() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.martin(); v_f1 uuid := (m ->> 'f1')::uuid; v_f2 uuid := (m ->> 'f2')::uuid;
        v_a uuid := (m ->> 'a')::uuid; d date := private.paris_today(); w jsonb; r jsonb; v_e uuid;
        v_lilas uuid;
begin
  v_lilas := pg_temp.inv('a2', '23', 100000, '231');
  w := jsonb_build_object(
    'collector', pg_temp.cpay('p1', 'a1', '10,00', p_user => '02') ->> 'error',
    'aal1', pg_temp.cpay('p2', 'a1', '10,00', p_aal => 'aal1') ->> 'error',
    'other_servicer', pg_temp.cpay('p3', 'a1', '10,00', p_user => '05') ->> 'error',
    'bad', jsonb_build_array(pg_temp.cpay('p4', 'a1', 'abc') ->> 'error', pg_temp.cpay('p5', 'a1', '0') ->> 'error',
                             pg_temp.cpay('p6', 'a1', '1,234') ->> 'error', pg_temp.cpay('p7', 'a1', '-5') ->> 'error'),
    'future', pg_temp.cpay('p8', 'a1', '10,00', d + 1, p_expected => '74000') ->> 'error',
    'bad_request', pg_temp.cpay('p9', 'a1', '10,00', p_expected => 'x') ->> 'error',
    'no_evidence', pg_temp.cpay('p10', 'a1', '10,00', p_ev => 'none') ->> 'error',
    'wrong_kind', pg_temp.cpay('p11', 'a1', '10,00', p_ev => pg_temp.ev('6', 'a1')::text) ->> 'error',
    'other_client', pg_temp.cpay('p12', 'a1', '10,00', p_ev => pg_temp.ev('5', 'a2')::text) ->> 'error',
    'no_designation', pg_temp.cpay('p13', 'a1', '10,00', p_docs => array[v_f2]) ->> 'error',
    'designation_of_another', pg_temp.cpay('p14', 'a1', '10,00', p_docs => array[v_f2],
                                           p_desig => pg_temp.ev('7', 'a2')) ->> 'error',
    'recovery_undesignated', pg_temp.cpay('p15', 'a1', '10,00', p_recover => array[v_a]) ->> 'error',
    'another_s_invoice', pg_temp.cpay('p16', 'a1', '10,00', p_docs => array[v_lilas], p_desig => pg_temp.ev('7', 'a1'),
                                      p_expected => '0') ->> 'error',
    'unknown', pg_temp.cpay('p17', 'a1', '10,00', p_docs => array[gen_random_uuid()], p_desig => pg_temp.ev('7', 'a1'),
                            p_expected => '0') ->> 'error',
    'twice', pg_temp.cpay('p18', 'a1', '10,00', p_docs => array[v_f2, v_f2], p_desig => pg_temp.ev('7', 'a1'),
                          p_expected => '18000') ->> 'error',
    'changed', pg_temp.cpay('p19', 'a1', '10,00', p_expected => '73999') ->> 'error');
  -- (review round 1, TUI-5) no own account set: refused before anything is posted (as r13 for a refund)
  update public.servicer_billing_settings set own_bank_account_id = null
  where organization_id = '00000000-0000-0000-0000-0000000000aa';
  w := w || jsonb_build_object('no_own_account', pg_temp.cpay('p19b', 'a1', '10,00', p_expected => '74000') ->> 'error');
  update public.servicer_billing_settings set own_bank_account_id = '80000000-0000-0000-0000-0000000000c0'
  where organization_id = '00000000-0000-0000-0000-0000000000aa';
  w := w || jsonb_build_object(
    'none_written', (select count(*) from public.commission_settlement s where s.document_id in (v_f1, v_f2, v_a))
                    + (select count(*) from public.ledger_entry e
                       where e.client_organization_id = pg_temp.c('a1') and e.entry_type = 'client_payment_own'));
  -- the default order, 600,00 € (its value date today): FC-1 in full (all its VAT), A, then 4 000 of FC-2
  r := pg_temp.cpay('p20', 'a1', '600,00', d, p_expected => '74000');
  v_e := (r ->> 'entry_id')::uuid;
  w := w || jsonb_build_object(
    'settled', (select jsonb_agg(jsonb_build_array(x ->> 'document_kind',
                                   case x ->> 'document_id' when v_f1::text then 'f1' when v_a::text then 'a'
                                                            when v_f2::text then 'f2' end,
                                   x ->> 'number' is not distinct from case x ->> 'document_id'
                                     when v_f1::text then pg_temp.num(v_f1) when v_f2::text then pg_temp.num(v_f2) end,
                                   x ->> 'amount_minor', x ->> 'vat_moved_minor'))
                from jsonb_array_elements(r -> 'settled') x),
    'credit', r ->> 'credit_minor',
    'entry', (select jsonb_build_array(e.entry_type, e.effective_date = d, e.source_type,
                                       e.source_id = pg_temp.ev('5', 'a1')::text, e.client_organization_id = pg_temp.c('a1'),
                                       e.reason = 'Règlement du client par virement sur le compte du cabinet (valeur '
                                                  || to_char(d, 'DD/MM/YYYY') || ')',
                                       e.idempotency_key = 'cpay:' || md5('cpay-045-p20'))
              from public.ledger_entry e where e.id = v_e),
    'books', pg_temp.books(v_e),
    'f1', pg_temp.sets(v_f1), 'a', pg_temp.sets(v_a), 'f2', pg_temp.sets(v_f2),
    'settled_on', (select array_agg(distinct s.settled_on = d) from public.commission_settlement s
                   where s.entry_id = v_e),
    'open', jsonb_build_array(private.document_open(v_f1), private.advance_open(v_a), private.document_open(v_f2),
                              private.document_pending_vat(v_f2)),
    'replay', pg_temp.cpay('p20', 'a1', '600,00', d, p_expected => '74000') = r,
    'reused_key', pg_temp.cpay('p20', 'a1', '600,01', d, p_expected => '74000') ->> 'error',
    'by_an_admin', pg_temp.cpay('p21', 'a1', '10,00', p_user => '04') ->> 'credit_minor',
    -- the rest of FC-2 (13 000 after the admin's 1 000): its VAT moved in full on the part that closes it
    'closing', pg_temp.cpay('p22', 'a1', '130,00') -> 'settled' -> 0 ->> 'vat_moved_minor');
  w := w || jsonb_build_object(
    'f2_after', jsonb_build_array(private.document_open(v_f2), private.document_pending_vat(v_f2)),
    -- 4111 = the open invoices, 4112 = the open advances, 44574 = the pending VAT (I18): nothing dirty
    'receivable', jsonb_build_array(pg_temp.bk0('commission_receivable', 'a1'),
                                    pg_temp.bk0('client_advance_receivable', 'a1'), pg_temp.bk0('own_cash')),
    'dirty', pg_temp.dirty(), 'nightly', pg_temp.nightly(), 'checks', pg_temp.cchecks(),
    -- (7b's guard) a payment's settlement beyond an advance's amount is refused whatever posts it
    'guard', pg_temp.attempt(format('insert into public.commission_settlement (organization_id, client_organization_id, '
                                    'document_kind, document_id, kind, amount_minor, settled_on) values (%L, %L, '
                                    '''advance'', %L, ''payment_own'', 1, %L) returning 1',
                                    '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), v_a, d)));
  return w;
end $$;
select is(pg_temp.iso('sp'),
  '{"collector": "not allowed", "aal1": "not allowed", "other_servicer": "not allowed",
    "bad": ["client payment refused: bad_amount", "client payment refused: bad_amount",
            "client payment refused: bad_amount", "client payment refused: bad_amount"],
    "future": "client payment refused: bad_date", "bad_request": "client payment refused: bad_request",
    "no_evidence": "client payment refused: evidence_required", "wrong_kind": "client payment refused: evidence_required",
    "other_client": "client payment refused: evidence_required",
    "no_designation": "client payment refused: designation_evidence_required",
    "designation_of_another": "client payment refused: designation_evidence_required",
    "recovery_undesignated": "client payment refused: designation_evidence_required",
    "another_s_invoice": "client payment refused: not_open", "unknown": "client payment refused: not_open",
    "twice": "client payment refused: bad_request", "changed": "client payment refused: open_changed",
    "no_own_account": "client payment refused: no_own_account", "none_written": 0,
    "settled": [["invoice", "f1", true, "36000", "6000"], ["advance", "a", true, "20000", "0"],
                ["invoice", "f2", true, "4000", "667"]],
    "credit": "0",
    "entry": ["client_payment_own", true, "document", true, true, true, true],
    "books": {"own_cash": 60000, "commission_receivable": -40000, "client_advance_receivable": -20000,
              "vat_pending": 6667, "vat_collected": -6667},
    "f1": [["payment_own", 36000, 6000]], "a": [["payment_own", 20000, 0]], "f2": [["payment_own", 4000, 667]],
    "settled_on": [true], "open": [0, 0, 14000, 2333], "replay": true,
    "reused_key": "idempotency key cpay-045-p20 was used for a different request", "by_an_admin": "0",
    "closing": "2166", "f2_after": [0, 0],
    "receivable": [0, 0, 74000], "dirty": [], "nightly": [], "checks": [],
    "guard": "commission settlement: an advance settled beyond its amount"}'::jsonb,
  'p: « Règlement du client » — money staff at aal2; every refusal, nothing written; the default order (FC-1 due, the '
  'advance, then FC-2), VAT moved pro rata and in full on the closing part; +5122 / −4111 / −4112 / VAT pair, its '
  'document the evidence, dated at its value date; the settlements; replayed; I18 clean; the 7b guard holds');


-- p2. A named order with the client's designation; documents in flight (§5.2.4, [critic] L16) ---------------------------
create or replace function pg_temp.sq() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.martin(); v_f1 uuid := (m ->> 'f1')::uuid; v_f2 uuid := (m ->> 'f2')::uuid;
        v_a uuid := (m ->> 'a')::uuid; r1 jsonb; r2 jsonb;
begin
  -- FC-2 then A, in the client's order, 300,00 €: FC-2 in full (all its VAT), 12 000 of A; FC-1 (due) untouched
  r1 := pg_temp.cpay('q1', 'a1', '300,00', p_docs => array[v_f2, v_a], p_desig => pg_temp.ev('7', 'a1'));
  -- FC-1 named, 400,00 €: what is beyond it is a credit owed back, never another document
  r2 := pg_temp.cpay('q2', 'a1', '400,00', p_docs => array[v_f1], p_desig => pg_temp.ev('7', 'a1'));
  return jsonb_build_object(
    'first', (select jsonb_agg(jsonb_build_array(case x ->> 'document_id' when v_f2::text then 'f2' when v_a::text then 'a'
                                                 when v_f1::text then 'f1' end, x ->> 'amount_minor', x ->> 'vat_moved_minor'))
              from jsonb_array_elements(r1 -> 'settled') x),
    'second', (select jsonb_agg(jsonb_build_array(case x ->> 'document_id' when v_f1::text then 'f1' end,
                                                  x ->> 'amount_minor', x ->> 'vat_moved_minor'))
               from jsonb_array_elements(r2 -> 'settled') x),
    'credit', r2 ->> 'credit_minor', 'credits', pg_temp.ccs('a1'),
    'open', jsonb_build_array(private.document_open(v_f1), private.advance_open(v_a), private.document_open(v_f2)),
    'named_closed', pg_temp.cpay('q3', 'a1', '1,00', p_docs => array[v_f2], p_desig => pg_temp.ev('7', 'a1'),
                                 p_expected => '0') ->> 'error',
    'dirty', pg_temp.dirty(), 'checks', pg_temp.cchecks());
end $$;
select is(pg_temp.iso('sq'),
  '{"first": [["f2", "18000", "3000"], ["a", "12000", "0"]], "second": [["f1", "36000", "6000"]], "credit": "4000",
    "credits": [["overpayment", 4000, 4000]], "open": [0, 8000, 0],
    "named_closed": "client payment refused: not_open", "dirty": [], "checks": []}'::jsonb,
  'p2: with its designation, what the client names is paid in its order, each up to its open part; the rest is a credit '
  'owed back, never another document; a named document with nothing open is refused');

-- Martin's advance A taken back by a run in flight (its file downloaded; Martin's terms with a claw-back clause): A is in
-- flight — named, refused in_flight (its run in the detail); with no designation the default order skips it
create or replace function pg_temp.taking(p_c text, p_adv uuid, p_n text, p_s text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.clawback(p_c, 'art. 7.4');
  perform pg_temp.pending(p_c, p_n, 100000);
  v := pg_temp.request(p_c, 'tk-' || p_s);
  perform pg_temp.prepare_adv(v, jsonb_build_array(jsonb_build_array(p_adv, private.advance_open(p_adv)::text)));
  perform pg_temp.approve_plain(v, 'tk-' || p_s);
  perform pg_temp.handed_out('file-tk' || p_s, 'gen-file-tk' || p_s);
  return v;
end $$;
create or replace function pg_temp.sf2() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.martin(); v_f1 uuid := (m ->> 'f1')::uuid; v_f2 uuid := (m ->> 'f2')::uuid;
        v_a uuid := (m ->> 'a')::uuid; v_y uuid; v_msg text; v_detail text; r jsonb; o jsonb;
begin
  v_y := pg_temp.taking('a1', v_a, '25', '251');
  perform pg_temp.as_user('01');
  set local role authenticated;
  begin
    perform public.record_client_payment('cpay-045-f1', pg_temp.c('a1'), 'EUR', '10,00', private.paris_today(),
                                         pg_temp.ev('5', 'a1'), array[v_a], pg_temp.ev('7', 'a1'), null, '20000', 'x');
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  end;
  reset role;
  o := pg_temp.read_as('01', format('select public.client_open_documents(%L, ''EUR'')', pg_temp.c('a1')));
  r := pg_temp.cpay('f2', 'a1', '540,00', p_expected => '54000');
  return jsonb_build_object(
    'status', pg_temp.rstatus(v_y), 'refused', v_msg, 'detail_is_the_run', v_detail = pg_temp.rnum(v_y),
    'page', (select jsonb_build_array(x -> 'in_flight_run' ->> 'number' = pg_temp.rnum(v_y), x ->> 'open_minor')
             from jsonb_array_elements(o -> 'advances') x where x ->> 'id' = v_a::text),
    'default_order', (select jsonb_agg(case x ->> 'document_id' when v_f1::text then 'f1' when v_f2::text then 'f2'
                                       when v_a::text then 'a' end order by n)
                      from jsonb_array_elements(o -> 'default_order') with ordinality x (x, n)),
    'default_open', o ->> 'default_open_minor',
    'skipped', (select jsonb_agg(jsonb_build_array(case x ->> 'document_id' when v_f1::text then 'f1'
                                                   when v_f2::text then 'f2' when v_a::text then 'a' end,
                                                   x ->> 'amount_minor'))
                from jsonb_array_elements(r -> 'settled') x),
    'a_open', private.advance_open(v_a));
end $$;
select is(pg_temp.iso('sf2'),
  '{"status": "sent", "refused": "client payment refused: in_flight", "detail_is_the_run": true,
    "page": [true, "20000"], "default_order": ["f1", "f2"], "default_open": "54000",
    "skipped": [["f1", "36000"], ["f2", "18000"]], "a_open": 20000}'::jsonb,
  'p2: an advance a sent run takes back is in flight (switch off: its downloaded payout is never cancelled) — named, '
  'refused in_flight with its run; the default order skips it');
-- (switch on) the same run's payout cancelled after download and the run cancelled: its plan no longer holds A
create or replace function pg_temp.sf3() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.martin(); v_a uuid := (m ->> 'a')::uuid; v_y uuid; r jsonb;
begin
  v_y := pg_temp.taking('a1', v_a, '25', '252');
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancel_reason = 'annulé (test)'
  where id = pg_temp.rtransfer(v_y);
  perform pg_temp.cancel_run(v_y, 'tk-252');
  r := pg_temp.cpay('f3', 'a1', '200,00', p_docs => array[v_a], p_desig => pg_temp.ev('7', 'a1'));
  return jsonb_build_object('status', pg_temp.rstatus(v_y), 'settled', r -> 'settled' -> 0 ->> 'amount_minor',
                            'a_open', private.advance_open(v_a), 'switch', private.switch_on('downloaded_file_cancellation'));
end $$;
select is(pg_temp.iso('sf3', true),
  '{"status": "cancelled", "settled": "20000", "a_open": 0, "switch": true}'::jsonb,
  'p2 (switch on): a run cancelled after download no longer holds the advance its plan took: the client''s payment '
  'settles it');

-- (review round 4) a statement as ops 01 at aal2: its result, or its error's [message, detail]
create or replace function pg_temp.why(p_sql text, p_user text default '01') returns jsonb language plpgsql as $$
declare v jsonb; v_msg text; v_detail text;
begin
  perform pg_temp.as_user(p_user);
  set local role authenticated;
  begin
    execute p_sql into v;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    v := jsonb_build_array(v_msg, nullif(v_detail, ''));
  end;
  reset role;
  return v;
end $$;
-- (review round 4) a payment settles only what existed on its date — an invoice issued, an advance born, a loss passed
-- on or before it: the default order skips what came later (the money a credit owed back, true that day, no 4111 and no
-- VAT moved); a document or a loss the client names that came later is refused bad_date, its day in the detail
create or replace function pg_temp.sp4() returns jsonb language plpgsql as $$
declare
  d date := private.paris_today(); v_f uuid; a public.client_advance; a6 public.client_advance; r jsonb; r2 jsonb;
  r3 jsonb; r4 jsonb; w jsonb;
  q text := 'select public.record_client_payment(%L, %L, ''EUR'', %L, %L, %L, %L, %L, %L, %L, ''Virement reçu (test)'')';
begin
  -- Cyprès: an invoice issued today (36 000 TTC, 6 000 VAT pending)
  v_f := pg_temp.inv('a3', '30', 200000, '301');
  r := pg_temp.cpay('p40', 'a3', '360,00', d - 1);
  w := jsonb_build_object(
    'open_before', pg_temp.read_as('01', format(
                     'select public.client_payment_preview(%L, ''EUR'', ''360,00'', null, null, %L)', pg_temp.c('a3'),
                     d - 1)) ->> 'open_minor',
    'before', jsonb_build_array(r -> 'settled', r ->> 'credit_minor', pg_temp.books((r ->> 'entry_id')::uuid)),
    'invoice_open', private.document_open(v_f),
    'named_before', pg_temp.why(format(q, 'cpay-045-p41', pg_temp.c('a3'), '10,00', d - 1, pg_temp.ev('5', 'a3'),
                                       array[v_f], pg_temp.ev('7', 'a3'), null, '36000')),
    'preview_named_before', (select jsonb_build_array(x ->> 'refusal', x ->> 'refusal_detail')
                             from pg_temp.read_as('01', format(
                                    'select public.client_payment_preview(%L, ''EUR'', ''10,00'', %L, null, %L)',
                                    pg_temp.c('a3'), array[v_f], d - 1)) x));
  -- on its issue day it is settled
  r2 := pg_temp.cpay('p42', 'a3', '360,00', d);
  w := w || jsonb_build_object('on_issue', jsonb_build_array(jsonb_array_length(r2 -> 'settled'),
                                                             r2 #>> '{settled,0,amount_minor}', r2 ->> 'credit_minor'));
  -- Lambert: an advance born d − 2 — named on d − 3: refused; a payment dated d − 3 skips it, one dated d − 2 settles it
  a := pg_temp.adv('a4', '41', 50000, '411');
  w := w || jsonb_build_object(
    'advance_named_before', pg_temp.why(format(q, 'cpay-045-p43', pg_temp.c('a4'), '10,00', d - 3, pg_temp.ev('5', 'a4'),
                                               array[a.id], pg_temp.ev('7', 'a4'), null, '50000')));
  r3 := pg_temp.cpay('p44', 'a4', '100,00', d - 3);
  r4 := pg_temp.cpay('p45', 'a4', '100,00', d - 2);
  w := w || jsonb_build_object('advance', jsonb_build_array(r3 -> 'settled', r3 ->> 'credit_minor',
                                                            r4 #>> '{settled,0,document_kind}', r4 ->> 'credit_minor',
                                                            private.advance_open(a.id)));
  -- Dupont: an advance passed as a loss today, in full — its recovery named the day before: refused; today: recovered
  a6 := pg_temp.adv('a6', '40', 100000, '401');
  perform pg_temp.wo('b6', a6.id, '1000,00', '100000', p_evidence => 'd0000000-0000-0000-0000-0000000003a6');
  w := w || jsonb_build_object(
    'loss_before', pg_temp.why(format(q, 'cpay-045-p46', pg_temp.c('a6'), '10,00', d - 1, pg_temp.ev('5', 'a6'),
                                      array[]::uuid[], pg_temp.ev('7', 'a6'), array[a6.id], '100000')),
    'loss_on', pg_temp.cpay('p47', 'a6', '10,00', d, p_docs => array[]::uuid[], p_desig => pg_temp.ev('7', 'a6'),
                            p_recover => array[a6.id]) #>> '{settled,0,document_kind}',
    'dirty', pg_temp.dirty());
  return w;
end $$;
select is(pg_temp.iso('sp4'),
  ('{"open_before": "0",
     "before": [[], "36000", {"own_cash": 36000, "client_credit_owed": -36000}], "invoice_open": 36000,
     "named_before": ["client payment refused: bad_date", "' || private.paris_today() || '"],
     "preview_named_before": ["bad_date", "' || private.paris_today() || '"],
     "on_issue": [1, "36000", "0"],
     "advance_named_before": ["client payment refused: bad_date", "' || (private.paris_today() - 2) || '"],
     "advance": [[], "10000", "advance", "0", 40000],
     "loss_before": ["client payment refused: bad_date", "' || private.paris_today() || '"],
     "loss_on": "written_off", "dirty": []}')::jsonb,
  'p: (review round 4) a payment settles only what existed on its date — the default order skips an invoice issued or '
  'an advance born later (the money a credit owed back that day, no 4111, no VAT moved); named, it or a loss passed '
  'later is refused bad_date with its day; on that day it is settled');


-- b. What exceeds what is open is a credit owed back ([critic] M7-MONEY-10) -------------------------------------------------
create or replace function pg_temp.sb() returns jsonb language plpgsql as $$
declare v_f uuid; r jsonb; v_e uuid; v_cc uuid; w jsonb; d date := private.paris_today(); rf jsonb;
begin
  v_f := pg_temp.inv('a3', '30', 200000, '301');
  r := pg_temp.cpay('b1', 'a3', '365,00', p_expected => '36000');
  v_e := (r ->> 'entry_id')::uuid;
  v_cc := (select c.id from public.client_credit c where c.entry_id = v_e);
  w := jsonb_build_object(
    'settled', (select jsonb_agg(jsonb_build_array(x ->> 'amount_minor', x ->> 'vat_moved_minor'))
                from jsonb_array_elements(r -> 'settled') x),
    'credit', r ->> 'credit_minor', 'books', pg_temp.books(v_e), 'credits', pg_temp.ccs('a3'),
    -- (review round 1, TUI-2) the command states its credits by cause: the page's note is built from them
    'result_credits', r -> 'credits',
    'credit_row', (select jsonb_build_array(c.cause, c.amount_minor, c.currency, c.organization_id = '00000000-0000-0000-0000-0000000000aa',
                                            c.details is null)
                   from public.client_credit c where c.id = v_cc),
    'replay_rows', (select count(*) from public.client_credit c where c.client_organization_id = pg_temp.c('a3'))
                   + case when pg_temp.cpay('b1', 'a3', '365,00', p_expected => '36000') = r then 0 else 100 end,
    'dirty', pg_temp.dirty(), 'nightly', pg_temp.nightly(), 'today', pg_temp.cchecks(),
    -- more than 15 days old: silent on the 15th day, alerted on the 16th
    'day_15', pg_temp.cchecks(d + 15), 'day_16', pg_temp.cchecks(d + 16),
    -- the accounting export of the payment balances and names account 419
    'export', (select jsonb_build_array(sum((x ->> 'debit_minor')::bigint) = sum((x ->> 'credit_minor')::bigint),
                                        jsonb_agg(distinct x ->> 'account_number'))
               from jsonb_array_elements(pg_temp.read_as('01', format(
                      'select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.accounting_export_entries(%L, %L) x '
                      'where x.entry_id = %L', d, d, v_e))) x));
  -- the credit refunded from the own account, on proof: +419 / −5122; the alert stops
  rf := pg_temp.crfd('b2', v_cc, '5,00', d);
  w := w || jsonb_build_object(
    'refund', rf ->> 'owed_after_minor', 'refund_books', pg_temp.books((rf ->> 'entry_id')::uuid),
    'refund_settlement', pg_temp.sets(v_cc), 'credits_after', pg_temp.ccs('a3'),
    'day_16_after', pg_temp.cchecks(d + 16), 'nothing_owed', pg_temp.crfd('b3', v_cc, '1,00', d) ->> 'error',
    'dirty_after', pg_temp.dirty());
  return w;
end $$;
select is(pg_temp.iso('sb'),
  '{"settled": [["36000", "6000"]], "credit": "500",
    "books": {"own_cash": 36500, "commission_receivable": -36000, "client_credit_owed": -500, "vat_pending": 6000,
              "vat_collected": -6000},
    "credits": [["overpayment", 500, 500]], "result_credits": [{"cause": "overpayment", "amount_minor": "500"}],
    "credit_row": ["overpayment", 500, "EUR", true, true], "replay_rows": 1,
    "dirty": [], "nightly": [], "today": [], "day_15": [],
    "day_16": [["client_credit_owed", "alert", 500, "overpayment", false]],
    "export": [true, ["4111", "419", "44571", "44574", "5122"]],
    "refund": "0", "refund_books": {"client_credit_owed": 500, "own_cash": -500},
    "refund_settlement": [["refund", 500, 0]], "credits_after": [["overpayment", 500, 0]], "day_16_after": [],
    "nothing_owed": "client refund refused: nothing_owed", "dirty_after": []}'::jsonb,
  'b: 365,00 € for 360,00 € open — 360,00 € settled, 5,00 € a credit owed back (−419), never refused; a replay creates '
  'none; I9, I18, I19 clean; client_credit_owed after 15 days; the export balances with account 419; the refund of the '
  'credit (+419 / −5122) stops the alert');

-- an advance a run already took back (Durand, a claw-back clause), then the client pays it anyway: all of it a credit owed
-- back (named, the advance is refused not_open); a written-off advance repaid (Dupont): 7714, capped at the loss
create or replace function pg_temp.sb2() returns jsonb language plpgsql as $$
declare a7 public.client_advance; a6 public.client_advance; v_y uuid; r jsonb; r2 jsonb; v_e uuid; w jsonb;
begin
  a7 := pg_temp.adv('a7', '31', 20000, '311');
  v_y := pg_temp.taking('a7', a7.id, '32', '321');
  perform pg_temp.debit(v_y, '322');
  r := pg_temp.cpay('b4', 'a7', '200,00', p_expected => '0');
  w := jsonb_build_object(
    'taken', jsonb_build_array(pg_temp.rstatus(v_y), private.advance_open(a7.id)),
    'all_credit', jsonb_build_array(r -> 'settled', r ->> 'credit_minor'), 'credits', pg_temp.ccs('a7'),
    'named', pg_temp.cpay('b5', 'a7', '200,00', p_docs => array[a7.id], p_desig => pg_temp.ev('7', 'a7'),
                          p_expected => '0') ->> 'error');
  -- Dupont: an advance of 100 000, 30 000 of it passed as a loss; the client repays 1 100,00 €, naming the advance and
  -- the loss's recovery: 70 000 settle the advance, 30 000 are a recovery (7714), 10 000 a credit owed back
  a6 := pg_temp.adv('a6', '40', 100000, '401');
  perform pg_temp.wo('b6', a6.id, '300,00', '100000', p_evidence => 'd0000000-0000-0000-0000-0000000003a6');
  w := w || jsonb_build_object(
    'expected', pg_temp.read_as('01', format('select public.client_payment_preview(%L, ''EUR'', ''1100,00'', %L, %L)',
                                             pg_temp.c('a6'), array[a6.id], array[a6.id])) ->> 'open_minor');
  r2 := pg_temp.cpay('b7', 'a6', '1100,00', p_docs => array[a6.id], p_desig => pg_temp.ev('7', 'a6'),
                     p_recover => array[a6.id]);
  v_e := (r2 ->> 'entry_id')::uuid;
  w := w || jsonb_build_object(
    'rows', (select jsonb_agg(jsonb_build_array(x ->> 'document_kind', x ->> 'amount_minor'))
             from jsonb_array_elements(r2 -> 'settled') x),
    'credit', r2 ->> 'credit_minor', 'books', pg_temp.books(v_e),
    'recoveries', (select jsonb_agg(jsonb_build_array(x.advance_id = a6.id, x.amount_minor, x.entry_id = v_e))
                   from public.advance_write_off_recovery x where x.advance_id = a6.id),
    'again', pg_temp.cpay('b8', 'a6', '10,00', p_docs => array[]::uuid[], p_desig => pg_temp.ev('7', 'a6'),
                          p_recover => array[a6.id], p_expected => '0') ->> 'error',
    'loss', pg_temp.bk0('servicer_losses'), 'recovered', pg_temp.bk0('written_off_recovered'),
    'checks', pg_temp.cchecks());
  -- the guard, whoever writes (test only, a planted payment of 1,00 € on 7714): a recovery beyond what was passed as a
  -- loss, or of an advance of another client, is refused
  perform pg_temp.plant('client_payment_own', 'b9', '[["own_cash", 100], ["written_off_recovered", -100]]', 'a6');
  return w || jsonb_build_object('guard', jsonb_build_array(
    pg_temp.state(format('insert into public.advance_write_off_recovery (advance_id, entry_id, organization_id, '
                         'client_organization_id, currency, amount_minor) values (%L, %L, %L, %L, ''EUR'', 100)',
                         a6.id, pg_temp.ek('raw-045-b9'), '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a6'))),
    pg_temp.state(format('insert into public.advance_write_off_recovery (advance_id, entry_id, organization_id, '
                         'client_organization_id, currency, amount_minor) values (%L, %L, %L, %L, ''EUR'', 100)',
                         a7.id, pg_temp.ek('raw-045-b9'), '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a6')))));
end $$;
select is(pg_temp.iso('sb2'),
  '{"taken": ["booked", 0], "all_credit": [[], "20000"], "credits": [["overpayment", 20000, 20000]],
    "named": "client payment refused: not_open", "expected": "100000",
    "rows": [["advance", "70000"], ["written_off", "30000"]], "credit": "10000",
    "books": {"own_cash": 110000, "client_advance_receivable": -70000, "written_off_recovered": -30000,
              "client_credit_owed": -10000},
    "recoveries": [[true, 30000, true]], "again": "client payment refused: not_open", "loss": 30000,
    "recovered": -30000, "checks": [], "guard": ["23514", "23514"]}'::jsonb,
  'b: money for an advance a run already took back is all a credit owed back; a written-off advance the client repays '
  'is a recovery (7714) capped at what was passed as a loss, never again');


-- l, c. A client in a proceeding ([check 1] gap 11, [critic] L21) ------------------------------------------------------
-- Lilas: FC-3 (36 000) issued d − 5, its proceeding opened d − 3, FC-5 (18 000) issued d
create or replace function pg_temp.lilas() returns jsonb language plpgsql as $$
declare v_f3 uuid; v_f5 uuid; d date := private.paris_today();
begin
  v_f3 := pg_temp.inv('a2', '50', 200000, '501');
  perform pg_temp.issued(v_f3, d - 5);
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, note, recorded_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a2'), 'proceeding_opened', d - 3, pg_temp.ev('8', 'a2'),
          'Redressement judiciaire (test)', '10000000-0000-0000-0000-000000000004');
  v_f5 := pg_temp.inv('a2', '51', 100000, '511');
  return jsonb_build_object('f3', v_f3, 'f5', v_f5);
end $$;
create or replace function pg_temp.sl() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.lilas(); v_f3 uuid := (m ->> 'f3')::uuid; v_f5 uuid := (m ->> 'f5')::uuid; r jsonb; o jsonb;
begin
  o := pg_temp.read_as('01', format('select public.client_open_documents(%L, ''EUR'')', pg_temp.c('a2')));
  r := pg_temp.cpay('l1', 'a2', '180,00', p_expected => '18000');
  return jsonb_build_object(
    'page', jsonb_build_array(o -> 'procedure',
                              (select jsonb_agg(jsonb_build_array(case x ->> 'id' when v_f3::text then 'f3' else 'f5' end,
                                                                  x -> 'before_opening', x -> 'payable') order by x ->> 'number')
                               from jsonb_array_elements(o -> 'invoices') x)),
    'before', jsonb_build_array(private.document_before_opening(v_f3, private.paris_today()),
                                private.document_client_payable(v_f3, private.paris_today()),
                                private.document_client_payable(v_f5, private.paris_today()),
                                private.document_before_opening(v_f3, private.paris_today() - 4)),
    'settled', (select jsonb_agg(jsonb_build_array(case x ->> 'document_id' when v_f5::text then 'f5' else 'f3' end,
                                                   x ->> 'amount_minor'))
                from jsonb_array_elements(r -> 'settled') x),
    'credits', pg_temp.ccs('a2'), 'f3_open', private.document_open(v_f3));
end $$;
select is(pg_temp.iso('sl'),
  '{"page": [true, [["f3", true, false], ["f5", false, true]]], "before": [true, false, true, false],
    "settled": [["f5", "18000"]], "credits": [], "f3_open": 36000}'::jsonb,
  'l: a client in a proceeding, no designation: the post-opening invoice is paid, the pre-opening one untouched '
  '(L622-7 I al. 1), no credit');
create or replace function pg_temp.sl2() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.lilas(); v_f3 uuid := (m ->> 'f3')::uuid; v_f5 uuid := (m ->> 'f5')::uuid; r jsonb;
begin
  r := pg_temp.cpay('l2', 'a2', '300,00', p_expected => '18000');
  return jsonb_build_object(
    'settled', (select jsonb_agg(jsonb_build_array(case x ->> 'document_id' when v_f5::text then 'f5' else 'f3' end,
                                                   x ->> 'amount_minor'))
                from jsonb_array_elements(r -> 'settled') x),
    'credits', pg_temp.ccs('a2'), 'f3_open', private.document_open(v_f3),
    -- a P0 alert at once (cause procedure): ops and counsel decide
    'today', pg_temp.cchecks());
end $$;
select is(pg_temp.iso('sl2'),
  '{"settled": [["f5", "18000"]], "credits": [["procedure", 12000, 12000]], "f3_open": 36000,
    "today": [["client_credit_owed", "alert", 12000, "procedure", true]]}'::jsonb,
  'l: a larger payment — the post-opening invoice paid, the rest held for the procedure (cause procedure, never '
  'overpayment), a P0 alert at once');
-- a client in liquidation (its judgment recorded alone: a liquidation opened at once) pays with nothing open: the money
-- is held for the procedure too, never refunded to it as an overpayment
create or replace function pg_temp.sl4() returns jsonb language plpgsql as $$
begin
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, note, recorded_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a8'), 'liquidation', private.paris_today() - 2,
          pg_temp.ev('8', 'a8'), 'Liquidation judiciaire (test)', '10000000-0000-0000-0000-000000000004');
  perform pg_temp.cpay('l4', 'a8', '50,00', p_expected => '0');
  return jsonb_build_object('credits', pg_temp.ccs('a8'));
end $$;
select is(pg_temp.iso('sl4'), '{"credits": [["procedure", 5000, 5000]]}'::jsonb,
  'l: a client in liquidation — what it pays with nothing open is held for the procedure (cause procedure)');
create or replace function pg_temp.sl3() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.lilas(); v_f3 uuid := (m ->> 'f3')::uuid; r jsonb;
begin
  r := pg_temp.cpay('l3', 'a2', '360,00', p_docs => array[v_f3], p_desig => pg_temp.ev('7', 'a2'));
  return jsonb_build_object(
    'settled', r -> 'settled', 'credit', r ->> 'credit_minor', 'credits', pg_temp.ccs('a2'),
    'details', (select c.details = jsonb_build_array(jsonb_build_object('document_kind', 'invoice', 'document_id', v_f3,
                                                                         'number', pg_temp.num(v_f3),
                                                                         'amount_minor', '36000'))
                from public.client_credit c where c.client_organization_id = pg_temp.c('a2')),
    'f3_open', private.document_open(v_f3), 'f3_settlements', pg_temp.sets(v_f3), 'dirty', pg_temp.dirty(),
    -- (review round 1, TUI-6) its P0 alert at once (plan §5.7 (c))
    'today', pg_temp.cchecks());
end $$;
select is(pg_temp.iso('sl3'),
  '{"settled": [], "credit": "36000", "credits": [["procedure", 36000, 36000]], "details": true, "f3_open": 36000,
    "f3_settlements": [], "dirty": [], "today": [["client_credit_owed", "alert", 36000, "procedure", true]]}'::jsonb,
  'c: the client designates its pre-opening invoice — the money is held for the procedure (cause procedure, the '
  'invoice named in the credit''s details, a P0 alert at once), the invoice still open');
-- (review round 1, MONEY-1) a client in a proceeding repays an advance passed as a loss that was born before the
-- opening (L622-7 I al. 1; founder Q4 a: never a pre-opening claim): never income on 7714 — held for the procedure
-- (cause procedure, the advance named in the credit's details, a P0 alert), its loss still to recover; the page and the
-- preview say so; on the dedicated account the same. Dupont: an advance of 100 000 passed as a loss in full (no longer
-- open: the credit's details read it from the advance itself), its proceeding opened today.
create or replace function pg_temp.sl5() returns jsonb language plpgsql as $$
declare a6 public.client_advance; d date := private.paris_today(); o jsonb; p jsonb; r jsonb; v_e uuid; v_l uuid;
        r2 jsonb; w jsonb;
begin
  a6 := pg_temp.adv('a6', '40', 100000, '401');
  perform pg_temp.wo('s5a', a6.id, '1000,00', '100000', p_evidence => 'd0000000-0000-0000-0000-0000000003a6');
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, note, recorded_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a6'), 'proceeding_opened', d, pg_temp.ev('8', 'a6'),
          'Redressement judiciaire (test)', '10000000-0000-0000-0000-000000000004');
  o := pg_temp.read_as('01', format('select public.client_open_documents(%L, ''EUR'')', pg_temp.c('a6')));
  p := pg_temp.read_as('01', format('select public.client_payment_preview(%L, ''EUR'', ''300,00'', %L, %L)',
                                    pg_temp.c('a6'), array[]::uuid[], array[a6.id]));
  r := pg_temp.cpay('s5b', 'a6', '300,00', p_docs => array[]::uuid[], p_desig => pg_temp.ev('7', 'a6'),
                    p_recover => array[a6.id]);
  v_e := (r ->> 'entry_id')::uuid;
  w := jsonb_build_object(
    'born_before', jsonb_build_array(private.document_before_opening(a6.id, d), private.advance_open(a6.id)),
    'page', (select jsonb_agg(jsonb_build_array(x -> 'before_opening', x -> 'payable', x ->> 'available_minor'))
             from jsonb_array_elements(o -> 'written_off') x),
    'preview', (select jsonb_agg(jsonb_build_array(x ->> 'document_kind', x ->> 'document_id' = a6.id::text,
                                                   x ->> 'amount_minor', x ->> 'cause'))
                from jsonb_array_elements(p -> 'rows') x),
    'settled', r -> 'settled', 'credit', r ->> 'credit_minor', 'result_credits', r -> 'credits',
    'books', pg_temp.books(v_e), 'credits', pg_temp.ccs('a6'),
    'details', (select c.details = jsonb_build_array(jsonb_build_object('document_kind', 'advance', 'document_id', a6.id,
                                                                         'number', null, 'amount_minor', '30000'))
                from public.client_credit c where c.entry_id = v_e),
    'recoveries', (select count(*) from public.advance_write_off_recovery x where x.advance_id = a6.id),
    'to_recover', private.written_off_available(a6.id), 'recovered', pg_temp.bk0('written_off_recovered'),
    'today', pg_temp.cchecks(), 'dirty', pg_temp.dirty());
  -- the dedicated account: Dupont's credit of 300,00 € booked today (the proceeding open on its date) the client
  -- designates for the loss's recovery — the same
  v_l := pg_temp.ctin('751', 30000, pg_temp.iban_of('a6'), 'Remboursement', p_day => d);
  r2 := pg_temp.cline('s5c', v_l, p_desig => pg_temp.ev('7', 'a6'), p_recover => array[a6.id]);
  w := w || jsonb_build_object(
    'line', jsonb_build_array(r2 -> 'settled', r2 ->> 'credit_minor'), 'line_books', pg_temp.books((r2 ->> 'entry_id')::uuid),
    'credits_after', pg_temp.ccs('a6'),
    'recoveries_after', (select count(*) from public.advance_write_off_recovery x where x.advance_id = a6.id),
    'recovered_after', pg_temp.bk0('written_off_recovered'), 'dirty_after', pg_temp.dirty());
  -- a line booked yesterday, the day before the opening: then the client could still repay it — a recovery (7714) —
  -- (review round 4) once the loss was passed: passed today, yesterday's line repaid an advance still open, never a
  -- loss (refused bad_date); the loss moved back to d − 2 (test only, as Lilas's FC-3), it is a recovery
  v_l := pg_temp.ctin('752', 10000, pg_temp.iban_of('a6'), 'Remboursement', p_day => d - 1);
  w := w || jsonb_build_object(
    'loss_later', pg_temp.cline('s5d0', v_l, p_desig => pg_temp.ev('7', 'a6'), p_recover => array[a6.id],
                                p_expected => '100000') ->> 'error');
  alter table public.commission_settlement disable trigger commission_settlement_append_only;
  update public.commission_settlement set settled_on = d - 2
  where document_id = a6.id and document_kind = 'advance' and kind = 'write_off';
  alter table public.commission_settlement enable always trigger commission_settlement_append_only;
  r2 := pg_temp.cline('s5d', v_l, p_desig => pg_temp.ev('7', 'a6'), p_recover => array[a6.id]);
  return w || jsonb_build_object(
    'day_before', jsonb_build_array((select jsonb_agg(jsonb_build_array(x ->> 'document_kind', x ->> 'amount_minor'))
                                     from jsonb_array_elements(r2 -> 'settled') x), r2 ->> 'credit_minor',
                                    pg_temp.bk0('written_off_recovered'), private.written_off_available(a6.id)));
end $$;
select is(pg_temp.iso('sl5'),
  '{"born_before": [true, 0], "page": [[true, false, "100000"]],
    "preview": [["client_credit", true, "30000", "procedure"]],
    "settled": [], "credit": "30000", "result_credits": [{"cause": "procedure", "amount_minor": "30000"}],
    "books": {"own_cash": 30000, "client_credit_owed": -30000},
    "credits": [["procedure", 30000, 30000]], "details": true, "recoveries": 0, "to_recover": 100000, "recovered": 0,
    "today": [["client_credit_owed", "alert", 30000, "procedure", true]], "dirty": [],
    "line": [[], "30000"],
    "line_books": {"client_money_cash": 30000, "due_to_servicer": -30000, "due_from_client_funds": 30000,
                   "client_credit_owed": -30000},
    "credits_after": [["procedure", 30000, 30000], ["procedure", 30000, 30000]], "recoveries_after": 0,
    "recovered_after": 0, "dirty_after": [], "loss_later": "client payment refused: bad_date",
    "day_before": [[["written_off", "10000"]], "0", -10000, 90000]}'::jsonb,
  'c: a client in a proceeding repays an advance passed as a loss born before the opening — held for the procedure '
  '(cause procedure, a P0 alert), never 7714, the loss still to recover; the page and the preview say so; the '
  'dedicated account the same; a payment dated the day before the opening is still a recovery once the loss was '
  'passed (review round 4: never before it)');
-- (review round 2) a client whose liquidation judgment is recorded alone (a liquidation opened at once): C. com. L641-3
-- al. 1 gives that judgment the effects of L622-7 I al. 1 — a claim born before it is never paid (HOLD-02) —, so its
-- opening is the earliest proceeding_opened or liquidation in effect (private.client_opening_date, plan §6.2.2). Roux:
-- FC-R1 (36 000) issued d − 5, an advance (20 000) born d − 2, FC-R2 (18 000) issued d; its liquidation at d − 1
create or replace function pg_temp.roux() returns jsonb language plpgsql as $$
declare v_r1 uuid; v_r2 uuid; a public.client_advance; d date := private.paris_today();
begin
  v_r1 := pg_temp.inv('a5', '90', 200000, '901');
  perform pg_temp.issued(v_r1, d - 5);
  v_r2 := pg_temp.inv('a5', '93', 100000, '931');
  a := pg_temp.adv('a5', '92', 20000, '921');
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, note, recorded_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a5'), 'liquidation', d - 1, pg_temp.ev('8', 'a5'),
          'Liquidation judiciaire (test)', '10000000-0000-0000-0000-000000000004');
  return jsonb_build_object('r1', v_r1, 'r2', v_r2, 'a', a.id);
end $$;
create or replace function pg_temp.sl6() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.roux(); v_r1 uuid := (m ->> 'r1')::uuid; v_r2 uuid := (m ->> 'r2')::uuid;
        v_a uuid := (m ->> 'a')::uuid; d date := private.paris_today(); o jsonb; r jsonb;
begin
  o := pg_temp.read_as('01', format('select public.client_open_documents(%L, ''EUR'')', pg_temp.c('a5')));
  -- no designation, enough for every document: only the claim born after the judgment is paid
  r := pg_temp.cpay('l6', 'a5', '740,00');
  return jsonb_build_object(
    'page', jsonb_build_array(o -> 'procedure',
                              (select jsonb_agg(jsonb_build_array(case x ->> 'id' when v_r1::text then 'r1' else 'r2' end,
                                                                  x -> 'before_opening', x -> 'payable')
                                                order by x ->> 'issue_date')
                               from jsonb_array_elements(o -> 'invoices') x),
                              (select jsonb_agg(jsonb_build_array(x -> 'before_opening', x -> 'payable'))
                               from jsonb_array_elements(o -> 'advances') x)),
    'before', jsonb_build_array(private.document_before_opening(v_r1, d), private.document_client_payable(v_r1, d),
                                private.document_before_opening(v_a, d), private.document_before_opening(v_r2, d),
                                private.document_before_opening(v_r1, d - 2)),
    'settled', (select jsonb_agg(jsonb_build_array(case x ->> 'document_id' when v_r1::text then 'r1'
                                                                            when v_r2::text then 'r2' else 'a' end,
                                                   x ->> 'amount_minor'))
                from jsonb_array_elements(r -> 'settled') x),
    'credits', pg_temp.ccs('a5'), 'open', jsonb_build_array(private.document_open(v_r1), private.advance_open(v_a)),
    'r1_settlements', pg_temp.sets(v_r1), 'today', pg_temp.cchecks(), 'dirty', pg_temp.dirty());
end $$;
-- (M2c-7d-2, house rule R3, ADR-0014 « M2c-7d-2 ») plan §6.2.4–§6.2.5, default OQ-92: an invoice is born at the
-- earliest collection it charges, never at its issue — FC-R2, issued on d for a collection of d − 3, is a claim born
-- before the judgment of d − 1: skipped and held for the procedure like FC-R1 (in 7c-1 it was paid, 18 000, and the
-- procedure's credit 56 000)
select is(pg_temp.iso('sl6'),
  '{"page": [true, [["r1", true, false], ["r2", true, false]], [[true, false]]],
    "before": [true, false, true, true, false], "settled": null,
    "credits": [["procedure", 74000, 74000]], "open": [36000, 20000], "r1_settlements": [],
    "today": [["client_credit_owed", "alert", 74000, "procedure", true]], "dirty": []}'::jsonb,
  'l: a client whose liquidation is recorded alone, no designation — the claims born before the judgment (an invoice, '
  'an advance) are skipped (L641-3 al. 1, L622-7 I al. 1) — (M2c-7d-2, R3) FC-R2 too, born before the judgment by its '
  'collection (document_born_on), so nothing is settled — and held for the procedure; the page marks them '
  '« antérieure à l''ouverture »');
create or replace function pg_temp.sl7() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.roux(); v_r1 uuid := (m ->> 'r1')::uuid; v_a uuid := (m ->> 'a')::uuid; r jsonb;
        r2 jsonb; v_l uuid;
begin
  -- the client designates FC-R1 and the advance (own account): all held for the procedure, each named
  r := pg_temp.cpay('l7', 'a5', '400,00', p_docs => array[v_r1, v_a], p_desig => pg_temp.ev('7', 'a5'));
  -- the dedicated account: Roux's credit of 50,00 € booked yesterday, the judgment's day, labelled with FC-R1's number
  v_l := pg_temp.ctin('9a1', 5000, pg_temp.iban_of('a5'), 'Reglement ' || pg_temp.num(v_r1));
  r2 := pg_temp.cline('l7b', v_l, array[v_r1]);
  return jsonb_build_object(
    'settled', r -> 'settled', 'credit', r ->> 'credit_minor', 'books', pg_temp.books((r ->> 'entry_id')::uuid),
    'details', (select c.details = jsonb_build_array(
                         jsonb_build_object('document_kind', 'invoice', 'document_id', v_r1, 'number', pg_temp.num(v_r1),
                                            'amount_minor', '36000'),
                         jsonb_build_object('document_kind', 'advance', 'document_id', v_a, 'number', null,
                                            'amount_minor', '4000'))
                from public.client_credit c where c.entry_id = (r ->> 'entry_id')::uuid),
    'line', jsonb_build_array(r2 -> 'settled', r2 ->> 'credit_minor'),
    'line_books', pg_temp.books((r2 ->> 'entry_id')::uuid),
    'credits', (select jsonb_agg(jsonb_build_array(c.cause, c.amount_minor) order by c.amount_minor desc)
                from public.client_credit c where c.client_organization_id = pg_temp.c('a5')),
    'open', jsonb_build_array(private.document_open(v_r1), private.advance_open(v_a)), 'r1_settlements', pg_temp.sets(v_r1),
    'dirty', pg_temp.dirty());
end $$;
select is(pg_temp.iso('sl7'),
  '{"settled": [], "credit": "40000", "books": {"own_cash": 40000, "client_credit_owed": -40000}, "details": true,
    "line": [[], "5000"],
    "line_books": {"client_money_cash": 5000, "due_to_servicer": -5000, "due_from_client_funds": 5000,
                   "client_credit_owed": -5000},
    "credits": [["procedure", 40000], ["procedure", 5000]], "open": [36000, 20000], "r1_settlements": [],
    "dirty": []}'::jsonb,
  'c: a client whose liquidation is recorded alone designates a pre-judgment invoice and advance — held for the '
  'procedure (cause procedure, each named), never settled; on the dedicated account, a label naming the invoice, the '
  'same on the judgment''s day');
-- the opening read: the earliest proceeding_opened or liquidation in effect on the day
create or replace function pg_temp.sl8() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb;
begin
  perform pg_temp.roux();
  w := jsonb_build_object('liquidation', jsonb_build_array(private.client_opening_date(pg_temp.c('a5'), d) = d - 1,
                                                           private.client_opening_date(pg_temp.c('a5'), d - 1) = d - 1,
                                                           private.client_opening_date(pg_temp.c('a5'), d - 2)));
  -- a redressement opened d − 4 (recorded after): the earliest of the two
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, note, recorded_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a5'), 'proceeding_opened', d - 4, pg_temp.ev('8', 'a5'),
          'Redressement judiciaire (test)', '10000000-0000-0000-0000-000000000004');
  return w || jsonb_build_object('both', jsonb_build_array(private.client_opening_date(pg_temp.c('a5'), d) = d - 4,
                                                           private.client_opening_date(pg_temp.c('a5'), d - 5)),
                                 'none', private.client_opening_date(pg_temp.c('a1'), d));
end $$;
select is(pg_temp.iso('sl8'),
  '{"liquidation": [true, true, null], "both": [true, null], "none": null}'::jsonb,
  'l: the client''s opening is the earliest proceeding_opened or liquidation in effect that day, none before it');
-- (review round 3) Roux's advance, born d − 2 before its liquidation recorded alone at d − 1, under a mandate without a
-- claw-back clause: no run takes it, and the client may not pay it (L641-3 al. 1 → L622-7 I al. 1; the creditor
-- declares it to the liquidator) — so no page says a request is due: barred_proceeding on the client space, the staff
-- « Avances », « Ce que le client doit au cabinet », the run page, « Désimputer » and the nightly, before and after the
-- client pays it (held for the procedure). Born on the judgment's day, or read the day before it, it is a request.
-- (M2c-7d-2) A claw-back clause no longer takes it: the prepare and advance_recovery_of read client_opening_date (a
-- liquidation recorded alone opens the procedure) and client_set_off_barred (nothing set off in liquidation, Q11).
create or replace function pg_temp.sl9() returns jsonb language plpgsql as $$
declare m jsonb; v_a uuid; d date := private.paris_today();
        c5 uuid := pg_temp.c('a5'); v_m uuid := pg_temp.mandate('a5'); v_run uuid; v_chk uuid; w jsonb; r jsonb;
begin
  -- a collection of Roux remitted by a payout debited d − 2 (before the judgment), still allocated: « Désimputer » would
  -- post a cover born then
  perform pg_temp.remitted('a5', '94', 10000, '941', d - 2, d - 3);
  m := pg_temp.roux();
  v_a := (m ->> 'a')::uuid;
  select q.id into v_run from public.remittance_run q
  where q.transfer_id = (select a.transfer_id from public.client_advance a where a.id = v_a);
  v_chk := pg_temp.adv_run(d + 31, true);
  w := jsonb_build_object(
    'space', (select jsonb_agg(jsonb_build_array(x ->> 'recovery', x ->> 'clause_ref', x ->> 'open_minor',
                                                 (x ->> 'born_on')::date - d))
              from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_space_advances(%L)', c5))
                                        -> 'rows') x),
    'staff', (select jsonb_agg(jsonb_build_array(x ->> 'recovery', x ->> 'clause_ref'))
              from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_advances(%L, %L)',
                                                                      '00000000-0000-0000-0000-0000000000aa', c5))
                                        -> 'rows') x),
    'page', (select jsonb_agg(jsonb_build_array(x ->> 'recovery', x -> 'before_opening', x -> 'payable'))
             from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_open_documents(%L, ''EUR'')',
                                                                     c5)) -> 'advances') x),
    'run_page', (select jsonb_agg(jsonb_build_array(x ->> 'recovery', x ->> 'clause_ref'))
                 from jsonb_array_elements(pg_temp.read_as('01', format('select public.remittance_run_payout(%L)', v_run))
                                           -> 'advances') x),
    -- the cover « Désimputer » would post: born d − 2, barred; FC-R1's collection's, born with its payout's debit on
    -- the judgment's day (not before it), a request
    'desimputer', jsonb_build_array(
      (select jsonb_agg(jsonb_build_array(x ->> 'recovery', (x ->> 'booked_on')::date - d))
       from jsonb_array_elements(pg_temp.read_as('01', format('select public.allocation_remitted(%L)',
                                                               pg_temp.pay('94')))) x),
      (select jsonb_agg(jsonb_build_array(x ->> 'recovery', (x ->> 'booked_on')::date - d))
       from jsonb_array_elements(pg_temp.read_as('01', format('select public.allocation_remitted(%L)',
                                                               pg_temp.pay('90')))) x)),
    'nightly', (select jsonb_agg(jsonb_build_array(x.amount_minor, x.details ->> 'recovery'))
                from public.payment_check_result x
                where x.run_id = v_chk and x.code = 'advance_open' and x.details ->> 'client_id' = c5::text),
    'of', jsonb_build_array((select q.recovery from private.advance_recovery_of(v_m, c5, d - 2, d) q),
                            (select q.recovery from private.advance_recovery_of(v_m, c5, d - 1, d) q),
                            (select q.recovery from private.advance_recovery_of(null, c5, d - 2, d) q),
                            (select q.recovery from private.advance_recovery_of(null, c5, d - 1, d) q),
                            (select q.recovery from private.advance_recovery_of(v_m, c5, d - 2, d - 2) q)));
  -- the client repays it as designated: held for the procedure, the advance still open and still not « à rembourser »
  r := pg_temp.cpay('l9', 'a5', '200,00', p_docs => array[v_a], p_desig => pg_temp.ev('7', 'a5'));
  w := w || jsonb_build_object(
    'paid', jsonb_build_array(r -> 'settled', r ->> 'credit_minor', private.advance_open(v_a)),
    'space_after', (select jsonb_agg(jsonb_build_array(x ->> 'recovery', x ->> 'open_minor'))
                    from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_space_advances(%L)', c5))
                                              -> 'rows') x),
    'credits_space', (select jsonb_agg(jsonb_build_array(x ->> 'cause', x ->> 'open_minor'))
                      from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_space_credits(%L)',
                                                                             c5)) -> 'rows') x));
  -- a claw-back clause in Roux's terms: (M2c-7d-2) the liquidation recorded alone bars it too (carried from 7c-1)
  perform pg_temp.clawback('a5', 'art. 7.4');
  return w || jsonb_build_object('clawback', jsonb_build_array(
    (select jsonb_agg(jsonb_build_array(x ->> 'recovery', x ->> 'clause_ref'))
     from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_space_advances(%L)', c5)) -> 'rows') x),
    (select q.recovery from private.advance_recovery_of(v_m, c5, d - 2, d) q)));
end $$;
-- (M2c-7d-2, house rule R3, ADR-0014 « M2c-7d-2 ») carried from 7c-1 rounds 2–3 and plan §6.2.6 (founder Q11, Q18
-- defaults): a liquidation recorded alone stands as a proceeding — no advance is taken back or requested, whatever its
-- birth or mandate (« of » was request / request_no_mandate for the ones born on or after the judgment, « Désimputer »
-- request for one), and the claw-back clause no longer applies (« clawback » was 7b's rule, read on proceeding_opened
-- alone)
select is(pg_temp.iso('sl9'),
  '{"space": [["barred_proceeding", null, "20000", -2]], "staff": [["barred_proceeding", null]],
    "page": [["barred_proceeding", true, false]], "run_page": [["barred_proceeding", null]],
    "desimputer": [[["barred_proceeding", -2]], [["barred_proceeding", -1]]], "nightly": [[20000, "barred_proceeding"]],
    "of": ["barred_proceeding", "barred_proceeding", "barred_proceeding", "barred_proceeding", "request"],
    "paid": [[], "20000", 20000], "space_after": [["barred_proceeding", "20000"]],
    "credits_space": [["procedure", "20000"]], "clawback": [[["barred_proceeding", null]], "barred_proceeding"]}'::jsonb,
  'l: a liquidation recorded alone — a pre-judgment advance without a claw-back clause is never said to be repaid '
  '(barred_proceeding on the client space, « Avances », the client''s page, the run page, « Désimputer », the nightly), '
  'paid or not; (M2c-7d-2, R3) nor one born on or after the judgment, nor under a claw-back clause (L4, Q11)');
-- (review round 3) a credit's date is the day the money was received — the payment's own entry (its value date on the
-- own account, the line's booking date on the dedicated one), never its recording: Lilas, in redressement since d − 3,
-- pays 50,00 € value-dated d − 2 and 70,00 € on the dedicated account booked d − 1, both recorded today; Moreau, with
-- nothing open, 5,00 € value-dated d − 4. The client space and « Ce que le client doit au cabinet » carry received_on
-- (and created_on, the recording day the nightly's 15-day alert reads)
create or replace function pg_temp.sl10() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); v_l uuid; r jsonb; r2 jsonb; r3 jsonb;
begin
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, note, recorded_by)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c('a2'), 'proceeding_opened', d - 3, pg_temp.ev('8', 'a2'),
          'Redressement judiciaire (test)', '10000000-0000-0000-0000-000000000004');
  r := pg_temp.cpay('l10', 'a2', '50,00', p_value => d - 2);
  v_l := pg_temp.ctin('9c1', 7000, pg_temp.iban_of('a2'), 'Virement');
  r2 := pg_temp.cline('l10b', v_l);
  r3 := pg_temp.cpay('l10c', 'a9', '5,00', p_value => d - 4, p_expected => '0');
  return jsonb_build_object(
    'entries', jsonb_build_array(
      (select e.effective_date - d from public.ledger_entry e where e.id = (r ->> 'entry_id')::uuid),
      (select e.effective_date - d from public.ledger_entry e where e.id = (r2 ->> 'entry_id')::uuid),
      (select e.effective_date - d from public.ledger_entry e where e.id = (r3 ->> 'entry_id')::uuid)),
    'space', (select jsonb_agg(jsonb_build_array(x ->> 'cause', x ->> 'open_minor', (x ->> 'received_on')::date - d,
                                                 (x ->> 'created_on')::date - d))
              from jsonb_array_elements(pg_temp.read_as('08', format('select public.client_space_credits(%L)',
                                                                      pg_temp.c('a2'))) -> 'rows') x),
    'page', (select jsonb_agg(jsonb_build_array(x ->> 'cause', x ->> 'open_minor', (x ->> 'received_on')::date - d,
                                                (x ->> 'created_on')::date - d))
             from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_open_documents(%L, ''EUR'')',
                                                                     pg_temp.c('a2'))) -> 'credits') x),
    'overpaid', jsonb_build_array(
      (select jsonb_agg(jsonb_build_array(x ->> 'cause', (x ->> 'received_on')::date - d, (x ->> 'created_on')::date - d))
       from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_space_credits(%L)',
                                                               pg_temp.c('a9'))) -> 'rows') x),
      (select jsonb_agg(jsonb_build_array(x ->> 'cause', (x ->> 'received_on')::date - d, (x ->> 'created_on')::date - d))
       from jsonb_array_elements(pg_temp.read_as('01', format('select public.client_open_documents(%L, ''EUR'')',
                                                               pg_temp.c('a9'))) -> 'credits') x)));
end $$;
select is(pg_temp.iso('sl10'),
  '{"entries": [-2, -1, -4],
    "space": [["procedure", "5000", -2, 0], ["procedure", "7000", -1, 0]],
    "page": [["procedure", "5000", -2, 0], ["procedure", "7000", -1, 0]],
    "overpaid": [[["overpayment", -4, 0]], [["overpayment", -4, 0]]]}'::jsonb,
  'c: a credit is dated by the money''s receipt (its payment''s entry: the value date, the line''s booking date), its '
  'recording day apart — the client space and the client''s page');


-- k. At most one client_credit per cause of a payment ([check 1] gap 8) -----------------------------------------------------
create or replace function pg_temp.sk() returns jsonb language plpgsql as $$
declare v_e uuid; ins text := 'insert into public.client_credit (organization_id, client_organization_id, currency, cause, '
                              'amount_minor, entry_id, details) values ';
begin
  perform pg_temp.plant('client_payment_own', 'k1', '[["own_cash", 800], ["client_credit_owed", -800]]');
  v_e := pg_temp.ek('raw-045-k1');
  return jsonb_build_object(
    'one_short', pg_temp.attempt(ins || format('(%L, %L, ''EUR'', ''procedure'', 300, %L, ''[]'') returning 1',
                                               '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), v_e)),
    'two_causes', pg_temp.attempt(ins || format('(%L, %L, ''EUR'', ''procedure'', 300, %L, ''[]''), '
                                                '(%L, %L, ''EUR'', ''overpayment'', 500, %L, null) returning 1',
                                                '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), v_e,
                                                '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), v_e)),
    'same_cause_twice', pg_temp.state(ins || format('(%L, %L, ''EUR'', ''overpayment'', 300, %L, null), '
                                                    '(%L, %L, ''EUR'', ''overpayment'', 500, %L, null)',
                                                    '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), v_e,
                                                    '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'), v_e)),
    'another_client', pg_temp.attempt(ins || format('(%L, %L, ''EUR'', ''overpayment'', 800, %L, null) returning 1',
                                                    '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a2'), v_e)),
    'not_a_payment', pg_temp.attempt(ins || format('(%L, %L, ''EUR'', ''overpayment'', 800, %L, null) returning 1',
                                                   '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a1'),
                                                   (select e.id from public.ledger_entry e
                                                    where e.entry_type = 'cash_in' limit 1))));
end $$;
select is(pg_temp.iso('sk'),
  '{"one_short": "client credit: not the 419 credit of its payment for its client",
    "two_causes": "1", "same_cause_twice": "23505",
    "another_client": "client credit: not the 419 credit of its payment for its client",
    "not_a_payment": "client credit: not the 419 credit of its payment for its client"}'::jsonb,
  'k: one client_credit per cause of a payment — two causes on one entry sum to its −419 line; a second row of a cause '
  'is refused; a row of another client or of no payment is refused');


-- d, e. The dedicated account (§5.2.5): a client's credit that pays the servicer ----------------------------------------
create or replace function pg_temp.sd() returns jsonb language plpgsql as $$
declare v_f uuid; v_l uuid; v_l6 uuid; r jsonb; o jsonb; v_e uuid; w jsonb; v_file uuid; v_share bigint;
begin
  v_f := pg_temp.inv('a4', '60', 200000, '601');
  -- (review round 4) issued the day its lines are booked, yesterday (test only, as Lilas's FC-3): a line settles only
  -- what existed on its booking date (sd4)
  perform pg_temp.issued(v_f, private.paris_today() - 1);
  -- a line with no label naming the invoice, the invoice named without the client's designation: refused
  v_l6 := pg_temp.ctin('706', 1000, pg_temp.iban_of('a4'), 'Virement');
  w := jsonb_build_object(
    'undesignated', pg_temp.cline('d0', v_l6, array[v_f], p_expected => '36000') ->> 'error');
  -- Lambert's credit of 365,00 € labelled with the invoice's number: the label is the client's designation
  v_l := pg_temp.ctin('701', 36500, pg_temp.iban_of('a4'), 'Reglement ' || pg_temp.num(v_f) || ' merci');
  o := pg_temp.read_as('01', format('select public.client_payment_line(%L)', v_l));
  -- what it may settle is no longer what the page showed: refused, nothing booked
  w := w || jsonb_build_object('changed', pg_temp.cline('d1x', v_l, array[v_f], p_expected => '35999') ->> 'error');
  r := pg_temp.cline('d1', v_l, array[v_f]);
  v_e := (r ->> 'entry_id')::uuid;
  v_share := pg_temp.share();
  v_file := (pg_temp.gen('01', 'gen-045-d-sweep') ->> 'file_id')::uuid;
  return w || jsonb_build_object(
    'line', jsonb_build_array(o ->> 'client_id' = pg_temp.c('a4')::text, o ->> 'amount_minor', o ->> 'refusal',
                              o -> 'named_documents' = jsonb_build_array(v_f), o #>> '{preview,open_minor}'),
    'settled', (select jsonb_agg(jsonb_build_array(x ->> 'document_id' = v_f::text, x ->> 'amount_minor',
                                                   x ->> 'vat_moved_minor'))
                from jsonb_array_elements(r -> 'settled') x),
    'credit', r ->> 'credit_minor',
    'entry', (select jsonb_build_array(e.entry_type, e.effective_date = private.paris_today() - 1, e.source_type,
                                       e.source_id = v_l::text, e.client_organization_id = pg_temp.c('a4'),
                                       e.idempotency_key = 'cpayd:' || v_l)
              from public.ledger_entry e where e.id = v_e),
    'books', pg_temp.books(v_e), 'bookings', pg_temp.bookings(v_l), 'review', pg_temp.review(v_l),
    -- not a debtor's payment: no payment row (so no R124-6 receipt, CPCE-07)
    'payments', (select count(*) from public.payment p where p.bank_transaction_id = v_l),
    'settlements', pg_temp.sets(v_f), 'credits', pg_temp.ccs('a4'),
    'replay', pg_temp.cline('d1', v_l, array[v_f], p_expected => '36000') = r,
    'again', pg_temp.cline('d2', v_l, array[v_f], p_expected => '0') ->> 'error',
    'dirty', pg_temp.dirty(), 'checks', pg_temp.cchecks(),
    -- the servicer's share on 4679 grew by it: the next file's sweep takes it
    'share', v_share, 'sweep', (pg_temp.sweep(v_file)).amount_minor);
end $$;
select is(pg_temp.iso('sd'),
  '{"undesignated": "client payment refused: designation_evidence_required",
    "changed": "client payment refused: open_changed",
    "line": [true, "36500", null, true, "36000"], "settled": [[true, "36000", "6000"]], "credit": "500",
    "entry": ["client_payment_dedicated", true, "bank_transaction", true, true, true],
    "books": {"client_money_cash": 36500, "due_to_servicer": -36500, "due_from_client_funds": 36500,
              "commission_receivable": -36000, "client_credit_owed": -500, "vat_pending": 6000, "vat_collected": -6000},
    "bookings": ["1 client_payment 36500"], "review": null, "payments": 0, "settlements": [["payment_dedicated", 36000, 6000]],
    "credits": [["overpayment", 500, 500]], "replay": true, "again": "client payment refused: line_booked",
    "dirty": [], "checks": [], "share": -36500, "sweep": 36500}'::jsonb,
  'd: a client''s credit on the dedicated account (its confirmed IBAN; the label naming its invoice is its designation) '
  '— +5120 / −4679 ‖ +4689 / −4111 / −419 ‖ VAT; booked on its line, its review gone; I9, I19 clean; the next file''s '
  'sweep takes it; booked once');

create or replace function pg_temp.sd2() returns jsonb language plpgsql as $$
declare v_l uuid; v_c uuid;
begin
  -- Lilas's rejected proposal carrying Martin's IBAN never attributes a credit from it ([critic] M7-MONEY-12) (test
  -- only: the accounts planted in their states, their guard set aside)
  alter table public.client_payout_account disable trigger client_payout_account_guard;
  insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                            evidence_document_id, proposed_by, status, closed_by, closed_at,
                                            closed_reason)
  values ('90000000-0000-0000-0000-0000000001a2', '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a2'), 'EUR',
          pg_temp.iban_of('a1'), 'LILAS FINANCE', 'd0000000-0000-0000-0000-0000000002a2',
          '10000000-0000-0000-0000-000000000004', 'rejected', '10000000-0000-0000-0000-000000000001', now(),
          'IBAN erroné (test)');
  v_l := pg_temp.ctin('707', 1000, pg_temp.iban_of('a1'));
  v_c := (pg_temp.read_as('01', format('select public.client_payment_line(%L)', v_l)) ->> 'client_id')::uuid;
  -- …but a retired account of Cyprès once confirmed with that IBAN does: two clients
  insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                            evidence_document_id, proposed_by, status, confirmed_by, confirmed_at,
                                            confirmed_via, closed_by, closed_at, closed_reason)
  values ('90000000-0000-0000-0000-0000000001a3', '00000000-0000-0000-0000-0000000000aa', pg_temp.c('a3'), 'EUR',
          pg_temp.iban_of('a1'), 'CYPRES SA', 'd0000000-0000-0000-0000-0000000002a3',
          '10000000-0000-0000-0000-000000000004', 'retired', '10000000-0000-0000-0000-000000000001', now(),
          'second_admin', '10000000-0000-0000-0000-000000000001', now(), 'Remplacé (test)');
  alter table public.client_payout_account enable always trigger client_payout_account_guard;
  return jsonb_build_object(
    'martin', v_c = pg_temp.c('a1'),
    'ambiguous', pg_temp.cline('e1', v_l, p_expected => '0') ->> 'error',
    'kinds', jsonb_build_array(
      -- a debtor's credit and an own credit, each from the IBAN of a client's confirmed account: refused for their
      -- kind alone (mutant: an own credit accepted)
      pg_temp.cline('e2', pg_temp.ctin('702', 1000, pg_temp.iban_of('a4'), null, 'debtor_credit'),
                    p_expected => '0') ->> 'error',
      pg_temp.cline('e3', pg_temp.ctin('703', 1000, pg_temp.iban_of('a4'), null, 'own_transfer_in'),
                    p_expected => '0') ->> 'error',
      pg_temp.cline('e4', pg_temp.ctin('704', 1000, pg_temp.iban_of('a4'), null, 'client_transfer_in', 'RMT0123456789AB'),
                    p_expected => '0') ->> 'error',
      pg_temp.cline('e5', pg_temp.ctin('705', 1000, pg_temp.iban_of('a4'), 'Remboursement TOP0123456789AB'),
                    p_expected => '0') ->> 'error',
      pg_temp.cline('e6', pg_temp.ctin('708', 1000, pg_temp.iban_of('a4'), 'Virement SWP0123456789AB'),
                    p_expected => '0') ->> 'error'),
    'roles', jsonb_build_array(pg_temp.cline('e7', pg_temp.ctin('709', 1000, pg_temp.iban_of('a4')), p_expected => '0',
                                             p_user => '02') ->> 'error',
                               pg_temp.cline('e8', pg_temp.l2('709', 1), p_expected => '0', p_aal => 'aal1') ->> 'error'),
    -- the fixture's servicer only: what other runs left on the stack (an E2E, the integration tests) is not its
    'nothing_booked', (select count(*) from public.bank_line_booking b
                       where b.organization_id = '00000000-0000-0000-0000-0000000000aa' and b.kind = 'client_payment'));
end $$;
select is(pg_temp.iso('sd2'),
  '{"martin": true, "ambiguous": "client payment refused: ambiguous_client",
    "kinds": ["client payment refused: not_a_client_credit", "client payment refused: not_a_client_credit",
              "client payment refused: our_reference", "client payment refused: our_reference",
              "client payment refused: our_reference"],
    "roles": ["not allowed", "not allowed"], "nothing_booked": 0}'::jsonb,
  'e: the client is the one whose confirmed account carries the IBAN (a rejected proposal never), several → '
  'ambiguous_client; a debtor''s or an own credit, a line naming our transfer or our top-up are refused; money staff at '
  'aal2 only');

-- (F7) the line is taken under the funds pass's lock order: a line linked meanwhile is refused line_booked
create or replace function pg_temp.sd3() returns jsonb language plpgsql as $$
declare v_l uuid;
begin
  v_l := pg_temp.ctin('710', 1000, pg_temp.iban_of('a4'));
  perform pg_temp.link('lk-045-d3', v_l, 'explained', null, null, null);
  return jsonb_build_object('linked', pg_temp.cline('d3', v_l, p_expected => '0') ->> 'error');
end $$;
select is(pg_temp.iso('sd3'), '{"linked": "client payment refused: line_booked"}'::jsonb,
  'd: a line already explained (« Classer sans comptabiliser ») is not also booked as a client payment');

-- (review round 4) a line booked the day before an invoice's issue never settles it: its label naming the invoice is no
-- designation then (the invoice did not exist), named anyway it is refused bad_date with the issue day, and the line is
-- all a credit owed back (no 4111, no VAT moved); a line of the issue day settles it
create or replace function pg_temp.sd4() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); v_f uuid; v_l uuid; v_l2 uuid; o jsonb; o2 jsonb; r jsonb; r2 jsonb; w jsonb;
begin
  v_f := pg_temp.inv('a4', '60', 200000, '601');
  v_l := pg_temp.ctin('741', 36000, pg_temp.iban_of('a4'), 'Reglement ' || pg_temp.num(v_f), p_day => d - 1);
  o := pg_temp.read_as('01', format('select public.client_payment_line(%L)', v_l));
  w := jsonb_build_object(
    'named', o -> 'named_documents', 'preview', jsonb_build_array(o #>> '{preview,open_minor}',
                                                                  o #>> '{preview,credit_minor}'),
    'named_anyway', pg_temp.why(format(
      'select public.book_client_payment_line(''cpayl-045-d40'', %L, %L, null, null, ''36000'', ''Règlement (test)'')',
      v_l, array[v_f])));
  r := pg_temp.cline('d41', v_l);
  w := w || jsonb_build_object(
    'booked', jsonb_build_array(r -> 'settled', r ->> 'credit_minor',
                                pg_temp.books((r ->> 'entry_id')::uuid) ?| array['commission_receivable', 'vat_pending'],
                                pg_temp.ccs('a4')),
    'invoice_open', private.document_open(v_f));
  v_l2 := pg_temp.ctin('742', 36000, pg_temp.iban_of('a4'), 'Reglement ' || pg_temp.num(v_f), p_day => d);
  o2 := pg_temp.read_as('01', format('select public.client_payment_line(%L)', v_l2));
  r2 := pg_temp.cline('d42', v_l2, (select array_agg(x::uuid) from jsonb_array_elements_text(o2 -> 'named_documents') x));
  return w || jsonb_build_object(
    'on_issue', jsonb_build_array(jsonb_array_length(o2 -> 'named_documents'), r2 #>> '{settled,0,amount_minor}',
                                  r2 ->> 'credit_minor'),
    'dirty', pg_temp.dirty());
end $$;
select is(pg_temp.iso('sd4'),
  ('{"named": [], "preview": ["0", "36000"],
     "named_anyway": ["client payment refused: bad_date", "' || private.paris_today() || '"],
     "booked": [[], "36000", false, [["overpayment", 36000, 36000]]], "invoice_open": 36000,
     "on_issue": [1, "36000", "0"], "dirty": []}')::jsonb,
  'd: (review round 4) a line booked the day before an invoice''s issue never settles it — its label is no designation '
  'then, named anyway refused bad_date with the issue day, the line all a credit owed back; a line of the issue day '
  'settles it');


-- r. « Enregistrer le remboursement » (§5.2.6) ------------------------------------------------------------------------------
-- Roux: FC-R (36 000) set off in full by its run; a credit note of 100,00 € HT on it: 12 000 owed back to the client
create or replace function pg_temp.sr() returns jsonb language plpgsql as $$
declare v_f uuid; v_cn uuid; w jsonb; r jsonb; d date := private.paris_today();
begin
  v_f := pg_temp.inv('a5', '80', 200000, '801', 36000, 6000);
  perform pg_temp.as_user('04');
  set local role authenticated;
  v_cn := (public.issue_credit_note('cn-045-r', v_f, '100,00', 'terms_error', 'taux erroné (test)', '30000')
           ->> 'credit_note_id')::uuid;
  reset role;
  w := jsonb_build_object(
    'owed', private.document_open(v_cn), 'alert', pg_temp.rrc('credit_refund_owed', d + 31) -> 0 -> 1,
    'collector', pg_temp.crfd('r1', v_cn, '10,00', p_user => '02') ->> 'error',
    'aal1', pg_temp.crfd('r2', v_cn, '10,00', p_aal => 'aal1') ->> 'error',
    'bad', jsonb_build_array(pg_temp.crfd('r3', v_cn, 'abc') ->> 'error', pg_temp.crfd('r4', v_cn, '0') ->> 'error'),
    'exceeds', pg_temp.crfd('r5', v_cn, '120,01') ->> 'error',
    'changed', pg_temp.crfd('r6', v_cn, '10,00', p_expected => '11999') ->> 'error',
    'future', pg_temp.crfd('r7', v_cn, '10,00', d + 1) ->> 'error',
    'no_evidence', pg_temp.crfd('r8', v_cn, '10,00', p_ev => 'none') ->> 'error',
    'wrong_kind', pg_temp.crfd('r9', v_cn, '10,00', p_ev => pg_temp.ev('5', 'a5')::text) ->> 'error',
    'invoice', pg_temp.crfd('r10', v_f, '10,00', p_expected => '0') ->> 'error',
    'unknown', pg_temp.crfd('r11', gen_random_uuid(), '10,00', p_expected => '0') ->> 'error',
    -- an approved run whose plan pays the credit note as a refund (planted; rolled back)
    'in_flight', pg_temp.attempt(format(
      'select pg_temp.crfd(''r12'', %L, ''10,00'') ->> ''error'' '
      'from (select pg_temp.pending(''a5'', ''81'', 50000), '
      '             pg_temp.plan_refund(pg_temp.flight(''a5'', ''rf-045''), %L, 12000)) x', v_cn, v_cn)));
  update public.servicer_billing_settings set own_bank_account_id = null
  where organization_id = '00000000-0000-0000-0000-0000000000aa';
  w := w || jsonb_build_object('no_own_account', pg_temp.crfd('r13', v_cn, '10,00') ->> 'error');
  update public.servicer_billing_settings set own_bank_account_id = '80000000-0000-0000-0000-0000000000c0'
  where organization_id = '00000000-0000-0000-0000-0000000000aa';
  -- 50,00 € paid back yesterday, on proof: +4111 / −5122, a refund settlement — (review round 4) the credit note
  -- issued two days ago (test only, as Lilas's FC-3): a refund is never dated before its issue (sr2)
  perform pg_temp.issued(v_cn, d - 2);
  r := pg_temp.crfd('r14', v_cn, '50,00', d - 1);
  w := w || jsonb_build_object(
    'partial', r ->> 'owed_after_minor',
    'entry', (select jsonb_build_array(e.entry_type, e.effective_date = d - 1, e.source_type,
                                       e.source_id = pg_temp.ev('6', 'a5')::text, e.client_organization_id = pg_temp.c('a5'),
                                       e.idempotency_key = 'crfd:' || md5('crfd-045-r14'))
              from public.ledger_entry e where e.id = (r ->> 'entry_id')::uuid),
    'books', pg_temp.books((r ->> 'entry_id')::uuid),
    'settlement', (select jsonb_agg(jsonb_build_array(s.document_kind, s.kind, s.amount_minor, s.vat_moved_minor,
                                                      s.settled_on = d - 1))
                   from public.commission_settlement s where s.entry_id = (r ->> 'entry_id')::uuid),
    'replay', pg_temp.crfd('r14', v_cn, '50,00', d - 1, p_expected => '12000') = r,
    'rest', pg_temp.crfd('r15', v_cn, '70,00') ->> 'owed_after_minor',
    'alert_after', pg_temp.rrc('credit_refund_owed', d + 31),
    'nothing_owed', pg_temp.crfd('r16', v_cn, '1,00') ->> 'error', 'dirty', pg_temp.dirty());
  return w;
end $$;
select is(pg_temp.iso('sr'),
  '{"owed": 12000, "alert": 12000, "collector": "not allowed", "aal1": "not allowed",
    "bad": ["client refund refused: bad_amount", "client refund refused: bad_amount"],
    "exceeds": "client refund refused: amount_exceeds_owed", "changed": "client refund refused: owed_changed",
    "future": "client refund refused: bad_date", "no_evidence": "client refund refused: evidence_required",
    "wrong_kind": "client refund refused: evidence_required", "invoice": "client refund refused: nothing_owed",
    "unknown": "not allowed", "in_flight": "client refund refused: in_flight",
    "no_own_account": "client refund refused: no_own_account",
    "partial": "7000", "entry": ["client_refund_own", true, "document", true, true, true],
    "books": {"commission_receivable": 5000, "own_cash": -5000},
    "settlement": [["credit_note", "refund", 5000, 0, true]], "replay": true, "rest": "0", "alert_after": [],
    "nothing_owed": "client refund refused: nothing_owed", "dirty": []}'::jsonb,
  'r: a credit note''s refund owed paid back from the own account, on proof — +4111 / −5122, a refund settlement, '
  'partial then the rest; credit_refund_owed stops; refused when a run in flight pays it, beyond what is owed, and on '
  'every other refusal');

-- (review round 4) a refund is never dated before what it pays back existed — a credit's receipt (its payment's entry's
-- date), a credit note's issue: refused bad_date with that day in the detail; on that day itself it is recorded
create or replace function pg_temp.sr2() returns jsonb language plpgsql as $$
declare
  d date := private.paris_today(); r jsonb; v_cc uuid; v_f uuid; v_cn uuid; rf jsonb; rn jsonb; w jsonb; v_b bigint;
  q text := 'select public.record_client_refund(%L, %L, %L, %L, %L, %L, ''Virement de remboursement (test)'')';
begin
  -- Moreau, with nothing open, pays 5,00 € value-dated d − 4: a credit received d − 4
  r := pg_temp.cpay('r20', 'a9', '5,00', p_value => d - 4, p_expected => '0');
  v_cc := (select c.id from public.client_credit c where c.entry_id = (r ->> 'entry_id')::uuid);
  -- Roux: a credit note of 100,00 € HT issued today on its invoice set off in full: 12 000 owed back
  v_f := pg_temp.inv('a5', '80', 200000, '801', 36000, 6000);
  perform pg_temp.as_user('04');
  set local role authenticated;
  v_cn := (public.issue_credit_note('cn-045-r2', v_f, '100,00', 'terms_error', 'taux erroné (test)', '30000')
           ->> 'credit_note_id')::uuid;
  reset role;
  v_b := pg_temp.bal('commission_receivable', 'a5', d - 1);
  w := jsonb_build_object(
    'credit_before', pg_temp.why(format(q, 'crfd-045-r21', v_cc, '5,00', d - 5, pg_temp.ev('6', 'a9'), '500')),
    'note_before', pg_temp.why(format(q, 'crfd-045-r22', v_cn, '50,00', d - 1, pg_temp.ev('6', 'a5'), '12000')),
    -- the verifier's probe (pq1): forty days before
    'far_before', jsonb_build_array(pg_temp.crfd('r23', v_cc, '5,00', d - 40) ->> 'error',
                                    pg_temp.crfd('r24', v_cn, '50,00', d - 40) ->> 'error'));
  rf := pg_temp.crfd('r25', v_cc, '5,00', d - 4);
  rn := pg_temp.crfd('r26', v_cn, '50,00', d);
  return w || jsonb_build_object(
    'credit_on_receipt', jsonb_build_array(rf ->> 'owed_after_minor', pg_temp.edate((rf ->> 'entry_id')::uuid) - d),
    'note_on_issue', jsonb_build_array(rn ->> 'owed_after_minor', pg_temp.edate((rn ->> 'entry_id')::uuid) - d),
    -- Moreau's 419 never in debit; Roux's 4111 untouched before the credit note's issue, what it owes after
    'moreau_419', jsonb_build_array(pg_temp.bal('client_credit_owed', 'a9', d - 5),
                                    pg_temp.bal('client_credit_owed', 'a9', d - 4)),
    'roux_4111', jsonb_build_array(pg_temp.bal('commission_receivable', 'a5', d - 1) - v_b,
                                   pg_temp.bal('commission_receivable', 'a5', d)),
    'dirty', pg_temp.dirty());
end $$;
select is(pg_temp.iso('sr2'),
  ('{"credit_before": ["client refund refused: bad_date", "' || (private.paris_today() - 4) || '"],
     "note_before": ["client refund refused: bad_date", "' || private.paris_today() || '"],
     "far_before": ["client refund refused: bad_date", "client refund refused: bad_date"],
     "credit_on_receipt": ["0", -4], "note_on_issue": ["7000", 0],
     "moreau_419": [0, 0], "roux_4111": [0, -7000], "dirty": []}')::jsonb,
  'r: (review round 4) a refund is never dated before what it pays back existed — a credit''s receipt, a credit '
  'note''s issue: refused bad_date with that day; on that day itself it is recorded');


-- o. The page's reads (§5.2.1): staff only ---------------------------------------------------------------------------
create or replace function pg_temp.so() returns jsonb language plpgsql as $$
declare m jsonb := pg_temp.martin(); v_f1 uuid := (m ->> 'f1')::uuid; v_f2 uuid := (m ->> 'f2')::uuid;
        v_a uuid := (m ->> 'a')::uuid; o jsonb; p jsonb; d date := private.paris_today();
begin
  o := pg_temp.read_as('01', format('select public.client_open_documents(%L, ''EUR'')', pg_temp.c('a1')));
  p := pg_temp.read_as('01', format('select public.client_payment_preview(%L, ''EUR'', ''600,00'', null, null)',
                                    pg_temp.c('a1')));
  return jsonb_build_object(
    'invoices', (select jsonb_agg(jsonb_build_array(x ->> 'number' = pg_temp.num((x ->> 'id')::uuid), x ->> 'open_minor',
                                                    x ->> 'pending_vat_minor', (x ->> 'due_date')::date - d,
                                                    x -> 'before_opening', x -> 'payable', x -> 'in_flight_run')
                                  order by x ->> 'number')
                 from jsonb_array_elements(o -> 'invoices') x),
    'advances', (select jsonb_agg(jsonb_build_array(x ->> 'id' = v_a::text, x ->> 'cause', x ->> 'open_minor',
                                                    (x ->> 'born_on')::date - d, x ->> 'recovery', x -> 'payable'))
                 from jsonb_array_elements(o -> 'advances') x),
    'others', jsonb_build_array(o -> 'refunds_owed', o -> 'credits', o -> 'written_off', o -> 'procedure',
                                o -> 'own_account', o ->> 'default_open_minor'),
    'default_order', (select jsonb_agg(case x ->> 'document_id' when v_f1::text then 'f1' when v_f2::text then 'f2'
                                       when v_a::text then 'a' end order by n)
                      from jsonb_array_elements(o -> 'default_order') with ordinality x (x, n)),
    'preview', jsonb_build_array(p ->> 'open_minor', p ->> 'credit_minor', p -> 'refusal',
                                 (select jsonb_agg(jsonb_build_array(x ->> 'document_kind', x ->> 'amount_minor',
                                                                     x ->> 'vat_moved_minor') order by (x ->> 'ord')::int)
                                  from jsonb_array_elements(p -> 'rows') x)),
    'preview_refused', jsonb_build_array(
      pg_temp.read_as('01', format('select public.client_payment_preview(%L, ''EUR'', ''abc'', null, null)',
                                   pg_temp.c('a1'))) ->> 'refusal',
      pg_temp.read_as('01', format('select public.client_payment_preview(%L, ''EUR'', ''1,00'', %L, null)',
                                   pg_temp.c('a1'), array[gen_random_uuid()])) ->> 'refusal'),
    'refused', (select jsonb_object_agg(u, pg_temp.read_as(u, format('select public.client_open_documents(%L, ''EUR'')',
                                                                     pg_temp.c('a1'))) ->> 'error')
                from unnest(array['02', '03', '05']) u));
end $$;
select is(pg_temp.iso('so'),
  '{"invoices": [[true, "36000", "6000", 0, false, true, null], [true, "18000", "3000", 30, false, true, null]],
    "advances": [[true, "remitted_reversal", "20000", -2, "request", true]],
    "others": [[], [], [], false, true, "74000"], "default_order": ["f1", "a", "f2"],
    "preview": ["74000", "0", null, [["invoice", "36000", "6000"], ["advance", "20000", "0"], ["invoice", "4000", "667"]]],
    "preview_refused": ["bad_amount", "not_open"],
    "refused": {"02": "not allowed", "03": "not allowed", "05": "not allowed"}}'::jsonb,
  'o: « Ce que le client doit au cabinet » — the open invoices, advances, refunds owed and credits, the default order and '
  'the preview of a payment, from the ledger and the engine; money staff only');


-- i. The new tables (RLS, append-only, change log), the client space, the evidence kinds ([critic] F18, F11) --------------
create or replace function pg_temp.si() returns jsonb language plpgsql as $$
declare r jsonb; v_cc uuid; a6 public.client_advance; v_name text;
        v_docs jsonb := '{}'; k text;
begin
  -- Petit pays 50,00 € with nothing open: a credit owed back
  r := pg_temp.cpay('i1', 'a8', '50,00', p_expected => '0');
  v_cc := (select c.id from public.client_credit c where c.client_organization_id = pg_temp.c('a8'));
  a6 := pg_temp.adv('a6', '41', 50000, '411');
  perform pg_temp.wo('i2', a6.id, '100,00', '50000', p_evidence => 'd0000000-0000-0000-0000-0000000003a6');
  perform pg_temp.cpay('i3', 'a6', '100,00', p_docs => array[]::uuid[], p_desig => pg_temp.ev('7', 'a6'),
                       p_recover => array[a6.id]);
  -- the evidence kinds, each registered by an ops manager for Petit at a client key of Petit
  foreach k in array array['client_payment_evidence', 'client_refund_evidence', 'payment_designation_evidence'] loop
    v_name := 'client/00000000-0000-0000-0000-0000000000aa/00000000-0000-0000-0000-0000000000a8/' || gen_random_uuid()
              || '.pdf';
    insert into storage.objects (bucket_id, name) values ('documents', v_name);
    v_docs := v_docs || jsonb_build_object(k, jsonb_build_array(v_name,
      pg_temp.read_as('01', format('select public.register_client_document(%L, %L, %L, %L, %L, %L, %L)', 'reg-045-' || k,
                                   pg_temp.c('a8'), k, v_name, 'preuve.pdf', repeat('b', 64), 'application/pdf'))
        ->> 'document_id'));
  end loop;
  return jsonb_build_object(
    'credits', (select jsonb_object_agg(u, pg_temp.try(u, 'select count(*) from public.client_credit'))
                from unnest(array['01', '03', '07', '08', '02', '05']) u),
    'recoveries', (select jsonb_object_agg(u, pg_temp.try(u, 'select count(*) from public.advance_write_off_recovery'))
                   from unnest(array['01', '03', '07', '08', '02', '05']) u),
    'account_419', (select jsonb_object_agg(u, pg_temp.try(u, 'select count(*) from public.ledger_account '
                                                              'where book = ''client_credit_owed'''))
                    from unnest(array['01', '03', '02']) u),
    -- the balance of each new book by its id (public.ledger_balance): money staff only
    'balance_419', (select jsonb_object_agg(u, pg_temp.try(u, format('select public.ledger_balance(%L)', la.id)))
                    from unnest(array['01', '03', '02']) u
                    cross join (select l.id from public.ledger_account l
                                where l.book = 'client_credit_owed' and l.client_organization_id = pg_temp.c('a8')) la),
    'balance_7714', (select jsonb_object_agg(u, pg_temp.try(u, format('select public.ledger_balance(%L)', la.id)))
                     from unnest(array['01', '03', '02']) u
                     cross join (select l.id from public.ledger_account l
                                 where l.book = 'written_off_recovered'
                                   and l.organization_id = '00000000-0000-0000-0000-0000000000aa') la),
    'space', jsonb_build_array(
      (select jsonb_agg(jsonb_build_array(x ->> 'cause', x ->> 'open_minor', (x ->> 'created_on')::date = private.paris_today()))
       from jsonb_array_elements(pg_temp.read_as('03', format('select public.client_space_credits(%L)', pg_temp.c('a8')))
                                 -> 'rows') x),
      pg_temp.read_as('03', format('select public.client_space_credits(%L)', pg_temp.c('a8'))) -> 'total',
      pg_temp.read_as('08', format('select public.client_space_credits(%L)', pg_temp.c('a8'))) ->> 'error',
      pg_temp.read_as('07', format('select public.client_space_credits(%L)', pg_temp.c('a8'))) ->> 'error'),
    'grants', jsonb_build_array(
      (select c.relrowsecurity from pg_class c where c.oid = 'public.client_credit'::regclass),
      (select c.relrowsecurity from pg_class c where c.oid = 'public.advance_write_off_recovery'::regclass),
      has_table_privilege('anon', 'public.client_credit', 'select'),
      has_table_privilege('authenticated', 'public.client_credit', 'insert'),
      has_table_privilege('authenticated', 'public.advance_write_off_recovery', 'insert'),
      has_function_privilege('authenticated', 'private.client_credit_open(uuid)', 'execute'),
      has_function_privilege('authenticated', 'private.client_settlement_plan(uuid, char, bigint, uuid[], uuid[], date)',
                             'execute'),
      has_function_privilege('anon', 'public.record_client_payment(text, uuid, char, text, date, uuid, uuid[], uuid, '
                                     'uuid[], text, text)', 'execute')),
    'append_only', jsonb_build_array(
      pg_temp.state(format('update public.client_credit set amount_minor = 1 where id = %L', v_cc)),
      pg_temp.state(format('delete from public.client_credit where id = %L', v_cc)),
      pg_temp.state('update public.advance_write_off_recovery set amount_minor = 1'),
      pg_temp.state('delete from public.advance_write_off_recovery')),
    'change_log', jsonb_build_array(
      (select count(*) from private.change_log l where l.table_name = 'public.client_credit' and l.row_id = v_cc::text
         and l.op = 'INSERT'),
      (select count(*) from private.change_log l where l.table_name = 'public.advance_write_off_recovery'
         and l.op = 'INSERT')),
    'evidence', (select jsonb_object_agg(e.key, jsonb_build_array(
                   (select d.kind from public.document d where d.id = (e.value ->> 1)::uuid),
                   (select jsonb_object_agg(u, pg_temp.try(u, format('select count(*) from public.document where id = %L',
                                                                     e.value ->> 1)))
                    from unnest(array['01', '04', '03', '07', '02', '05']) u),
                   (select jsonb_object_agg(u, pg_temp.try(u, format('select count(*) from storage.objects where name = %L',
                                                                     e.value ->> 0)))
                    from unnest(array['01', '03', '02']) u)))
                 from jsonb_each(v_docs) e));
end $$;
select is(pg_temp.iso('si'),
  '{"credits": {"01": "1", "03": "1", "07": "0", "08": "0", "02": "0", "05": "0"},
    "recoveries": {"01": "1", "03": "0", "07": "0", "08": "0", "02": "0", "05": "0"},
    "account_419": {"01": "1", "03": "0", "02": "0"},
    "balance_419": {"01": "-5000", "03": "not allowed", "02": "not allowed"},
    "balance_7714": {"01": "-10000", "03": "not allowed", "02": "not allowed"},
    "space": [[["overpayment", "5000", true]], [{"currency": "EUR", "open_minor": "5000"}], "not allowed", "not allowed"],
    "grants": [true, true, false, false, false, false, false, false],
    "append_only": ["23514", "23514", "23514", "23514"], "change_log": [1, 1],
    "evidence": {"client_payment_evidence": ["client_payment_evidence", {"01": "1", "04": "1", "03": "0", "07": "0",
                                                                          "02": "0", "05": "0"},
                                             {"01": "1", "03": "0", "02": "0"}],
                 "client_refund_evidence": ["client_refund_evidence", {"01": "1", "04": "1", "03": "0", "07": "0",
                                                                        "02": "0", "05": "0"},
                                            {"01": "1", "03": "0", "02": "0"}],
                 "payment_designation_evidence": ["payment_designation_evidence", {"01": "1", "04": "1", "03": "0",
                                                                                    "07": "0", "02": "0", "05": "0"},
                                                  {"01": "1", "03": "0", "02": "0"}]}}'::jsonb,
  'i: a client''s whole-client members read its credits owed back (never a restricted viewer, a collector or another '
  'tenant), recoveries, the 419 and 7714 accounts and their balances are staff-only, both tables append-only with '
  'their change log; the client space states its credits; the evidence kinds are registered by money staff and read '
  '(row and file) by money staff only');


-- x. The full list of codes run_advance_checks emits (043 #33, 044 h F12; [critic] F12) -----------------------------------
create or replace function pg_temp.sx() returns jsonb language plpgsql as $$
declare a public.client_advance; c uuid;
begin
  -- 7c-1: a credit owed back (its command first: the raw reversal below would fail its commit checks), a 419 posting
  -- and a 7714 posting without their rows
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
    "written_off_recovery_ledger"]'::jsonb,
  'x (F12): run_advance_checks emits exactly advance_ledger, advance_open, client_credit_ledger, client_credit_owed, '
  'remitted_reversal_uncovered, written_off_recovery_ledger (later slices extend this list)');


-- d. The default order itself (§5.2.3; founder Q4, OQ-89): due invoices by due date, then advances oldest born first and,
-- born the same day, in the order they were recorded, then the invoices not yet due (the pure core, no fixture) --------
select is(
  (select jsonb_agg(right(o.id::text, 2) order by o.n)
   from private.client_payment_order(
     '[{"kind": "invoice", "id": "00000000-0000-0000-0000-0000000000f2", "open": "12000", "due_date": "2026-11-30", "year": 2026, "seq": 2},
       {"kind": "advance", "id": "00000000-0000-0000-0000-0000000000a1", "open": "20000", "born_on": "2026-11-12", "created_at": "2026-11-12T10:00:00Z"},
       {"kind": "advance", "id": "00000000-0000-0000-0000-0000000000a3", "open": "5000", "born_on": "2026-11-12", "created_at": "2026-11-12T09:00:00Z"},
       {"kind": "advance", "id": "00000000-0000-0000-0000-0000000000a2", "open": "5000", "born_on": "2026-11-02", "created_at": "2026-11-15T09:00:00Z"},
       {"kind": "invoice", "id": "00000000-0000-0000-0000-0000000000f3", "open": "1000", "due_date": "2026-11-15", "year": 2026, "seq": 3},
       {"kind": "invoice", "id": "00000000-0000-0000-0000-0000000000f1", "open": "36000", "due_date": "2026-11-10", "year": 2026, "seq": 5}]',
     date '2026-11-20') o),
  '["f1", "f3", "a2", "a3", "a1", "f2"]'::jsonb,
  'd: the default order — the due invoices by due date (10/11 before 15/11, whatever their numbers), the advances '
  'oldest born first and, born the same day, in their recording order, then the invoice not yet due');


-- The switch is still off (no M2c-7 migration writes it) --------------------------------------------------------------------
select is(private.switch_on('downloaded_file_cancellation'), false,
  'the cancellation-after-download switch is still off');

select * from finish();
rollback;
