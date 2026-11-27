-- M2c-7d-3 « declarations, liquidation, statement » (plan docs/design/m2c-7-plan.md §6.1 the disposition table, §6.2.8's
-- statement fr-4, §6.2.10's 7d-3 part, §6.3 claims_to_declare, post_opening_unpaid, payout_after_liquidation, §6.6
-- 046c; ADR-0014 « M2c-7d-3 »). Every rule the law does not fix is the servicer's default (founder Q8, Q11, Q19; OQ-41,
-- OQ-92, OQ-93, OQ-99), never presented as the law's. Texts read on LibreJustice on 2026-11-25 (C. com. L622-24,
-- L622-26, R622-24, L622-17, L641-3, L641-9, L641-13; CPCE R124-6; C. civ. 2008).
--   d     claims_to_declare ([critic] L8, L4; [check 2] reading 7d-1's declared items): a client in a proceeding or a
--         liquidation, per document — an open invoice born before the opening, an open advance whatever its birth —, its
--         deadline (two months after the BODACC publication for a claim born before the opening, R622-24; after its
--         exigibility for one born after, L622-24 al. 6 — the advance's date by default, OQ-92), « date de publication à
--         saisir » without it, P0 from 15 days before; stopped per document by a declaration naming it; advance_open
--         silent for such an advance (carried item 1: each in exactly one alert);
--         (review round 1, TUI-1) the publication date recorded by recording the event again: the deadline known, and in
--         liquidation the liquidator's account to confirm again (what the help says);
--   u     post_opening_unpaid ([critic] L8): an invoice born on or after the opening, unpaid at its due date (a
--         proceeding: L622-17 IV; a liquidation: L641-13 III), stopped when paid or declared;
--         (review round 2) a run's own invoice netted in full whose set-off the debit withheld: unpaid from the debit's
--         day (post_opening_unpaid; invoice_overdue for a client with no opening, e.g. after a death);
--         (review round 3) one whose payout is not debited while the client's invoice bar applies (a liquidation, the
--         mandate's end, a seizure): post_opening_unpaid from the day the bar was recorded;
--   o     invoice_overdue ([critic] L9, L1): silent for an invoice born before the opening and for every invoice of a
--         client in liquidation; firing for an invoice born after a redressement's opening and after a death;
--   l     payout_after_liquidation and its disposition ([critic] L11, [check 1] gap 9): a payout to an account that is not
--         the liquidator's confirmed one, in a file with a requested date on or after the judgment (switch off: not
--         cancellable once downloaded; on: cancellable) or debited on or after it; never a payout debited before, one to
--         the liquidator's account, a sweep; stays after 30 days until a disposition is recorded
--         (record_liquidation_payout_disposition: admins at aal2, its refusals, its replay, already_disposed);
--         (review round 1, TUI-5) a payout in a file not yet downloaded: cancellable whatever the switch; one in a
--         downloaded file requested before the judgment and not debited: never listed;
--   s     the outcome of a set-off set_off_after_bar alerts (carried item 2): « compensation maintenue » recorded with its
--         evidence stops the alert; giving it back is not built (bad_kind);
--         (review round 1, ML-2) the command takes only a settlement the alert names (a set-off valid under C. civ. 2008,
--         barred by the end alone and posted before the servicer recorded it, is refused not_alerted);
--   w     a withheld set-off given back, the giving run's payout returned and paid again (carried item 4): the withheld
--         run's read follows the returned payout's item to the run that repaid it;
--   f     the statement fr-4 (§6.2.8; [critic] L12, L13, M7-MONEY-5): the mandate's end as of K (its date and the day the
--         servicer recorded it, C. civ. 2008), the payee, who it is addressed to (the role only), the withheld item given
--         back, each advance settled with its date; a statement with none of these keeps fr-3's payload (schema 1); the
--         record step takes each payload by its own template only;
--         (review round 1, ML-1) an old « Tutelle ou curatelle » row counts as a tutelle from its qualification: a
--         statement whose K precedes it states no end, a later one the qualification's day; the payee as at K;
--         (review round 3) two ends known on different days: the end at K with its day, and each end the code applied
--         before it with its own (`earlier`);
--   i     the two new tables' isolation, append-only, change log;
--   n     the full list of codes run_advance_checks emits;
--   c     the privileges of the new functions.
-- Each scenario runs in its own rolled-back subtransaction; the ones that touch payouts run with the switch off and on
-- (pg_temp.iso(…, true)) — only payout_after_liquidation's `cancellable` reads it — and a guard at the end checks it is
-- off.
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


-- 046c's own helpers ---------------------------------------------------------------------------------------------------
-- a proceeding or a liquidation of client c effective p_on, published p_pub (none when null), recorded p_ago before now
create or replace function pg_temp.opening(p_c text, p_kind text, p_on date, p_pub date default null,
                                           p_ago interval default '1 minute') returns uuid language sql as $$
  insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date,
                                          evidence_document_id, recorded_by, recorded_at, publication_date)
  values ('00000000-0000-0000-0000-0000000000aa', pg_temp.c(p_c), p_kind, p_on, pg_temp.ev('8', p_c),
          '10000000-0000-0000-0000-000000000004', now() - p_ago, p_pub)
  returning id $$;
-- an advance of client c born on p_day: its collection n of p_amount (the day before) remitted in a run debited p_day,
-- then « Désimputer »-ed (the cover dated at the payout it covers)
create or replace function pg_temp.adv_on(p_c text, p_n text, p_amount bigint, p_s text, p_day date)
returns public.client_advance language plpgsql as $$
begin
  perform pg_temp.remitted(p_c, p_n, p_amount, p_s, p_day, p_day - 1);
  perform pg_temp.unalloc(p_n);
  return pg_temp.adv_of(pg_temp.rev(pg_temp.alloc(p_n)));
end $$;
-- the remittance runs' checks alone into a check run of their own (finished) as of p_today; the run
create or replace function pg_temp.rr_run(p_today date) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_remittance_runs_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return v;
end $$;
-- a check run's rows of a code, each by the name p_names gives its subject ('other' for any other)
create or replace function pg_temp.names(p_run uuid, p_code text, p_names jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_agg(coalesce(n.key, 'other') order by coalesce(n.key, 'other')), '[]')
  from public.payment_check_result c
  left join lateral (select x.key from jsonb_each_text(p_names) x where x.value::uuid = c.subject_id limit 1) n on true
  where c.run_id = p_run and c.code = p_code $$;
-- claims_to_declare's rows by name: [amount, document kind, born before the opening, deadline basis, born (days from
-- p_d), deadline = its anchor + two months (null: none), p0]
create or replace function pg_temp.claims(p_run uuid, p_names jsonb, p_pub date, p_d date) returns jsonb
language sql as $$
  select coalesce(jsonb_object_agg(coalesce(n.key, 'other'), jsonb_build_array(
           c.amount_minor, c.details ->> 'document_kind', (c.details ->> 'pre_opening')::boolean,
           c.details ->> 'deadline_basis', (c.details ->> 'born_on')::date - p_d,
           case when c.details ->> 'deadline' is null then null
                else (c.details ->> 'deadline')::date
                       = (case when (c.details ->> 'pre_opening')::boolean then p_pub
                               else (c.details ->> 'born_on')::date end + interval '2 months')::date end,
           (c.details ->> 'p0')::boolean)), '{}')
  from public.payment_check_result c
  left join lateral (select x.key from jsonb_each_text(p_names) x where x.value::uuid = c.subject_id limit 1) n on true
  where c.run_id = p_run and c.code = 'claims_to_declare' $$;
-- the run's payout to its client: collection n of p_amount (three days ago) on client c's file, the run prepared without
-- commission or set-off (the client's status of the day recorded in its draft), approved, its file generated, written
-- and downloaded (ops 01); the payout (the run kept as run-<key>)
create or replace function pg_temp.out_plain(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v uuid; f uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount);
  v := pg_temp.request(p_c, 'op-' || p_key);
  perform pg_temp.prepare_plain(v);
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'op-' || p_key);
  insert into t values ('run-' || p_key, v) on conflict (k) do update set v = excluded.v;
  f := (pg_temp.gen('01', 'gen-op-' || p_key) ->> 'file_id')::uuid;
  insert into t values ('file-' || p_key, f) on conflict (k) do update set v = excluded.v;
  perform pg_temp.write(f);
  perform pg_temp.download('01', f);
  return pg_temp.rtransfer(v);
end $$;
-- a run of client c with nothing to pay (N = 0: its collection n and that collection's reversal, a same-run pair),
-- prepared with the client's status of the day in its draft and approved (booked at once: no payout, no blockers); the run
create or replace function pg_temp.zero_run(p_c text, p_n text, p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform pg_temp.pending(p_c, p_n, 100000);
  perform private.ledger_reverse(pg_temp.alloc(p_n), 'raw-046c-' || p_n, 'Retour (test)', private.paris_today());
  v := pg_temp.request(p_c, 'zr-' || p_key);
  perform pg_temp.prepare_plain(v);
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'zr-' || p_key);
  return v;
end $$;
-- payout_after_liquidation's rows by name: [status, amount, cancellable, downloaded]
create or replace function pg_temp.pal(p_run uuid, p_names jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_object_agg(coalesce(n.key, 'other'), jsonb_build_array(
           c.details ->> 'status', c.amount_minor, (c.details ->> 'cancellable')::boolean,
           (c.details ->> 'downloaded')::boolean)), '{}')
  from public.payment_check_result c
  left join lateral (select x.key from jsonb_each_text(p_names) x where x.value::uuid = c.subject_id limit 1) n on true
  where c.run_id = p_run and c.code = 'payout_after_liquidation' $$;
-- « Enregistrer la suite » of a payout after a liquidation as p_user (admin 04 at aal2), the evidence the client's status
-- evidence (d…8<c>) unless given: its result, or its error's message
create or replace function pg_temp.disp(p_key text, p_transfer uuid, p_kind text, p_ev uuid default null,
                                        p_note text default 'Ratifié par le liquidateur (test)',
                                        p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
        v_c text := (select right(t.client_organization_id::text, 2) from public.bank_transfer t where t.id = p_transfer);
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_liquidation_payout_disposition('disp-046c-' || p_key, p_transfer, p_kind,
                                                      coalesce(p_ev, pg_temp.ev('8', coalesce(v_c, 'a1'))), p_note);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- « Compensation maintenue » of a set-off set_off_after_bar alerts, as p_user (admin 04 at aal2), the evidence the
-- client's status evidence unless given: its result, or its error's message
create or replace function pg_temp.outc(p_key text, p_entry uuid, p_kind text, p_ev uuid default null,
                                        p_note text default 'Avis de l''avocat : compensation maintenue (test)',
                                        p_user text default '04', p_aal text default 'aal2') returns jsonb
language plpgsql as $$
declare v jsonb;
        v_c text := (select right(e.client_organization_id::text, 2) from public.ledger_entry e where e.id = p_entry);
begin
  perform pg_temp.as_user(p_user, p_aal);
  set local role authenticated;
  begin
    v := public.record_set_off_outcome('outc-046c-' || p_key, p_entry, p_kind,
                                       coalesce(p_ev, pg_temp.ev('8', coalesce(v_c, 'a1'))), p_note);
  exception when others then
    v := jsonb_build_object('error', sqlerrm);
  end;
  reset role;
  return v;
end $$;
-- the withheld read with the run its payout's return was repaid by: [given_back_by, giving_back_by, returned_by]
create or replace function pg_temp.withheld_back(p_run uuid) returns jsonb language sql as $$
  select jsonb_build_array(r ->> 'given_back_by', r ->> 'giving_back_by', r ->> 'returned_by')
  from (select pg_temp.read_as('01', format('select public.remittance_run_withheld(%L)', p_run)) as r) z $$;
-- the statement's payload of a run, as the documents job builds it
create or replace function pg_temp.stmt_of(p_run uuid) returns jsonb language sql as $$
  select private.remittance_statement_build(p_run) $$;
-- the record step for one statement drawn by p_template: 'recorded', or the error's message
create or replace function pg_temp.record_stmt(p_run uuid, p_template text) returns text language plpgsql as $$
declare v jsonb;
begin
  perform private.remittance_documents_begin('00000000-0000-0000-0000-0000000000aa', 10, 10);
  begin
    perform private.remittance_statement_prepare(p_run);
    insert into pg_temp._rd_statement_files (run_id, pdf_sha256, csv_sha256)
    values (p_run, repeat('b', 64), repeat('c', 64));
    v := private.remittance_documents_record('00000000-0000-0000-0000-0000000000aa', p_template,
                                             'facture-commission-fr-3', 'test');
    raise exception 'record rolled back: %', v using errcode = 'TR004';
  exception when sqlstate 'TR004' then
    return 'recorded';
  when others then
    return sqlerrm;
  end;
end $$;
grant execute on all functions in schema pg_temp to authenticated;


-- d. claims_to_declare ([critic] L8, L4; carried item 1) -------------------------------------------------------------
-- Lilas (a2): FC-6 born d − 12, FC-8 born d − 4, A4 born d − 10, A3 born d − 2, all open; Martin (a1, no event) an
-- advance; the redressement opened d − 6, published d − 4. Listed: FC-6 and A4 (born before the opening: two months after
-- the publication, R622-24), A3 (born after: two months after its date, L622-24 al. 6), never FC-8 (born after the
-- opening: post_opening_unpaid's) nor Martin's; P0 from 15 days before the deadline; advance_open at d + 31 lists
-- Martin's advance alone (the client in a proceeding's are to declare: each in one alert); a declaration naming FC-6
-- stops FC-6 alone
create or replace function pg_temp.dc1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f6 uuid; f8 uuid; a3 public.client_advance; a4 public.client_advance;
        m public.client_advance; nm jsonb; w jsonb; dl date; c0 uuid;
begin
  f6 := pg_temp.inv_on('a2', '61', 200000, '610', d - 12);
  f8 := pg_temp.inv_on('a2', '62', 200000, '620', d - 4);
  a4 := pg_temp.adv_on('a2', '64', 50000, '640', d - 10);
  a3 := pg_temp.adv_on('a2', '63', 40000, '630', d - 2);
  m := pg_temp.adv_on('a1', '1d', 30000, '1d0', d - 2);
  perform pg_temp.opening('a2', 'proceeding_opened', d - 6, d - 4);
  nm := jsonb_build_object('fc6', f6, 'fc8', f8, 'a3', a3.id, 'a4', a4.id, 'martin', m.id);
  dl := ((d - 4) + interval '2 months')::date;
  c0 := pg_temp.adv_run(d);
  w := jsonb_build_object(
    'today', pg_temp.claims(c0, nm, d - 4, d),
    'near_deadline', pg_temp.claims(pg_temp.adv_run(dl - 15), nm, d - 4, d) -> 'fc6' -> 6,
    'far', pg_temp.claims(pg_temp.adv_run(dl - 16), nm, d - 4, d) -> 'fc6' -> 6,
    'advance_open_d31', pg_temp.names(pg_temp.adv_run(d + 31), 'advance_open', nm),
    'details', (select jsonb_build_array(c.details ->> 'client_id' = pg_temp.c('a2')::text,
                                         (c.details ->> 'opening_on')::date = d - 6,
                                         c.details ->> 'opening_kind',
                                         (c.details ->> 'publication_date')::date = d - 4,
                                         c.details ->> 'number' is not null, c.subject_type, c.severity)
                from public.payment_check_result c
                where c.run_id = c0 and c.code = 'claims_to_declare' and c.subject_id = f6));
  w := w || jsonb_build_object('declared', pg_temp.code(pg_temp.rec('dc1', 'a2', 'claims_declared', d,
           p_declared => jsonb_build_array(jsonb_build_object('document_kind', 'invoice', 'document_id', f6,
                                                              'amount_minor', '36000')))));
  return w || jsonb_build_object('after', pg_temp.claims(pg_temp.adv_run(d), nm, d - 4, d));
end $$;
select is(pg_temp.iso('dc1'),
  '{"today": {"fc6": [36000, "invoice", true, "publication", -12, true, false],
              "a4": [50000, "advance", true, "publication", -10, true, false],
              "a3": [40000, "advance", false, "exigibility", -2, true, false]},
    "near_deadline": true, "far": false, "advance_open_d31": ["martin"],
    "details": [true, true, "proceeding_opened", true, true, "commission_invoice", "alert"],
    "declared": "ok",
    "after": {"a4": [50000, "advance", true, "publication", -10, true, false],
              "a3": [40000, "advance", false, "exigibility", -2, true, false]}}'::jsonb,
  'd (L8, L4): each document to declare listed with its deadline (two months after the publication for a claim born '
  'before the opening, after its date for an advance born after), P0 from 15 days before; never a post-opening invoice '
  'nor a client with no event; advance_open silent for the client in a proceeding; a declaration stops its document alone');

-- Lambert (a4): a liquidation recorded alone, unpublished: its invoice born before is listed, the deadline unknown
-- (« date de publication à saisir »); every advance of Lambert too; its invoice born after is not. Roux (a5): its invoice
-- set off in full before the redressement: nothing open, nothing listed. Dupont (a6): no event, nothing listed
create or replace function pg_temp.dc2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); l1 uuid; l2 uuid; la public.client_advance; r1 uuid; n1 uuid; nm jsonb;
        c0 uuid;
begin
  l1 := pg_temp.inv_on('a4', '41', 200000, '410', d - 12);
  l2 := pg_temp.inv_on('a4', '42', 200000, '420', d - 3);
  la := pg_temp.adv_on('a4', '43', 25000, '430', d - 2);
  r1 := pg_temp.inv_on('a5', '51', 200000, '510', d - 12, 36000, 6000);
  n1 := pg_temp.inv_on('a6', '61', 200000, '610', d - 12);
  perform pg_temp.opening('a4', 'liquidation', d - 6);
  perform pg_temp.opening('a5', 'proceeding_opened', d - 6, d - 5);
  nm := jsonb_build_object('l1', l1, 'l2', l2, 'la', la.id, 'r1', r1, 'n1', n1);
  c0 := pg_temp.adv_run(d);
  return jsonb_build_object(
    'rows', pg_temp.claims(c0, nm, null, d),
    'opening_kind', (select c.details ->> 'opening_kind' from public.payment_check_result c
                     where c.run_id = c0 and c.code = 'claims_to_declare' and c.subject_id = l1),
    'open', jsonb_build_array(private.document_open(r1)));
end $$;
select is(pg_temp.iso('dc2'),
  '{"rows": {"l1": [36000, "invoice", true, "publication_missing", -12, null, false],
             "la": [25000, "advance", false, "exigibility", -2, true, false]},
    "opening_kind": "liquidation", "open": [0]}'::jsonb,
  'd (L8): a liquidation recorded alone opens the declarations; with no publication recorded the deadline is unknown; '
  'nothing listed for a document already settled, nor for a client with no event');

-- (review round 1, TUI-1) what « date de publication à saisir » asks, as the code does it: no command adds a date to a
-- recorded event (append-only), so the same event is recorded again with its publication date. Roux (a5): its invoice
-- born d − 12; the liquidation effective d − 6 recorded without a publication date; the liquidator's account confirmed
-- after it by a second admin (nothing blocks its payouts). Recorded again (same date of effect, published d − 4): the
-- deadline known (two months after the publication) — and the liquidator's account to confirm again (its confirmation
-- predates the new recording: client_status:liquidation), as the help says
create or replace function pg_temp.dc3() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; nm jsonb; w jsonb;
begin
  f := pg_temp.inv_on('a5', '51', 200000, '510', d - 12);
  perform pg_temp.opening('a5', 'liquidation', d - 6, null, '3 hours');
  perform pg_temp.payee('dc3', 'a5', pg_temp.ib('B'), 'SELARL MJ SYNERGIE', 'court_appointed');
  nm := jsonb_build_object('fc', f);
  w := jsonb_build_object('blockers', pg_temp.blk('a5'), 'claim', pg_temp.claims(pg_temp.adv_run(d), nm, d - 4, d),
                          'again', pg_temp.code(pg_temp.rec('dc3', 'a5', 'liquidation', d - 6, p_publication => d - 4)));
  return w || jsonb_build_object('blockers_after', pg_temp.blk('a5'),
                                 'claim_after', pg_temp.claims(pg_temp.adv_run(d), nm, d - 4, d));
end $$;
select is(pg_temp.iso('dc3'),
  '{"blockers": [], "claim": {"fc": [36000, "invoice", true, "publication_missing", -12, null, false]}, "again": "ok",
    "blockers_after": ["client_status:liquidation"],
    "claim_after": {"fc": [36000, "invoice", true, "publication", -12, true, false]}}'::jsonb,
  'd (TUI-1): the publication date is recorded by recording the event again — the deadline then runs from it; in '
  'liquidation the liquidator''s account is to be confirmed again by a second administrator');


-- u. post_opening_unpaid ([critic] L8) and o. invoice_overdue ([critic] L9, L1) ----------------------------------------
-- Lilas (a2, redressement d − 6, published d − 4): FC-6 born d − 12, FC-8 born d − 4, FC-9 born d − 3 set off in full;
-- Lambert (a4, liquidation d − 6): L1 born d − 12, L2 born d − 3; Durand (a7, death d − 5): D1 born d − 3; Dupont (a6, no
-- event): N1 born d − 3. As of d + 90 (every due date passed):
--   post_opening_unpaid: FC-8 (a proceeding) and L2 (a liquidation) — never FC-9 (paid), FC-6 or L1 (born before: to
--   declare), D1 or N1 (no opening); a declaration naming FC-8 stops it;
--   invoice_overdue: FC-8, D1, N1 — never FC-6 (born before the opening: to declare), L1 or L2 (a client in liquidation).
create or replace function pg_temp.du1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f6 uuid; f8 uuid; f9 uuid; l1 uuid; l2 uuid; d1 uuid; n1 uuid; nm jsonb;
        w jsonb; c90 uuid;
begin
  f6 := pg_temp.inv_on('a2', '61', 200000, '610', d - 12);
  f8 := pg_temp.inv_on('a2', '62', 200000, '620', d - 4);
  f9 := pg_temp.inv_on('a2', '63', 200000, '630', d - 3, 36000, 6000);
  l1 := pg_temp.inv_on('a4', '41', 200000, '410', d - 12);
  l2 := pg_temp.inv_on('a4', '42', 200000, '420', d - 3);
  d1 := pg_temp.inv_on('a7', '71', 200000, '710', d - 3);
  n1 := pg_temp.inv_on('a6', '68', 200000, '680', d - 3);
  perform pg_temp.opening('a2', 'proceeding_opened', d - 6, d - 4);
  perform pg_temp.opening('a4', 'liquidation', d - 6);
  perform pg_temp.evt('a7', 'death', d - 5, '1 minute');
  nm := jsonb_build_object('fc6', f6, 'fc8', f8, 'fc9', f9, 'l1', l1, 'l2', l2, 'd1', d1, 'n1', n1);
  c90 := pg_temp.adv_run(d + 90);
  w := jsonb_build_object(
    'unpaid', pg_temp.names(c90, 'post_opening_unpaid', nm),
    'unpaid_details', (select jsonb_object_agg(n.key, jsonb_build_array(c.amount_minor, c.details ->> 'opening_kind',
                                                                          (c.details ->> 'born_on')::date - d,
                                                                          c.details ->> 'due_date' is not null))
                       from public.payment_check_result c
                       join lateral (select x.key from jsonb_each_text(nm) x where x.value::uuid = c.subject_id) n on true
                       where c.run_id = c90 and c.code = 'post_opening_unpaid'),
    'unpaid_today', pg_temp.names(pg_temp.adv_run(d), 'post_opening_unpaid', nm),
    'overdue', pg_temp.names(pg_temp.rr_run(d + 90), 'invoice_overdue', nm));
  w := w || jsonb_build_object('declared', pg_temp.code(pg_temp.rec('du1', 'a2', 'claims_declared', d,
           p_declared => jsonb_build_array(jsonb_build_object('document_kind', 'invoice', 'document_id', f8,
                                                              'amount_minor', '36000')))));
  return w || jsonb_build_object('unpaid_after', pg_temp.names(pg_temp.adv_run(d + 90), 'post_opening_unpaid', nm),
                                 'overdue_after', pg_temp.names(pg_temp.rr_run(d + 90), 'invoice_overdue', nm));
end $$;
select is(pg_temp.iso('du1'),
  '{"unpaid": ["fc8", "l2"],
    "unpaid_details": {"fc8": [36000, "proceeding_opened", -4, true], "l2": [36000, "liquidation", -3, true]},
    "unpaid_today": [], "overdue": ["d1", "fc8", "n1"], "declared": "ok",
    "unpaid_after": ["l2"], "overdue_after": ["d1", "fc8", "n1"]}'::jsonb,
  'u, o (L8, L9, L1): an invoice born after the opening and unpaid at its due date is post_opening_unpaid (a proceeding or '
  'a liquidation) until paid or declared; invoice_overdue leaves out the invoices born before the opening and every '
  'invoice of a client in liquidation, and still fires after a death or for a post-opening invoice of a redressement');

-- (review round 2) A run's own invoice set off in full by its plan has no due date of its own (paid with its run's
-- payout): once the debit withheld that set-off (7d-2), it is unpaid from the debit's day (private.invoice_withheld_on).
-- Dupont (a6): its collection d − 3, its run nets its own invoice (18 000), the file handed out; then a liquidation
-- effective d − 5 (published d − 4) recorded; the debit d − 1 withholds the set-off → post_opening_unpaid lists the
-- invoice (born d − 3, after the opening) from d, still at d + 200 (after L641-13 III's six months), until a declaration
-- names it; never claims_to_declare (born after) nor invoice_overdue (a client in liquidation). Lilas (a2): a
-- redressement d − 20 (published d − 19) recorded first, its run nets its own invoice (born d − 3: nettable in a
-- redressement), handed out; a liquidation effective d − 2 recorded; the debit withholds → listed (born after the
-- redressement's opening). Durand (a7): its run nets its own invoice, handed out; a death d − 2 recorded; the debit
-- withholds → invoice_overdue lists it from d (no opening: never post_opening_unpaid). Petit (a8, a redressement
-- d − 20): its run nets its own invoice, its payout in the file not yet debited → nothing (its run's payout pays it);
-- debited, set off → nothing. The debit's day itself: not yet listed (as a due date: from the next day)
create or replace function pg_temp.own_netted(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v uuid; f jsonb := jsonb_build_object(p_n, p_amount::text);
begin
  perform pg_temp.pending(p_c, p_n, p_amount);
  v := pg_temp.request(p_c, 'on-' || p_key);
  perform pg_temp.prepare(v, pg_temp.doc(p_c, f, 15, 100), pg_temp.keys(p_c, f, 15, 100),
                          pg_temp.plan(p_c, p_amount, p_amount * 15 / 100, p_amount * 18 / 100, p_amount * 3 / 100));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'on-' || p_key);
  return v;
end $$;
create or replace function pg_temp.du2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); r6 uuid; r2 uuid; r7 uuid; r8 uuid; nm jsonb; w jsonb; c0 uuid; o0 uuid;
        own text := 'select x.id from public.commission_invoice x where x.run_id = %L and x.kind = ''invoice''';
        i6 uuid; i2 uuid; i7 uuid; i8 uuid;
begin
  perform pg_temp.opening('a2', 'proceeding_opened', d - 20, d - 19, '3 hours');
  perform pg_temp.opening('a8', 'proceeding_opened', d - 20, d - 19, '3 hours');
  r6 := pg_temp.own_netted('a6', '6a', 100000, 'du2-6');
  r2 := pg_temp.own_netted('a2', '2a', 100000, 'du2-2');
  r7 := pg_temp.own_netted('a7', '7a', 100000, 'du2-7');
  r8 := pg_temp.own_netted('a8', '8a', 100000, 'du2-8');
  execute format(own, r6) into i6;
  execute format(own, r2) into i2;
  execute format(own, r7) into i7;
  execute format(own, r8) into i8;
  perform pg_temp.handed_out('file-du2', 'gen-file-du2');
  perform pg_temp.opening('a6', 'liquidation', d - 5, d - 4);
  perform pg_temp.opening('a2', 'liquidation', d - 2);
  perform pg_temp.evt('a7', 'death', d - 2, '1 minute');
  perform pg_temp.debit(r6, 'c61', d - 1);
  perform pg_temp.debit(r2, 'c21', d - 1);
  perform pg_temp.debit(r7, 'c71', d - 1);
  nm := jsonb_build_object('dupont', i6, 'lilas', i2, 'durand', i7, 'petit', i8);
  c0 := pg_temp.adv_run(d);
  o0 := pg_temp.rr_run(d);
  w := jsonb_build_object(
    'own', (select jsonb_agg(jsonb_build_array(x.settlement, x.due_date, private.document_open(x.id)) order by x.number)
            from public.commission_invoice x where x.id in (i6, i2, i7, i8)),
    'withheld', jsonb_build_array(pg_temp.ek('settle:' || r6 || ':barred') is not null,
                                  pg_temp.ek('settle:' || r2 || ':barred') is not null,
                                  pg_temp.ek('settle:' || r7 || ':barred') is not null,
                                  pg_temp.ek('settle:' || r8 || ':barred') is not null),
    'unpaid', pg_temp.names(c0, 'post_opening_unpaid', nm),
    'unpaid_details', (select jsonb_object_agg(n.key, jsonb_build_array(c.amount_minor, c.details ->> 'opening_kind',
                                                                          (c.details ->> 'born_on')::date - d,
                                                                          c.details ->> 'due_date',
                                                                          (c.details ->> 'withheld_on')::date - d,
                                                                          c.oldest_days,
                                                                          c.details ->> 'liquidation_on' is not null,
                                                                          -- (review round 3) a withheld invoice is
                                                                          -- dated by its debit, never by the bar
                                                                          c.details ->> 'barred_on'))
                       from public.payment_check_result c
                       join lateral (select x.key from jsonb_each_text(nm) x where x.value::uuid = c.subject_id) n on true
                       where c.run_id = c0 and c.code = 'post_opening_unpaid'),
    'claims', pg_temp.claims(c0, nm, d - 4, d),
    'unpaid_debit_day', pg_temp.names(pg_temp.adv_run(d - 1), 'post_opening_unpaid', nm),
    'unpaid_200', pg_temp.names(pg_temp.adv_run(d + 200), 'post_opening_unpaid', nm),
    'overdue', (select jsonb_object_agg(n.key, jsonb_build_array(c.amount_minor, c.details ->> 'due_date',
                                                                   (c.details ->> 'withheld_on')::date - d, c.oldest_days))
                from public.payment_check_result c
                join lateral (select x.key from jsonb_each_text(nm) x where x.value::uuid = c.subject_id) n on true
                where c.run_id = o0 and c.code = 'invoice_overdue'),
    'overdue_200', pg_temp.names(pg_temp.rr_run(d + 200), 'invoice_overdue', nm));
  perform pg_temp.debit(r8, 'c81', d - 1);
  w := w || jsonb_build_object(
    'petit_debited', jsonb_build_array(private.document_open(i8), pg_temp.ek('settle:' || r8 || ':barred') is null,
                                       pg_temp.names(pg_temp.adv_run(d + 90), 'post_opening_unpaid', nm)),
    'declared', pg_temp.code(pg_temp.rec('du2', 'a6', 'claims_declared', d,
                p_declared => jsonb_build_array(jsonb_build_object('document_kind', 'invoice', 'document_id', i6,
                                                                   'amount_minor', '18000')))));
  w := w || jsonb_build_object('unpaid_after', pg_temp.names(pg_temp.adv_run(d + 200), 'post_opening_unpaid', nm));
  -- the day itself: a barred settlement of Petit's run planted (as when its debit withholds another document of its
  -- plan): its invoice, set off by that run, was not withheld
  perform pg_temp.plant_barred(r8, 'a8', 1000);
  return w || jsonb_build_object('withheld_on', jsonb_build_array(private.invoice_withheld_on(i6) - d,
                                                                  private.invoice_withheld_on(i7) - d,
                                                                  private.invoice_withheld_on(i8)));
end $$;
select is(pg_temp.iso('du2'),
  '{"own": [["netted", null, 18000], ["netted", null, 18000], ["netted", null, 18000], ["netted", null, 18000]],
    "withheld": [true, true, true, false],
    "unpaid": ["dupont", "lilas"],
    "unpaid_details": {"dupont": [18000, "liquidation", -3, null, -1, 1, true, null],
                       "lilas": [18000, "proceeding_opened", -3, null, -1, 1, true, null]},
    "claims": {}, "unpaid_debit_day": [], "unpaid_200": ["dupont", "lilas"],
    "overdue": {"durand": [18000, null, -1, 1]}, "overdue_200": ["durand"],
    "petit_debited": [0, true, ["dupont", "lilas"]], "declared": "ok", "unpaid_after": ["lilas"],
    "withheld_on": [-1, -1, null]}'::jsonb,
  'u (review round 2): a run''s own invoice netted in full whose set-off the debit withheld is unpaid from that day: '
  'post_opening_unpaid after a liquidation (alone, or after a redressement), invoice_overdue after a death; never one '
  'whose run''s payout is still to pay it, nor one it set off');
select is(pg_temp.iso('du2', true), pg_temp.iso('du2'), 'u (review round 2): the same with the switch on');

-- (review round 3) A run's own invoice netted in full whose payout is not debited: once the client's invoice bar applies
-- (private.client_set_off_barred: a liquidation, the mandate's end, a seizure), the payout to come no longer pays it —
-- its set-off would be withheld at the debit, and in liquidation the payout is held — so post_opening_unpaid lists it
-- from the day the bar was recorded (private.client_set_off_bar_recorded_on; the servicer's rule, OQ-92), as a due date
-- (from the next day). Each event is inserted after the run's approval, its recording p_ago before now. Dupont (a6): its
-- run nets its own invoice (18 000, born d − 3), approved, its payout ordered in no file; a liquidation effective d − 5
-- (published d − 4) recorded → not on its recording's day, listed the next day (one day old), still at d + 200 (after
-- L641-13 III's six months); never claims_to_declare (born after) nor invoice_overdue (in liquidation); a declaration
-- naming it stops it. Lilas (a2): a redressement d − 20, its run nets its own invoice (nettable then), ordered; an old
-- « Tutelle ou curatelle » row recorded d − 10, still to qualify (it ends nothing), and a death effective d − 4 recorded
-- d − 3 → listed from the death's recording (the bar the mandate's end); its run cancelled → its full credit note,
-- applied to the invoice at once, annuls it (open 0) and no payout is to come: no longer listed. Roux (a5): a
-- redressement, its run nets its own invoice, ordered; a seizure recorded d − 14 and released, then one effective d − 5
-- recorded d − 2 → listed from the standing one's recording (the bar a seizure). Moreau (a9): a redressement, its run
-- nets its own invoice, ordered; an old row recorded
-- d − 40 qualified a tutelle now → listed from the qualification's day (the code applied the end from it). Petit (a8): a
-- redressement, its run nets its own invoice, ordered, no bar → never listed (its payout pays it). Durand (a7, no
-- opening): its run nets its own invoice, ordered; a death recorded → not post_opening_unpaid (no opening), not
-- invoice_overdue (round 3 leaves invoice_overdue's rule as round 2's: Left open)
create or replace function pg_temp.du3() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); r6 uuid; r2 uuid; r5 uuid; r8 uuid; r7 uuid; r9 uuid; nm jsonb; w jsonb;
        own text := 'select x.id from public.commission_invoice x where x.run_id = %L and x.kind = ''invoice''';
        i6 uuid; i2 uuid; i5 uuid; i8 uuid; i7 uuid; i9 uuid; e6 uuid; e2 uuid; e5 uuid; o9 uuid; q jsonb; c1 uuid;
begin
  perform pg_temp.opening('a2', 'proceeding_opened', d - 20, d - 19, '3 hours');
  perform pg_temp.opening('a5', 'proceeding_opened', d - 20, d - 19, '3 hours');
  perform pg_temp.opening('a8', 'proceeding_opened', d - 20, d - 19, '3 hours');
  perform pg_temp.opening('a9', 'proceeding_opened', d - 20, d - 19, '3 hours');
  r6 := pg_temp.own_netted('a6', '6a', 100000, 'du3-6');
  r2 := pg_temp.own_netted('a2', '2a', 100000, 'du3-2');
  r5 := pg_temp.own_netted('a5', '5a', 100000, 'du3-5');
  r8 := pg_temp.own_netted('a8', '8a', 100000, 'du3-8');
  r7 := pg_temp.own_netted('a7', '7a', 100000, 'du3-7');
  r9 := pg_temp.own_netted('a9', '9a', 100000, 'du3-9');
  execute format(own, r6) into i6;
  execute format(own, r2) into i2;
  execute format(own, r5) into i5;
  execute format(own, r8) into i8;
  execute format(own, r7) into i7;
  execute format(own, r9) into i9;
  e6 := pg_temp.opening('a6', 'liquidation', d - 5, d - 4);
  perform pg_temp.old_tutelle('a2', d - 25, '10 days');
  e2 := pg_temp.evt('a2', 'death', d - 4, '3 days');
  perform pg_temp.evt('a5', 'seizure_released', d - 10, '9 days', pg_temp.evt('a5', 'seizure', d - 15, '14 days'));
  e5 := pg_temp.evt('a5', 'seizure', d - 5, '2 days');
  o9 := pg_temp.old_tutelle('a9', d - 30, '40 days');
  perform pg_temp.qual('du3-9', o9, 'guardianship');
  perform pg_temp.evt('a7', 'death', d - 2, '1 minute');
  nm := jsonb_build_object('dupont', i6, 'lilas', i2, 'roux', i5, 'petit', i8, 'durand', i7, 'moreau', i9);
  -- the Paris day each bar was recorded (Moreau's: its qualification's)
  q := (select jsonb_object_agg(n, (e.recorded_at at time zone 'Europe/Paris')::date)
        from (values ('dupont', e6), ('lilas', e2), ('roux', e5)) v (n, id)
        join public.client_status_event e on e.id = v.id)
       || jsonb_build_object('moreau', (select (x.recorded_at at time zone 'Europe/Paris')::date
                                        from public.client_status_event_qualification x where x.event_id = o9));
  c1 := pg_temp.adv_run(d + 1);
  w := jsonb_build_object(
    'own', (select jsonb_agg(jsonb_build_array(x.settlement, x.due_date, private.document_open(x.id),
                                               pg_temp.status(pg_temp.rtransfer(x.run_id))) order by x.number)
            from public.commission_invoice x where x.id in (i6, i2, i5, i8, i7, i9)),
    'bars', jsonb_build_array(private.client_set_off_barred(pg_temp.c('a6'), d, 'invoice'),
                              private.client_set_off_barred(pg_temp.c('a2'), d, 'invoice'),
                              private.client_set_off_barred(pg_temp.c('a5'), d, 'invoice'),
                              private.client_set_off_barred(pg_temp.c('a9'), d, 'invoice'),
                              private.client_set_off_barred(pg_temp.c('a8'), d, 'invoice')),
    'dupont_on_its_bar_day', pg_temp.names(pg_temp.adv_run((q ->> 'dupont')::date), 'post_opening_unpaid', nm)
                               ? 'dupont',
    'unpaid_d1', pg_temp.names(c1, 'post_opening_unpaid', nm),
    'details', (select jsonb_object_agg(n.key, jsonb_build_array(c.amount_minor, c.details ->> 'opening_kind',
                                                                   (c.details ->> 'born_on')::date - d,
                                                                   c.details ->> 'due_date', c.details ->> 'withheld_on',
                                                                   (c.details ->> 'barred_on')::date
                                                                     = (q ->> n.key)::date,
                                                                   c.details ->> 'bar',
                                                                   c.oldest_days = (d + 1) - (q ->> n.key)::date))
                from public.payment_check_result c
                join lateral (select x.key from jsonb_each_text(nm) x where x.value::uuid = c.subject_id) n on true
                where c.run_id = c1 and c.code = 'post_opening_unpaid'),
    'claims', pg_temp.claims(c1, nm, d - 4, d),
    'unpaid_200', pg_temp.names(pg_temp.adv_run(d + 200), 'post_opening_unpaid', nm),
    'overdue_200', pg_temp.names(pg_temp.rr_run(d + 200), 'invoice_overdue', nm));
  w := w || jsonb_build_object(
    'declared', pg_temp.code(pg_temp.rec('du3', 'a6', 'claims_declared', d,
                p_declared => jsonb_build_array(jsonb_build_object('document_kind', 'invoice', 'document_id', i6,
                                                                   'amount_minor', '18000')))),
    'cancelled', pg_temp.cancel_run(r2, 'du3-2'));
  -- (read in a statement of its own: the cancellation's effects in its snapshot)
  w := w || jsonb_build_object(
    'credited', jsonb_build_array(private.document_open(i2),
                                  (select jsonb_agg(jsonb_build_array(-c.ht_minor, c.applied_minor))
                                   from public.commission_credit_correction c where c.original_invoice_id = i2)));
  return w || jsonb_build_object('unpaid_after', pg_temp.names(pg_temp.adv_run(d + 1), 'post_opening_unpaid', nm));
end $$;
select is(pg_temp.iso('du3'),
  '{"own": [["netted", null, 18000, "ordered"], ["netted", null, 18000, "ordered"], ["netted", null, 18000, "ordered"],
            ["netted", null, 18000, "ordered"], ["netted", null, 18000, "ordered"], ["netted", null, 18000, "ordered"]],
    "bars": ["liquidation", "mandate_ended", "seizure", "mandate_ended", null],
    "dupont_on_its_bar_day": false,
    "unpaid_d1": ["dupont", "lilas", "moreau", "roux"],
    "details": {"dupont": [18000, "liquidation", -3, null, null, true, "liquidation", true],
                "lilas": [18000, "proceeding_opened", -3, null, null, true, "mandate_ended", true],
                "roux": [18000, "proceeding_opened", -3, null, null, true, "seizure", true],
                "moreau": [18000, "proceeding_opened", -3, null, null, true, "mandate_ended", true]},
    "claims": {}, "unpaid_200": ["dupont", "lilas", "moreau", "roux"], "overdue_200": [],
    "declared": "ok", "cancelled": "cancelled",
    "credited": [0, [[15000, 18000]]], "unpaid_after": ["moreau", "roux"]}'::jsonb,
  'u (review round 3): a run''s own invoice netted in full whose payout is not debited is unpaid from the day the '
  'client''s invoice bar was recorded (a liquidation, the mandate''s end as the code applied it, a seizure) — never '
  'while its payout may still pay it, nor once declared or its run cancelled (its credit note annuls it)');
select is(pg_temp.iso('du3', true), pg_temp.iso('du3'), 'u (review round 3): the same with the switch on');


-- l. payout_after_liquidation and its disposition ([critic] L11, [check 1] gap 9) ---------------------------------------
-- Petit (a8): its payout (100 000, to its own IBAN) in a downloaded file; the liquidation (effective d − 2) recorded after
-- the download → listed `in_file` (switch off: not cancellable in Collectoo once downloaded; on: cancellable); debited
-- d − 1 → listed `booked`, still at d + 31; a disposition recorded → gone. Cyprès (a3): its payout debited d − 3, the
-- liquidation effective d − 1 → never listed. Roux (a5): the liquidation recorded first, the liquidator's account
-- confirmed after it with the judgment, its payout to that account in a file then debited → never listed
create or replace function pg_temp.dl1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); p8 uuid; p3 uuid; p5 uuid; nm jsonb; w jsonb; c0 uuid;
begin
  p3 := pg_temp.out_plain('a3', '31', 100000, 'dl1-3');
  perform pg_temp.debit(pg_temp.v('run-dl1-3'), '310', d - 3);
  perform pg_temp.opening('a3', 'liquidation', d - 1);
  perform pg_temp.opening('a5', 'liquidation', d - 5, null, '1 hour');
  perform pg_temp.payee('dl1-5', 'a5', pg_temp.ib('A'), 'SELARL MJ SYNERGIE', 'court_appointed');
  p5 := pg_temp.out_plain('a5', '51', 100000, 'dl1-5');
  p8 := pg_temp.out_plain('a8', '81', 100000, 'dl1-8');
  perform pg_temp.opening('a8', 'liquidation', d - 2);
  nm := jsonb_build_object('p8', p8, 'p3', p3, 'p5', p5);
  c0 := pg_temp.adv_run(d);
  w := jsonb_build_object('in_file', pg_temp.pal(c0, nm),
                          'severity', (select jsonb_build_array(c.severity, c.subject_type, (c.details ->> 'p0')::boolean)
                                       from public.payment_check_result c
                                       where c.run_id = c0 and c.code = 'payout_after_liquidation'
                                       limit 1));
  perform pg_temp.debit(pg_temp.v('run-dl1-8'), '810', d - 1);
  perform pg_temp.debit(pg_temp.v('run-dl1-5'), '510', d - 1);
  w := w || jsonb_build_object('booked', pg_temp.pal(pg_temp.adv_run(d), nm),
                               'later', pg_temp.pal(pg_temp.adv_run(d + 31), nm),
                               'disposed', pg_temp.code(pg_temp.disp('dl1', p8, 'repaid_to_liquidator')));
  return w || jsonb_build_object('after', pg_temp.pal(pg_temp.adv_run(d + 31), nm));
end $$;
select is(pg_temp.iso('dl1'),
  '{"in_file": {"p8": ["in_file", 100000, false, true]}, "severity": ["alert", "bank_transfer", true],
    "booked": {"p8": ["booked", 100000, null, null]}, "later": {"p8": ["booked", 100000, null, null]},
    "disposed": "ok", "after": {}}'::jsonb,
  'l (L11): a payout to the client''s own account after its liquidation is listed in its file (not cancellable in '
  'Collectoo once downloaded, the switch off) and once debited, until a disposition is recorded — never by elapsed time; '
  'never one debited before the judgment nor one to the liquidator''s confirmed account');
select is(pg_temp.iso('dl1', true) -> 'in_file', '{"p8": ["in_file", 100000, true, true]}'::jsonb,
  'l (L11): with the switch on, the payout in its downloaded file is cancellable (the two-step cancellation)');
select is(pg_temp.iso('dl1', true) - 'in_file', pg_temp.iso('dl1') - 'in_file',
  'l (L11): the rest the same with the switch on');

-- record_liquidation_payout_disposition (gap 9): admins at aal2 only; not_after_liquidation for a payout still in its
-- file, one debited before the judgment, one to the liquidator's account and a sweep; bad_kind; evidence_required (none,
-- another client's, not a status evidence); bad_note; recorded; replayed (the same result); already_disposed; the row
create or replace function pg_temp.dl2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); p8 uuid; p3 uuid; p5 uuid; sw uuid; r jsonb; w jsonb;
begin
  p3 := pg_temp.out_plain('a3', '31', 100000, 'dl2-3');
  perform pg_temp.debit(pg_temp.v('run-dl2-3'), '310', d - 3);
  perform pg_temp.opening('a3', 'liquidation', d - 1);
  perform pg_temp.opening('a5', 'liquidation', d - 5, null, '1 hour');
  perform pg_temp.payee('dl2-5', 'a5', pg_temp.ib('A'), 'SELARL MJ SYNERGIE', 'court_appointed');
  p5 := pg_temp.out_plain('a5', '51', 100000, 'dl2-5');
  perform pg_temp.debit(pg_temp.v('run-dl2-5'), '510', d - 1);
  -- a sweep: Martin's run set off its commission (18 %), its payout debited: the next file carries the servicer's share
  perform pg_temp.inflight('a1', '11', 100000, 'dl2-1');
  perform pg_temp.debit(pg_temp.v('run-dl2-1'), '111', d - 1);
  p8 := pg_temp.out_plain('a8', '81', 100000, 'dl2-8');
  sw := (pg_temp.sweep(pg_temp.v('file-dl2-8'))).id;
  perform pg_temp.opening('a8', 'liquidation', d - 2);
  w := jsonb_build_object('in_file', pg_temp.code(pg_temp.disp('dl2-a', p8, 'ratified')));
  perform pg_temp.debit(pg_temp.v('run-dl2-8'), '810', d - 1);
  w := w || jsonb_build_object(
    'ops', pg_temp.code(pg_temp.disp('dl2-b', p8, 'ratified', p_user => '01')),
    'aal1', pg_temp.code(pg_temp.disp('dl2-c', p8, 'ratified', p_aal => 'aal1')),
    'servicer_b', pg_temp.code(pg_temp.disp('dl2-d', p8, 'ratified', p_user => '06')),
    'before', pg_temp.code(pg_temp.disp('dl2-e', p3, 'ratified')),
    'liquidator', pg_temp.code(pg_temp.disp('dl2-f', p5, 'ratified')),
    'sweep', pg_temp.code(pg_temp.disp('dl2-g', sw, 'ratified')),
    'unknown', pg_temp.code(pg_temp.disp('dl2-h', gen_random_uuid(), 'ratified')),
    'bad_kind', pg_temp.code(pg_temp.disp('dl2-i', p8, 'kept')),
    'no_evidence', pg_temp.code(pg_temp.disp('dl2-j', p8, 'ratified', p_ev => gen_random_uuid())),
    'other_client', pg_temp.code(pg_temp.disp('dl2-k', p8, 'ratified', p_ev => pg_temp.ev('8', 'a1'))),
    'rib', pg_temp.code(pg_temp.disp('dl2-l', p8, 'ratified', p_ev => pg_temp.ev('2', 'a8'))),
    'bad_note', pg_temp.code(pg_temp.disp('dl2-m', p8, 'ratified', p_note => repeat('x', 2001))));
  r := pg_temp.disp('dl2-z', p8, 'ratified');
  return w || jsonb_build_object(
    'ok', pg_temp.code(r), 'result', jsonb_build_array(r ->> 'transfer_id' = p8::text, r ->> 'kind'),
    'replay', pg_temp.disp('dl2-z', p8, 'ratified') = r,
    'second', pg_temp.code(pg_temp.disp('dl2-y', p8, 'repaid_to_liquidator')),
    'row', (select jsonb_build_array(x.id::text = r ->> 'disposition_id', x.kind, x.client_organization_id = pg_temp.c('a8'),
                                     x.evidence_document_id = pg_temp.ev('8', 'a8'), x.note,
                                     x.recorded_by = '10000000-0000-0000-0000-000000000004')
            from public.liquidation_payout_disposition x where x.transfer_id = p8));
end $$;
select is(pg_temp.iso('dl2'),
  '{"in_file": "not_after_liquidation", "ops": "not allowed", "aal1": "not allowed", "servicer_b": "not allowed",
    "before": "not_after_liquidation", "liquidator": "not_after_liquidation", "sweep": "not_after_liquidation",
    "unknown": "not allowed", "bad_kind": "bad_kind", "no_evidence": "evidence_required",
    "other_client": "evidence_required", "rib": "evidence_required", "bad_note": "bad_note", "ok": "ok",
    "result": [true, "ratified"], "replay": true, "second": "already_disposed",
    "row": [true, "ratified", true, true, "Ratifié par le liquidateur (test)", true]}'::jsonb,
  'l (gap 9): « Enregistrer la suite » is an administrator''s at aal2, only for a payout made to the client after its '
  'liquidation, with its evidence; replayed by its key; one disposition per payout');

-- (review round 1, TUI-5) the two rules of a payout in its file: Dupont (a6) — its payout in a file generated, not yet
-- downloaded; the liquidation (effective d − 2) recorded after → listed `in_file`, cancellable (its file not downloaded:
-- whatever the switch), not downloaded. Moreau (a9) — its payout in a downloaded file, requested for two days before the
-- judgment, not debited → never listed (in its file, a payout is listed when requested on or after the judgment)
create or replace function pg_temp.out_gen(p_c text, p_n text, p_amount bigint, p_key text) returns uuid
language plpgsql as $$
declare v uuid; f uuid;
begin
  perform pg_temp.pending(p_c, p_n, p_amount);
  v := pg_temp.request(p_c, 'op-' || p_key);
  perform pg_temp.prepare_plain(v);
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'op-' || p_key);
  f := (pg_temp.gen('01', 'gen-op-' || p_key) ->> 'file_id')::uuid;
  insert into t values ('file-' || p_key, f) on conflict (k) do update set v = excluded.v;
  perform pg_temp.write(f);
  return pg_temp.rtransfer(v);
end $$;
create or replace function pg_temp.dl3() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); p6 uuid; p9 uuid; j9 date; nm jsonb;
begin
  p9 := pg_temp.out_plain('a9', '91', 100000, 'dl3-9');
  j9 := (pg_temp.tr(pg_temp.v('run-dl3-9'))).requested_execution_date + 2;
  perform pg_temp.opening('a9', 'liquidation', j9);
  p6 := pg_temp.out_gen('a6', '61', 100000, 'dl3-6');
  perform pg_temp.opening('a6', 'liquidation', d - 2);
  nm := jsonb_build_object('p6', p6, 'p9', p9);
  return jsonb_build_object('today', pg_temp.pal(pg_temp.adv_run(d), nm),
                            'after_judgment', pg_temp.pal(pg_temp.adv_run(j9 + 1), nm),
                            'states', jsonb_build_array(pg_temp.status(p9), pg_temp.status(p6),
                                                        (pg_temp.fl(pg_temp.v('file-dl3-6'))).first_downloaded_at is null));
end $$;
select is(pg_temp.iso('dl3'),
  '{"today": {"p6": ["in_file", 100000, true, false]}, "after_judgment": {"p6": ["in_file", 100000, true, false]},
    "states": ["in_file", "in_file", true]}'::jsonb,
  'l (TUI-5): a payout in a file not yet downloaded is cancellable whatever the switch; one in a downloaded file '
  'requested before the judgment and not debited is never listed');
select is(pg_temp.iso('dl3', true), pg_temp.iso('dl3'), 'l (TUI-5): the same with the switch on');


-- s. The outcome of a set-off set_off_after_bar alerts (carried item 2) -----------------------------------------------
-- Lilas (a2): its run sets off FC-1 (born d − 12) at its debit (d − 1); the redressement (effective d − 6) recorded
-- after it → set_off_after_bar lists the settlement; « compensation maintenue » (admin, with counsel's answer as
-- evidence) stops it; refusals: an ops manager, aal1, given_back (not built), no evidence, an entry the alert does not
-- name (Martin's settlement, no event), already_recorded; replayed
create or replace function pg_temp.so1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; e uuid; m uuid; r jsonb; w jsonb;
begin
  f := pg_temp.inv_on('a2', '21', 200000, '210', d - 12);
  perform pg_temp.pending('a2', '23', 100000);
  v := pg_temp.request('a2', 'k046c-so1');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.approve_plain(v, 'k046c-so1');
  perform pg_temp.debit(v, '230', d - 1);
  e := pg_temp.ek('settle:' || v);
  perform pg_temp.inv_on('a1', '11', 200000, '110', d - 3, 36000, 6000);
  m := pg_temp.ek('settle:' || pg_temp.v('run-110'));
  perform pg_temp.evt('a2', 'proceeding_opened', d - 6, '1 minute');
  w := jsonb_build_object('alerted', pg_temp.rows_of(pg_temp.adv_run(d), 'set_off_after_bar', e),
    'ops', pg_temp.code(pg_temp.outc('so1-a', e, 'kept', p_user => '01')),
    'aal1', pg_temp.code(pg_temp.outc('so1-b', e, 'kept', p_aal => 'aal1')),
    'given_back', pg_temp.code(pg_temp.outc('so1-c', e, 'given_back')),
    'no_evidence', pg_temp.code(pg_temp.outc('so1-d', e, 'kept', p_ev => gen_random_uuid())),
    'not_alerted', pg_temp.code(pg_temp.outc('so1-e', m, 'kept')),
    'a_reversal', pg_temp.code(pg_temp.outc('so1-f', pg_temp.ek('tf-owe-21'), 'kept')));
  r := pg_temp.outc('so1-z', e, 'kept');
  return w || jsonb_build_object('ok', pg_temp.code(r), 'result', jsonb_build_array(r ->> 'entry_id' = e::text, r ->> 'kind'),
    'replay', pg_temp.outc('so1-z', e, 'kept') = r,
    'second', pg_temp.code(pg_temp.outc('so1-y', e, 'kept')),
    'after', pg_temp.rows_of(pg_temp.adv_run(d), 'set_off_after_bar', e));
end $$;
select is(pg_temp.iso('so1'),
  '{"alerted": [[true, 20000]], "ops": "not allowed", "aal1": "not allowed", "given_back": "bad_kind",
    "no_evidence": "evidence_required", "not_alerted": "not_alerted", "a_reversal": "not_alerted", "ok": "ok",
    "result": [true, "kept"], "replay": true, "second": "already_recorded", "after": []}'::jsonb,
  's (carried item 2): « Compensation maintenue » (an administrator at aal2, counsel''s answer as evidence) stops '
  'set_off_after_bar for that settlement; giving the sum back is not built; one outcome per settlement');

-- (review round 1, ML-2) the command takes what the alert names, by the alert's own rule: Durand (a7) — its run sets FC-1
-- (born d − 12) off at its debit (d − 1); the death (effective d − 6) recorded after the settlement's posting: barred by
-- the end alone and posted before the servicer recorded it (C. civ. 2008: valid, MLAW-3) — set_off_after_bar names
-- nothing, so « Compensation maintenue » is refused not_alerted, though FC-1 was not nettable that day
create or replace function pg_temp.so2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; e uuid;
begin
  f := pg_temp.inv_on('a7', '71', 200000, '710', d - 12);
  perform pg_temp.pending('a7', '73', 100000);
  v := pg_temp.request('a7', 'k046c-so2');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.approve_plain(v, 'k046c-so2');
  perform pg_temp.debit(v, '730', d - 1);
  e := pg_temp.ek('settle:' || v);
  perform pg_temp.evt('a7', 'death', d - 6, '-1 minute');
  return jsonb_build_object('alerted', pg_temp.rows_of(pg_temp.adv_run(d), 'set_off_after_bar', e),
                            'nettable', private.document_nettable(f, d - 1),
                            'outcome', pg_temp.code(pg_temp.outc('so2', e, 'kept')));
end $$;
select is(pg_temp.iso('so2'), '{"alerted": [], "nettable": false, "outcome": "not_alerted"}'::jsonb,
  's (ML-2): « Compensation maintenue » is refused for a settlement set_off_after_bar does not name (a set-off valid '
  'under C. civ. 2008)');


-- w. A withheld set-off given back, the giving run's payout returned and paid again (carried item 4) -----------------
-- Cyprès (a3): RV-7 sets off FC-1 (born d − 12); the redressement recorded after the download; its debit (d − 3)
-- withholds W. RV-8 approved → « giving back » RV-8; debited (d − 2) → given back by RV-8; RV-8's payout returned (d − 1)
-- → neither (the sum re-queued: « à rendre … par le prochain reversement »), returned_by RV-8; RV-9 (the account confirmed
-- again) approved → giving back RV-9; debited → given back by RV-9, returned_by RV-8
create or replace function pg_temp.ww1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; v8 uuid; v9 uuid; w jsonb; n8 text; n9 text;
begin
  f := pg_temp.inv_on('a3', '31', 200000, '310', d - 12);
  perform pg_temp.pending('a3', '32', 100000);
  v := pg_temp.request('a3', 'k046c-ww1');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046c-ww1');
  perform pg_temp.handed_out('file-790', 'gen-file-790');
  perform pg_temp.evt('a3', 'proceeding_opened', d - 6, '1 minute');
  perform pg_temp.debit(v, '790', d - 3);
  v8 := pg_temp.request('a3', 'k046c-ww1-8');
  perform pg_temp.prepare_plain(v8);
  perform pg_temp.draft_state(v8);
  perform pg_temp.approve_plain(v8, 'k046c-ww1-8');
  n8 := pg_temp.rnum(v8);
  w := jsonb_build_object('approved', pg_temp.withheld_back(v));
  perform pg_temp.debit(v8, '791', d - 2);
  w := w || jsonb_build_object('debited', pg_temp.withheld_back(v));
  perform pg_temp.bounce(v8, '792', d - 1);
  w := w || jsonb_build_object('returned', pg_temp.withheld_back(v));
  perform pg_temp.reconfirm('a3');
  v9 := pg_temp.request('a3', 'k046c-ww1-9');
  perform pg_temp.prepare_plain(v9);
  perform pg_temp.draft_state(v9);
  perform pg_temp.approve_plain(v9, 'k046c-ww1-9');
  n9 := pg_temp.rnum(v9);
  w := w || jsonb_build_object('repaying', pg_temp.withheld_back(v));
  perform pg_temp.debit(v9, '793', d - 1);
  w := w || jsonb_build_object('repaid', pg_temp.withheld_back(v));
  return (select jsonb_object_agg(k, (select jsonb_agg(case x #>> '{}' when n8 then to_jsonb('RV-8'::text)
                                                                        when n9 then to_jsonb('RV-9'::text) else x end)
                                       from jsonb_array_elements(w -> k) x))
          from jsonb_object_keys(w) k);
end $$;
select is(pg_temp.iso('ww1'),
  '{"approved": [null, "RV-8", null], "debited": ["RV-8", null, null], "returned": [null, null, "RV-8"],
    "repaying": [null, "RV-9", "RV-8"], "repaid": ["RV-9", null, "RV-8"]}'::jsonb,
  'w (carried item 4): once the run that gave the withheld set-off back has its payout returned, the withheld run''s '
  'read follows the returned payout''s item to the run that pays it again (giving back while approved, given back once '
  'booked), naming the run whose payout came back');
select is(pg_temp.iso('ww1', true), pg_temp.iso('ww1'), 'w (carried item 4): the same with the switch on');


-- f. The statement fr-4 (§6.2.8; [critic] L12, L13, M7-MONEY-5) ------------------------------------------------------
-- (MONEY-5) Lilas (a2): RV-7 nets FC-6 (pre-opening) at its debit after the redressement was recorded: withheld 20 000;
-- RV-8 gives it back — its statement (schema 2) names it: RV-7's number, the amount, the day it was withheld, the
-- ledger's reason; RV-7's own statement keeps fr-3's payload (schema 1, no fr-4 key); the record step takes each payload
-- by its own template only (fr-4 for schema 2, fr-3 for schema 1)
create or replace function pg_temp.sf1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; v8 uuid; p jsonb; p7 jsonb;
begin
  f := pg_temp.inv_on('a2', '61', 200000, '610', d - 12);
  perform pg_temp.pending('a2', '64', 100000);
  v := pg_temp.request('a2', 'k046c-sf1');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046c-sf1');
  perform pg_temp.handed_out('file-800', 'gen-file-800');
  perform pg_temp.opening('a2', 'proceeding_opened', d - 6, d - 4);
  perform pg_temp.debit(v, '800', d - 2);
  v8 := pg_temp.request('a2', 'k046c-sf1-8');
  perform pg_temp.prepare_plain(v8);
  perform pg_temp.draft_state(v8);
  perform pg_temp.approve_plain(v8, 'k046c-sf1-8');
  p := pg_temp.stmt_of(v8);
  p7 := pg_temp.stmt_of(v);
  return jsonb_build_object(
    'schema', jsonb_build_array(p ->> 'schema', p7 ->> 'schema'),
    'withheld', (select jsonb_agg(jsonb_build_array(x ->> 'run_number' = pg_temp.rnum(v), x ->> 'amount_minor',
                                                    (x ->> 'withheld_on')::date = d - 2,
                                                    x ->> 'reason' = 'Compensation retenue : procédure collective depuis le '
                                                                     || to_char(d - 6, 'DD/MM/YYYY') || ' (règle du cabinet)'))
                 from jsonb_array_elements(p -> 'withheld_given_back') x),
    'line', (select jsonb_agg(l -> 7) from jsonb_array_elements(p -> 'lines') l),
    'fr3_keys', jsonb_build_array(p7 ? 'withheld_given_back', p7 ? 'mandate_end', p7 ? 'addressees'),
    'record', jsonb_build_array(pg_temp.record_stmt(v8, 'releve-reversement-fr-4'),
                                pg_temp.record_stmt(v8, 'releve-reversement-fr-3'),
                                pg_temp.record_stmt(v, 'releve-reversement-fr-3'),
                                pg_temp.record_stmt(v, 'releve-reversement-fr-4')));
end $$;
select is(pg_temp.iso('sf1'),
  '{"schema": ["2", "1"], "withheld": [[true, "20000", true, true]], "line": ["settlement_withheld"],
    "fr3_keys": [false, false, false],
    "record": ["recorded",
               "statements drawn by template releve-reversement-fr-3: this payload is drawn by releve-reversement-fr-4 only",
               "recorded",
               "statements drawn by template releve-reversement-fr-4: this payload is drawn by releve-reversement-fr-3 only"]}'::jsonb,
  'f (M7-MONEY-5): the statement of the run that gives a withheld set-off back names it (the withheld run, the amount, '
  'its day, the ledger''s reason: fr-4); a statement with nothing of fr-4 keeps fr-3''s payload; each drawn by its own '
  'template only');
select is(pg_temp.iso('sf1', true), pg_temp.iso('sf1'), 'f (M7-MONEY-5): the same with the switch on');

-- (L13) Durand (a7): a death effective d − 10, recorded before the run's K → the statement states the end, its day and
-- the day the servicer recorded it, the payee the end requires (the estate's), addressed to the notary (the role only:
-- the name and address stay staff's); Moreau (a9): the death recorded after K → nothing (the statement is as of K)
create or replace function pg_temp.sf2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); e uuid; v uuid; v9 uuid; p jsonb; p9 jsonb;
begin
  e := pg_temp.evt('a7', 'death', d - 10, '1 hour');
  perform pg_temp.rep('sf2', e, pg_temp.person('notary'));
  v := pg_temp.zero_run('a7', '71', 'k046c-sf2');
  v9 := pg_temp.zero_run('a9', '91', 'k046c-sf2-9');
  perform pg_temp.evt('a9', 'death', d - 10, '-1 minute');
  p := pg_temp.stmt_of(v);
  p9 := pg_temp.stmt_of(v9);
  return jsonb_build_object(
    'schema', jsonb_build_array(p ->> 'schema', p9 ->> 'schema'),
    'end', jsonb_build_array(p #>> '{mandate_end,kind}', (p #>> '{mandate_end,effective_date}')::date = d - 10,
                             -- (review round 1, TUI-4) the day in Paris, as the payload states it (the session runs
                             -- in UTC: the two days differ between 23:00 and 01:00 UTC)
                             (p #>> '{mandate_end,recorded_on}')::date
                               = ((now() - interval '1 hour') at time zone 'Europe/Paris')::date,
                             p #>> '{mandate_end,payee_kind}'),
    'addressees', p -> 'addressees', 'other', p9 ? 'mandate_end');
end $$;
select is(pg_temp.iso('sf2') - 'end',
  '{"schema": ["2", "1"], "addressees": [{"role": "notary", "copy": false}], "other": false}'::jsonb,
  'f (L13, L12): after a death recorded by K the statement is fr-4, addressed to the notary (its role only); a death '
  'recorded after K changes nothing (the statement is as of K)');
select is(pg_temp.iso('sf2') -> 'end', '["death", true, true, "estate"]'::jsonb,
  'f (L13): the end of the mandate stated with its day and the day the servicer recorded it, and the payee it requires');

-- (L12) who a statement is addressed to, as of K: a tutelle with its tutor → the tutor; a curatelle with its curator →
-- the client, the curator in copy; a liquidation with its liquidator → the liquidator; a death without anybody recorded →
-- none (and fr-4 for its mandate end); a proceeding → nothing (schema 1); (§1.2) an advance a run takes back carries its
-- date (fr-4)
create or replace function pg_temp.sf3() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); e uuid; runs jsonb := '{}'; c text; a public.client_advance; v uuid;
        p jsonb;
begin
  e := pg_temp.evt('a4', 'guardianship', d - 10, '1 hour');
  perform pg_temp.rep('sf3-4', e, pg_temp.person('tutor'));
  e := pg_temp.evt('a5', 'curatorship', d - 10, '1 hour');
  perform pg_temp.rep('sf3-5', e, pg_temp.person('curator'));
  e := pg_temp.evt('a6', 'liquidation', d - 10, '1 hour');
  perform pg_temp.rep('sf3-6', e, pg_temp.person('liquidator'));
  perform pg_temp.evt('a8', 'death', d - 10, '1 hour');
  perform pg_temp.evt('a1', 'proceeding_opened', d - 10, '1 hour');
  foreach c in array array['a4', 'a5', 'a6', 'a8', 'a1'] loop
    runs := runs || jsonb_build_object(c, pg_temp.zero_run(c, right(c, 1) || '7', 'k046c-sf3-' || c));
  end loop;
  -- the curatelle's client dies, recorded after K: its statement still addressed as at K (the client, the curator in
  -- copy), not to whoever acts after the death
  perform pg_temp.evt('a5', 'death', d - 5, '-1 minute');
  -- Lilas: a claw-back clause, its advance taken back by the run
  perform pg_temp.clawback('a2', 'art. 7.4');
  a := pg_temp.adv_on('a2', '28', 30000, '280', d - 5);
  perform pg_temp.pending('a2', '29', 100000);
  v := pg_temp.request('a2', 'k046c-sf3-a2');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(a.id, 'advance', 30000)));
  perform pg_temp.approve_plain(v, 'k046c-sf3-a2');
  p := pg_temp.stmt_of(v);
  return (select jsonb_object_agg(k, jsonb_build_array(x ->> 'schema', x -> 'addressees'))
          from jsonb_each(runs) r (k, id)
          cross join lateral (select pg_temp.stmt_of((r.id #>> '{}')::uuid) as x) s)
         || jsonb_build_object('advance', jsonb_build_array(
              p ->> 'schema',
              (select jsonb_agg(jsonb_build_array(x ->> 'kind', x ->> 'amount_minor', (x ->> 'born_on')::date = d - 5))
               from jsonb_array_elements(p -> 'earlier_settled') x)));
end $$;
select is(pg_temp.iso('sf3'),
  '{"a4": ["2", [{"role": "tutor", "copy": false}]],
    "a5": ["2", [{"role": "client", "copy": false}, {"role": "curator", "copy": true}]],
    "a6": ["2", [{"role": "liquidator", "copy": false}]],
    "a8": ["2", null], "a1": ["1", null],
    "advance": ["2", [["advance", "30000", true]]]}'::jsonb,
  'f (L12): a statement is addressed as the letters are — the tutor, the client with its curator in copy (a death '
  'recorded after K changes nothing), the liquidator — by role only; a death with nobody recorded names nobody; a '
  'proceeding keeps fr-3; an advance taken back is dated (fr-4)');

-- (review round 1, ML-1) an old « Tutelle ou curatelle » row counts as a tutelle from its qualification, as the code
-- applies it. Lambert (a4): the row (effective d − 20, recorded d − 15); its run's set-off of FC at the debit after it,
-- not withheld; a payment matched before the qualification allocated ('ready'), one matched after set aside
-- (client_mandate_ended); a run whose K precedes the qualification states no end (its K saw a row still to qualify:
-- schema 1); one after states the end recorded the qualification's day, never the old row's. Petit (a8): an old row and a
-- death, both recorded before K, the row qualified after K → the death's end, and the payee as at K (payouts suspended
-- until the measure is said: 'to_qualify'), not the estate's. Moreau (a9): an old row (effective d − 20) and a tutelle
-- recorded later (effective d − 5, its tutor recorded), both before K, the old row qualified a curatelle after K → as at K
-- the old row, still to qualify, governs the letters: addressed to nobody (as private.client_addressee then), the end
-- the tutelle's, the payouts suspended. (ADR-0014 « M2c-7e-3 review fixes » round 2) FC's collection d − 22, not
-- d − 25: its line's latest execution date is the collection + 27 days and its run is approved today for the next
-- business day, so d − 25 (latest d + 2) left FC's run a draft on a Friday (late_reason_required; no payout to debit);
-- d − 22 (latest d + 5), still before the row's d − 20, holds whatever today's weekday or holidays
create or replace function pg_temp.sf4() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); f uuid; v uuid; o uuid; o8 uuid; o9 uuid; e9 uuid; z0 uuid; z1 uuid; z8 uuid;
        z9 uuid; e uuid; m1 text; m2 text; p0 jsonb; p1 jsonb; p8 jsonb; p9 jsonb; q date;
begin
  f := pg_temp.inv_on('a4', '41', 200000, '410', d - 22);
  perform pg_temp.pending('a4', '43', 100000);
  v := pg_temp.request('a4', 'k046c-sf4');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 36000, 6000)));
  perform pg_temp.draft_state(v);
  perform pg_temp.approve_plain(v, 'k046c-sf4');
  perform pg_temp.handed_out('file-430', 'gen-file-430');
  o := pg_temp.old_tutelle('a4', d - 20, '15 days');
  perform pg_temp.debit(v, '430', d - 1);
  e := pg_temp.ek('settle:' || v);
  m1 := pg_temp.match('a4', '44', 10000, d - 3);
  z0 := pg_temp.zero_run('a4', '45', 'k046c-sf4-0');
  o8 := pg_temp.old_tutelle('a8', d - 20, '15 days');
  perform pg_temp.evt('a8', 'death', d - 10, '1 hour');
  z8 := pg_temp.zero_run('a8', '85', 'k046c-sf4-8');
  o9 := pg_temp.old_tutelle('a9', d - 20, '15 days');
  e9 := pg_temp.evt('a9', 'guardianship', d - 5, '1 hour');
  perform pg_temp.rep('sf4-9', e9, pg_temp.person('tutor'));
  z9 := pg_temp.zero_run('a9', '95', 'k046c-sf4-9');
  perform pg_temp.qual('sf4', o, 'guardianship');
  perform pg_temp.qual('sf4-8', o8, 'guardianship');
  perform pg_temp.qual('sf4-9', o9, 'curatorship');
  m2 := pg_temp.match('a4', '46', 10000, d - 2);
  z1 := pg_temp.zero_run('a4', '47', 'k046c-sf4-1');
  p0 := pg_temp.stmt_of(z0);
  p1 := pg_temp.stmt_of(z1);
  p8 := pg_temp.stmt_of(z8);
  p9 := pg_temp.stmt_of(z9);
  q := (select (x.recorded_at at time zone 'Europe/Paris')::date from public.client_status_event_qualification x
        where x.event_id = o);
  return jsonb_build_object(
    'set_off', (select jsonb_agg(jsonb_build_array(s.kind, s.amount_minor)) from public.commission_settlement s
                where s.entry_id = e),
    'withheld', exists (select 1 from public.ledger_entry x where x.idempotency_key = 'settle:' || v || ':barred'),
    'matched', jsonb_build_array(m1, m2),
    'before', jsonb_build_array(p0 ->> 'schema', p0 ? 'mandate_end'),
    'after', jsonb_build_array(p1 #>> '{mandate_end,kind}', (p1 #>> '{mandate_end,effective_date}')::date = d - 20,
                               (p1 #>> '{mandate_end,recorded_on}')::date = q,
                               (p1 #>> '{mandate_end,recorded_on}')::date
                                 = ((now() - interval '15 days') at time zone 'Europe/Paris')::date,
                               p1 #>> '{mandate_end,payee_kind}'),
    'with_death', jsonb_build_array(p8 #>> '{mandate_end,kind}', (p8 #>> '{mandate_end,effective_date}')::date = d - 10,
                                    p8 #>> '{mandate_end,payee_kind}'),
    'curatelle_after_k', jsonb_build_array(p9 -> 'addressees', p9 #>> '{mandate_end,kind}',
                                           p9 #>> '{mandate_end,payee_kind}'));
end $$;
select is(pg_temp.iso('sf4'),
  '{"set_off": [["compensation", 36000]], "withheld": false, "matched": ["ready", "client_mandate_ended"],
    "before": ["1", false], "after": ["guardianship", true, true, false, "protected_adult"],
    "with_death": ["death", true, "to_qualify"], "curatelle_after_k": [null, "guardianship", "to_qualify"]}'::jsonb,
  'f (ML-1): an old « Tutelle ou curatelle » row ends the mandate from its qualification — a statement whose K '
  'precedes it states no end, a later one the day of the qualification; the payee stated as at K');

-- (review round 3) two ends known on different days: the code applied, from each one's day, the end it then knew
-- (private.client_end_event: the earliest in effect), so the statement states the end at K with its day and, before it,
-- each end the code applied earlier with its own (`earlier`). Petit (a8): an old « Tutelle ou curatelle » row (effective
-- d − 20, recorded d − 15); a death effective d − 14 recorded d − 12, its notary recorded; a payment booked d − 17 matched
-- then → allocated, one booked d − 13 → set aside (the death's end applied from its recording); the old row qualified a
-- tutelle; a payment booked d − 17 matched after → set aside; a run's statement → the tutelle's end (d − 20) known the
-- qualification's day and, earlier, the death's (d − 14) known d − 12; the estate's account; addressed to the notary.
-- Lambert (a4): an old row (d − 20, recorded d − 18), a mandate end effective d − 8 recorded d − 7, a death effective
-- d − 12 recorded d − 4, the old row qualified → three ends applied in turn, the two earlier in their order. Moreau (a9):
-- a mandate end effective d − 10 recorded d − 8, a death effective d − 5 recorded d − 6, a tutelle effective d − 20
-- recorded d − 3 → the tutelle's end, and before it the mandate end's alone (the death, known after it and later in
-- effect, changed nothing the code applied: never stated). Cyprès (a3): a death effective d − 10 recorded a
-- minute ago and an old row (d − 20) qualified now → one Paris day, one end stated (`earlier` only when the days differ).
-- Martin (a1): an old row (d − 20), a mandate end effective d − 8 recorded at 10:00 (Paris) d − 6 and a death effective
-- d − 12 recorded at 10:01 the same day, the old row qualified now → that day stated once, with the end the code applied
-- by its evening (the death's)
create or replace function pg_temp.sf5() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); o8 uuid; e8 uuid; o4 uuid; o3 uuid; e3 uuid; o1 uuid; z8 uuid; z4 uuid;
        z9 uuid; z3 uuid; z1 uuid; m1 text; m2 text; m3 text; p8 jsonb; p4 jsonb; p9 jsonb; p3 jsonb; p1 jsonb;
        t10 timestamptz := ((d - 6) + time '10:00') at time zone 'Europe/Paris';
begin
  o8 := pg_temp.old_tutelle('a8', d - 20, '15 days');
  e8 := pg_temp.evt('a8', 'death', d - 14, '12 days');
  perform pg_temp.rep('sf5-8', e8, pg_temp.person('notary'));
  m1 := pg_temp.match('a8', '8b', 10000, d - 17);
  m2 := pg_temp.match('a8', '8c', 10000, d - 13);
  perform pg_temp.qual('sf5-8', o8, 'guardianship');
  m3 := pg_temp.match('a8', '8d', 10000, d - 17);
  z8 := pg_temp.zero_run('a8', '8e', 'k046c-sf5-8');
  o4 := pg_temp.old_tutelle('a4', d - 20, '18 days');
  perform pg_temp.evt('a4', 'mandate_ended', d - 8, '7 days');
  perform pg_temp.evt('a4', 'death', d - 12, '4 days');
  perform pg_temp.qual('sf5-4', o4, 'guardianship');
  z4 := pg_temp.zero_run('a4', '4e', 'k046c-sf5-4');
  perform pg_temp.evt('a9', 'mandate_ended', d - 10, '8 days');
  perform pg_temp.evt('a9', 'death', d - 5, '6 days');
  perform pg_temp.evt('a9', 'guardianship', d - 20, '3 days');
  z9 := pg_temp.zero_run('a9', '9e', 'k046c-sf5-9');
  o3 := pg_temp.old_tutelle('a3', d - 20, '30 days');
  e3 := pg_temp.evt('a3', 'death', d - 10, '1 minute');
  perform pg_temp.qual('sf5-3', o3, 'guardianship');
  z3 := pg_temp.zero_run('a3', '3e', 'k046c-sf5-3');
  o1 := pg_temp.old_tutelle('a1', d - 20, '30 days');
  perform pg_temp.evt('a1', 'mandate_ended', d - 8, now() - t10);
  perform pg_temp.evt('a1', 'death', d - 12, now() - (t10 + interval '1 minute'));
  perform pg_temp.qual('sf5-1', o1, 'guardianship');
  z1 := pg_temp.zero_run('a1', '1e', 'k046c-sf5-1');
  p8 := pg_temp.stmt_of(z8);
  p4 := pg_temp.stmt_of(z4);
  p9 := pg_temp.stmt_of(z9);
  p3 := pg_temp.stmt_of(z3);
  p1 := pg_temp.stmt_of(z1);
  return jsonb_build_object(
    'matched', jsonb_build_array(m1, m2, m3),
    'petit', jsonb_build_array(
      p8 #>> '{mandate_end,kind}', (p8 #>> '{mandate_end,effective_date}')::date - d,
      (p8 #>> '{mandate_end,recorded_on}')::date
        = (select (x.recorded_at at time zone 'Europe/Paris')::date from public.client_status_event_qualification x
           where x.event_id = o8),
      p8 #>> '{mandate_end,payee_kind}', p8 -> 'addressees'),
    'petit_earlier', (select jsonb_agg(jsonb_build_array(x ->> 'kind', (x ->> 'effective_date')::date - d,
                                                         (x ->> 'recorded_on')::date
                                                           = ((now() - interval '12 days') at time zone 'Europe/Paris')::date))
                      from jsonb_array_elements(p8 #> '{mandate_end,earlier}') x),
    'lambert', jsonb_build_array(p4 #>> '{mandate_end,kind}', (p4 #>> '{mandate_end,effective_date}')::date - d),
    'lambert_earlier', (select jsonb_agg(jsonb_build_array(x ->> 'kind', (x ->> 'effective_date')::date - d,
                                                           (x ->> 'recorded_on')::date - d) order by n)
                        from jsonb_array_elements(p4 #> '{mandate_end,earlier}') with ordinality x (x, n)),
    'moreau', jsonb_build_array(p9 #>> '{mandate_end,kind}', (p9 #>> '{mandate_end,effective_date}')::date - d,
                                (p9 #>> '{mandate_end,recorded_on}')::date
                                  = ((now() - interval '3 days') at time zone 'Europe/Paris')::date,
                                (select jsonb_agg(jsonb_build_array(x ->> 'kind', (x ->> 'effective_date')::date - d,
                                                                    (x ->> 'recorded_on')::date
                                                                      = ((now() - interval '8 days')
                                                                         at time zone 'Europe/Paris')::date))
                                 from jsonb_array_elements(p9 #> '{mandate_end,earlier}') x)),
    'cypres', jsonb_build_array(p3 #>> '{mandate_end,kind}',
                                (p3 -> 'mandate_end' ? 'earlier')
                                  = ((select (x.recorded_at at time zone 'Europe/Paris')::date
                                      from public.client_status_event x where x.id = e3)
                                     <> (p3 #>> '{mandate_end,recorded_on}')::date)),
    'martin', jsonb_build_array(p1 #>> '{mandate_end,kind}',
                                (select jsonb_agg(jsonb_build_array(x ->> 'kind', (x ->> 'effective_date')::date - d,
                                                                    (x ->> 'recorded_on')::date - d))
                                 from jsonb_array_elements(p1 #> '{mandate_end,earlier}') x)));
end $$;
select is(pg_temp.iso('sf5'),
  '{"matched": ["ready", "client_mandate_ended", "client_mandate_ended"],
    "petit": ["guardianship", -20, true, "estate", [{"role": "notary", "copy": false}]],
    "petit_earlier": [["death", -14, true]],
    "lambert": ["guardianship", -20],
    "lambert_earlier": [["mandate_ended", -8, -7], ["death", -12, -4]],
    "moreau": ["guardianship", -20, true, [["mandate_ended", -10, true]]],
    "cypres": ["guardianship", true],
    "martin": ["guardianship", [["death", -12, -6]]]}'::jsonb,
  'f (review round 3): the statement states the end at K with the day the code applied it and, before it, each end the '
  'code applied earlier with its own day — never an end known later that changed nothing');


-- i. The two new tables: isolation, append-only, change log ------------------------------------------------------------
-- Petit (a8, its admin 03 and restricted viewer 07): a disposition and an outcome recorded; money staff read both,
-- servicer B, the client's admin, its viewer and a collector none; no caller writes them; append-only; one change-log
-- row each
create or replace function pg_temp.si1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); p8 uuid; f uuid; v uuid; e uuid; r1 jsonb; r2 jsonb; v_read text;
begin
  f := pg_temp.inv_on('a8', '82', 200000, '820', d - 12);
  perform pg_temp.pending('a8', '83', 100000);
  v := pg_temp.request('a8', 'k046c-si1');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.approve_plain(v, 'k046c-si1');
  perform pg_temp.debit(v, '830', d - 1);
  e := pg_temp.ek('settle:' || v);
  p8 := pg_temp.out_plain('a8', '81', 100000, 'si1-8');
  perform pg_temp.opening('a8', 'liquidation', d - 2);
  perform pg_temp.debit(pg_temp.v('run-si1-8'), '810', d - 1);
  r1 := pg_temp.disp('si1', p8, 'ratified');
  r2 := pg_temp.outc('si1', e, 'kept');
  v_read := 'select to_jsonb(array[(select count(*) from public.liquidation_payout_disposition), '
            '(select count(*) from public.set_off_outcome)])';
  return jsonb_build_object(
    'made', jsonb_build_array(pg_temp.code(r1), pg_temp.code(r2)),
    'money_staff', pg_temp.read_as('01', v_read), 'servicer_b', pg_temp.read_as('05', v_read),
    'client_admin', pg_temp.read_as('03', v_read), 'restricted_viewer', pg_temp.read_as('07', v_read),
    'collector', pg_temp.read_as('02', v_read),
    'write', jsonb_build_array(
      pg_temp.try('04', format('insert into public.liquidation_payout_disposition (organization_id, '
                               'client_organization_id, transfer_id, kind, evidence_document_id, recorded_by) '
                               'values (%L, %L, %L, %L, %L, %L) returning 1', '00000000-0000-0000-0000-0000000000aa',
                               pg_temp.c('a8'), gen_random_uuid(), 'ratified', pg_temp.ev('8', 'a8'),
                               '10000000-0000-0000-0000-000000000004')),
      pg_temp.try('04', 'update public.set_off_outcome set note = null returning 1'),
      pg_temp.try('04', 'delete from public.liquidation_payout_disposition returning 1')),
    'append_only', jsonb_build_array(
      pg_temp.state('update public.liquidation_payout_disposition set note = null'),
      pg_temp.state('delete from public.set_off_outcome')),
    'change_log', jsonb_build_array(
      (select count(*) from private.change_log l where l.table_name = 'public.liquidation_payout_disposition'
         and l.row_id = r1 ->> 'disposition_id'),
      (select count(*) from private.change_log l where l.table_name = 'public.set_off_outcome'
         and l.row_id = e::text)));
end $$;
select is(pg_temp.iso('si1'),
  '{"made": ["ok", "ok"], "money_staff": [1, 1], "servicer_b": [0, 0], "client_admin": [0, 0],
    "restricted_viewer": [0, 0], "collector": [0, 0],
    "write": ["permission denied for table liquidation_payout_disposition",
              "permission denied for table set_off_outcome",
              "permission denied for table liquidation_payout_disposition"],
    "append_only": ["23514", "23514"], "change_log": [1, 1]}'::jsonb,
  'i: the dispositions and the outcomes are read by the servicer''s money staff only (not servicer B, the client''s '
  'admin, its restricted viewer nor a collector), written by their commands only, append-only, each in the change log');


-- n. The full list of codes run_advance_checks emits (046b n, extended with 7d-3's three) -----------------------------
create or replace function pg_temp.sn3() returns jsonb language plpgsql as $$
declare a public.client_advance; m public.client_advance; c uuid; r jsonb; v uuid; f uuid; d date := private.paris_today();
        p8 uuid;
begin
  f := pg_temp.inv_on('a6', '91', 200000, '910', d - 12);
  perform pg_temp.inv_on('a6', '92', 200000, '920', d - 2);
  perform pg_temp.pending('a6', '93', 100000);
  v := pg_temp.request('a6', 'k046c-sn3');
  perform pg_temp.prepare_set(v, jsonb_build_array(pg_temp.st(f, 'compensation', 20000, 3333)));
  perform pg_temp.approve_plain(v, 'k046c-sn3');
  perform pg_temp.debit(v, '930', d - 1);
  perform pg_temp.evt('a6', 'proceeding_opened', d - 6, '1 minute');
  p8 := pg_temp.out_plain('a3', '31', 100000, 'sn3-3');
  perform pg_temp.opening('a3', 'liquidation', d - 2);
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
  c := pg_temp.adv_run(private.paris_today() + 90, true);
  return (select jsonb_agg(distinct x.code order by x.code) from public.payment_check_result x where x.run_id = c);
end $$;
select is(pg_temp.iso('sn3'),
  '["advance_ledger", "advance_open", "claims_to_declare", "client_credit_ledger", "client_credit_owed",
    "payout_after_liquidation", "post_opening_unpaid", "protection_event_to_qualify", "remitted_reversal_uncovered",
    "repayment_request_document_missing", "seizure_standing", "set_off_after_bar", "written_off_recovery_ledger"]'::jsonb,
  'n (F12): run_advance_checks emits exactly 046b''s ten codes and 7d-3''s claims_to_declare, payout_after_liquidation '
  'and post_opening_unpaid (later slices extend this list)');


-- c. The privileges of the new functions --------------------------------------------------------------------------------
select is((select jsonb_agg(jsonb_build_array(f, has_function_privilege('anon', f, 'execute'),
                                              has_function_privilege('authenticated', f, 'execute'),
                                              has_function_privilege('service_role', f, 'execute')) order by f)
           from unnest(array['public.record_liquidation_payout_disposition(text, uuid, text, uuid, text)',
                             'public.record_set_off_outcome(text, uuid, text, uuid, text)',
                             'private.client_procedure_facts(uuid, date)',
                             'private.client_claims_to_declare(uuid, date)',
                             'private.client_post_opening_unpaid(uuid, date)',
                             'private.client_payouts_after_liquidation(uuid, date)',
                             'private.statement_addressees(uuid, date, timestamptz)',
                             'private.statement_mandate_end(uuid, date, timestamptz)',
                             'private.invoice_to_declare(uuid, uuid, date)',
                             'private.withheld_given_back(uuid)',
                             -- (review round 1, ML-1, ML-2)
                             'private.client_event_known(uuid, timestamptz)',
                             'private.settlement_set_off_alert(uuid, uuid, date, uuid, text)',
                             'private.set_off_after_bar_rows(uuid, date)',
                             -- (review round 2)
                             'private.invoice_withheld_on(uuid)',
                             -- (review round 3)
                             'private.client_set_off_bar_recorded_on(uuid, date, text)']) f),
  '[["private.client_claims_to_declare(uuid, date)", false, false, false],
    ["private.client_event_known(uuid, timestamptz)", false, false, false],
    ["private.client_payouts_after_liquidation(uuid, date)", false, false, false],
    ["private.client_post_opening_unpaid(uuid, date)", false, false, false],
    ["private.client_procedure_facts(uuid, date)", false, false, false],
    ["private.client_set_off_bar_recorded_on(uuid, date, text)", false, false, false],
    ["private.invoice_to_declare(uuid, uuid, date)", false, false, false],
    ["private.invoice_withheld_on(uuid)", false, false, false],
    ["private.set_off_after_bar_rows(uuid, date)", false, false, false],
    ["private.settlement_set_off_alert(uuid, uuid, date, uuid, text)", false, false, false],
    ["private.statement_addressees(uuid, date, timestamptz)", false, false, false],
    ["private.statement_mandate_end(uuid, date, timestamptz)", false, false, false],
    ["private.withheld_given_back(uuid)", false, false, false],
    ["public.record_liquidation_payout_disposition(text, uuid, text, uuid, text)", false, true, true],
    ["public.record_set_off_outcome(text, uuid, text, uuid, text)", false, true, true]]'::jsonb,
  'c: the two commands are callers'' (checked inside: admins at aal2; the worker''s role keeps the default, as every '
  'command''s), never anon''s; the reads are internal');


-- The switch is still off (no M2c-7 migration writes it) --------------------------------------------------------------
select is(private.switch_on('downloaded_file_cancellation'), false,
  'the cancellation-after-download switch is still off');

select * from finish();
rollback;
