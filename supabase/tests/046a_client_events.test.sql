-- M2c-7d-1 « client events, payees and recipients » (plan docs/design/m2c-7-plan.md §6.1 but the withheld kind and the
-- disposition table, §6.2.1, §6.2.3, §6.2.7, §6.2.8's gate and forward, §6.2.10's 7d-1 part, §6.2.12, §6.2.13, §6.3's
-- protection_event_to_qualify and seizure_standing, §6.6 046a; ADR-0014 « M2c-7d-1 »). Every rule the law does not fix
-- is the servicer's default (founder Q8, Q10, Q12, Q21; OQ-41, OQ-91, OQ-93, OQ-94).
--   e     the events: the new kinds (curatorship, claims_declared with its items, seizure, seizure_released naming its
--         seizure), publication_date, qualified_at set at insert (the column added without a default: the rows from
--         before keep null), the representative given with the event; record_client_status_event's refusals
--         (claims_declared_without_proceeding, bad_publication_date, release_without_seizure ×5,
--         refers_to_not_allowed, not_declarable ×5, the representative's), nothing written; replay; roles;
--   x     the raw inserts the columns, the guard and the release index refuse; the event table still append-only;
--   s     ([check 2] gap 6) a release names its seizure: « standing » per seizure and per day (the day before the
--         release and the day of it), two seizures one released, the nightly's seizure_standing (P0 for 15 days);
--   rp    ([check 1] gap 3) the representatives: set_client_representative writes a row, a second a newer row that
--         client_addressee returns, the event row unchanged; its refusals; roles;
--   q     ([critic] L17) an old « Tutelle ou curatelle » row (qualified_at null): payouts held, no end of mandate, the
--         nightly's protection_event_to_qualify; qualified as a curatelle (its curatorship event, its effects only) or a
--         tutelle; already_qualified, not_an_old_guardianship, evidence_required; (review round 1) an old row holds
--         the payouts whatever account is confirmed until it is qualified (client_status:guardianship_to_qualify,
--         MONEY-LAW-1); the portfolio confirmation gate reads what each row counts as (TUI-2);
--   i     the side tables (representatives, qualifications, declared items): money staff read them; servicer B, a
--         client admin, a restricted viewer and a collector read none; authenticated writes none; append-only; logged;
--         (review round 1, MONEY-LAW-2, TUI-3) a letter addressed to the person who acts for the client is not the
--         client's members' to read (its request's row, its document, its PDF), a curatelle's letter is;
--   p     ([critic] F16, L2, L10) the payee after each event: per kind the blocker with no payee, the wrong kind, a
--         confirmation before the event, by the client's own user (refused), then lifted by the right kind confirmed
--         after by a second admin with its authority document; estate_without_death, protected_adult_without_measure,
--         authority_evidence_required, holder_not_client (the tutor's account; explained, accepted); curatorship
--         blocks payouts, not the confirmation gate; a guardianship then a mandate end (F16); a liquidation requires
--         the court-appointed account whatever else; a standing seizure blocks whatever the account (L14), also an
--         approval, and the file's generation; the client's own users act on no account of such a client; (review
--         round 1; M2c-7d-2, R3) an N = 0 run under a seizure is refused whatever N (sp9, its pin changed by 7d-2), a tutelle and a
--         death require the estate's account, a mandate end keeps the client's users from its accounts (TUI-4);
--   k     ([check 1] gap 10, [check 2] gap 4) epc_name_key: the writer's spellings, the boundary cases, the null rule;
--   g     (§6.2.8) a payment of a file of a client whose mandate ended by its booking date is held client_mandate_ended
--         (never allocated), before it allocated; forwarded with the reason mandate_ended (« … reçu après la fin du
--         mandat »), also on a file the client recalled since; an old guardianship row or a curatorship is no end;
--   a     ([critic] L12, [check 1] gap 7) who receives: client_addressee per event (the notary, the tutor alone, the
--         client and its curator in copy, the liquidator; none while unknown); the repayment request's recipient
--         (recipient_unknown narrowed: a mandate end is no longer refused) and its payload's addressees; (review round
--         1, TUI-4) the governing event's order (a death before a tutelle, a liquidation before a death);
--   n     the nightly's full list of codes (045b x extended);
--   c     (review round 1) the blockers' nested reads only for a client with events (CC-1); an event stamped under the
--         lock (CC-2); the commands' lock_timeout (CC-3); the end read executable by the worker's role (CC-4).
-- Each scenario runs in its own rolled-back subtransaction; the switch-dependent ones (p, g, a, q) run with the switch off
-- and on (pg_temp.iso(…, true)) — no 7d-1 rule reads it — and a guard at the end checks it is off.
begin;
select plan(48);

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


-- e. The events (§6.1, §6.2.1) ---------------------------------------------------------------------------------------
-- qualified_at was added without a default (the rows from before keep null), then given now() as its default
select is((select jsonb_build_array(a.atthasmissing, pg_get_expr(d.adbin, d.adrelid))
           from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
           where a.attrelid = 'public.client_status_event'::regclass and a.attname = 'qualified_at'),
  '[false, "now()"]'::jsonb,
  'e ([critic] L17, [check 1]): qualified_at was added with no default (no missing value written into the rows from '
  'before), then given now() for the rows recorded from 7d-1 on');

-- Cyprès's curatorship with its curator; Roux's seizure and the release naming it; Martin's proceeding (published), an
-- invoice and an advance of Martin, then its declaration naming both; the replay
create or replace function pg_temp.se1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); cu jsonb; s uuid; rel jsonb; p jsonb; inv uuid; a public.client_advance;
        dc jsonb; v_items jsonb;
begin
  inv := pg_temp.inv('a1', 'e5', 100000, 'e50');
  a := pg_temp.adv('a1', 'e6', 30000, 'e60');
  cu := pg_temp.rec('e1-1', 'a3', 'curatorship', d - 5, pg_temp.person('curator'));
  s := pg_temp.eid(pg_temp.rec('e1-2', 'a5', 'seizure', d - 4));
  rel := pg_temp.rec('e1-3', 'a5', 'seizure_released', d - 1, p_refers => s);
  p := pg_temp.rec('e1-4', 'a1', 'proceeding_opened', d - 20, p_publication => d - 12);
  v_items := jsonb_build_array(
    jsonb_build_object('document_kind', 'invoice', 'document_id', inv, 'amount_minor', '18000'),
    jsonb_build_object('document_kind', 'advance', 'document_id', a.id, 'amount_minor', '30000'));
  dc := pg_temp.rec('e1-5', 'a1', 'claims_declared', d - 2, p_declared => v_items);
  return jsonb_build_object(
    'kinds', (select jsonb_agg(e.kind order by e.kind) from public.client_status_event e
              where e.id in (pg_temp.eid(cu), s, pg_temp.eid(rel), pg_temp.eid(p), pg_temp.eid(dc))),
    'curator', (select jsonb_build_array(x.representative ->> 'role', x.evidence_document_id = pg_temp.ev('8', 'a3'),
                                         x.client_organization_id = pg_temp.c('a3'))
                from public.client_status_event_representative x where x.event_id = pg_temp.eid(cu)),
    'refers', (select e.refers_to_event_id = s from public.client_status_event e where e.id = pg_temp.eid(rel)),
    'publication', (select e.publication_date = d - 12 from public.client_status_event e where e.id = pg_temp.eid(p)),
    'qualified', (select bool_and(e.qualified_at is not null) from public.client_status_event e
                  where e.id in (pg_temp.eid(cu), s, pg_temp.eid(rel), pg_temp.eid(p), pg_temp.eid(dc))),
    'items', (select jsonb_agg(jsonb_build_array(i.document_kind, i.amount_minor, i.client_organization_id = pg_temp.c('a1'))
                               order by i.document_kind)
              from public.claims_declared_item i where i.event_id = pg_temp.eid(dc)),
    'replay', pg_temp.rec('e1-5', 'a1', 'claims_declared', d - 2, p_declared => v_items) = dc,
    'declarations', (select count(*) from public.client_status_event e
                     where e.client_organization_id = pg_temp.c('a1') and e.kind = 'claims_declared'),
    'items_after', (select count(*) from public.claims_declared_item i where i.event_id = pg_temp.eid(dc)));
end $$;
select is(pg_temp.iso('se1'),
  '{"kinds": ["claims_declared", "curatorship", "proceeding_opened", "seizure", "seizure_released"],
    "curator": ["curator", true, true], "refers": true, "publication": true, "qualified": true,
    "items": [["advance", 30000, true], ["invoice", 18000, true]], "replay": true, "declarations": 1,
    "items_after": 2}'::jsonb,
  'e: a curatorship with its curator (its first representative row, the event''s evidence), a seizure and the release '
  'naming it (refers_to_event_id), a proceeding with its BODACC publication date, a declaration with one '
  'claims_declared_item per document and its amount; qualified_at set at insert; a replay gives the same result: one '
  'event, the same items');

-- the refusals, nothing written
create or replace function pg_temp.se2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); inv1 uuid; inv8 uuid; s1 uuid; s5 uuid; dth uuid; n0 bigint; i0 bigint;
        w jsonb; v_bad jsonb;
begin
  inv1 := pg_temp.inv('a1', 'f1', 100000, 'f10');
  inv8 := pg_temp.inv('a8', 'f2', 100000, 'f20');
  s1 := pg_temp.evt('a1', 'seizure', d - 10);
  s5 := pg_temp.evt('a5', 'seizure', d - 2);
  dth := pg_temp.evt('a5', 'death', d - 9);
  perform pg_temp.evt('a8', 'proceeding_opened', d - 20);
  n0 := (select count(*) from public.client_status_event);
  i0 := (select count(*) from public.claims_declared_item);
  v_bad := jsonb_build_object('role', 'notary', 'name', 'Me Lenoir',
                              'address_lines', jsonb_build_array('1', '2', '3', '4', '5'));
  w := jsonb_build_object(
    'no_proceeding', pg_temp.code(pg_temp.rec('e2-1', 'a1', 'claims_declared', d, p_declared => jsonb_build_array(
                       jsonb_build_object('document_kind', 'invoice', 'document_id', inv1, 'amount_minor', '18000')))),
    'publication_on_a_death', pg_temp.code(pg_temp.rec('e2-2', 'a1', 'death', d - 3, p_publication => d - 1)),
    'publication_before', pg_temp.code(pg_temp.rec('e2-3', 'a6', 'liquidation', d - 3, p_publication => d - 4)),
    'publication_future', pg_temp.code(pg_temp.rec('e2-4', 'a6', 'liquidation', d - 3, p_publication => d + 1)),
    'release_naming_none', pg_temp.code(pg_temp.rec('e2-5', 'a5', 'seizure_released', d)),
    'release_of_another_client', pg_temp.code(pg_temp.rec('e2-6', 'a5', 'seizure_released', d, p_refers => s1)),
    'release_before_its_seizure', pg_temp.code(pg_temp.rec('e2-7', 'a5', 'seizure_released', d - 3, p_refers => s5)),
    'release_naming_a_death', pg_temp.code(pg_temp.rec('e2-8', 'a5', 'seizure_released', d, p_refers => dth)),
    'refers_on_a_death', pg_temp.code(pg_temp.rec('e2-9', 'a1', 'death', d, p_refers => s1)),
    'declared_other_client', pg_temp.code(pg_temp.rec('e2-10', 'a8', 'claims_declared', d, p_declared =>
                               jsonb_build_array(jsonb_build_object('document_kind', 'invoice', 'document_id', inv1,
                                                                    'amount_minor', '18000')))),
    'declared_zero', pg_temp.code(pg_temp.rec('e2-11', 'a8', 'claims_declared', d, p_declared => jsonb_build_array(
                       jsonb_build_object('document_kind', 'invoice', 'document_id', inv8, 'amount_minor', '0')))),
    'declared_wrong_kind', pg_temp.code(pg_temp.rec('e2-12', 'a8', 'claims_declared', d, p_declared =>
                             jsonb_build_array(jsonb_build_object('document_kind', 'advance', 'document_id', inv8,
                                                                  'amount_minor', '18000')))),
    'declared_credit_note', pg_temp.code(pg_temp.rec('e2-12b', 'a8', 'claims_declared', d, p_declared =>
                              jsonb_build_array(jsonb_build_object('document_kind', 'credit_note', 'document_id', inv8,
                                                                   'amount_minor', '18000')))),
    'declared_none', pg_temp.code(pg_temp.rec('e2-13', 'a8', 'claims_declared', d)),
    'declared_on_a_death', pg_temp.code(pg_temp.rec('e2-14', 'a1', 'death', d, p_declared => jsonb_build_array(
                             jsonb_build_object('document_kind', 'invoice', 'document_id', inv1, 'amount_minor', '18000')))),
    'rep_on_a_mandate_end', pg_temp.code(pg_temp.rec('e2-15', 'a4', 'mandate_ended', d, pg_temp.person('heirs'))),
    'rep_role', pg_temp.code(pg_temp.rec('e2-16', 'a1', 'death', d, pg_temp.person('tutor'))),
    'rep_no_name', pg_temp.code(pg_temp.rec('e2-17', 'a1', 'death', d, pg_temp.person('notary') || '{"name": " "}')),
    'rep_five_lines', pg_temp.code(pg_temp.rec('e2-18', 'a1', 'death', d, v_bad)),
    'ops', pg_temp.code(pg_temp.rec('e2-19', 'a1', 'death', d, p_user => '01')),
    'aal1', pg_temp.code(pg_temp.rec('e2-20', 'a1', 'death', d, p_aal => 'aal1')),
    'written', (select count(*) from public.client_status_event) - n0,
    'items', (select count(*) from public.claims_declared_item) - i0);
  return w || jsonb_build_object(
    'first_release', pg_temp.code(pg_temp.rec('e2-21', 'a5', 'seizure_released', d, p_refers => s5)),
    'second_release', pg_temp.code(pg_temp.rec('e2-22', 'a5', 'seizure_released', d, p_refers => s5)));
end $$;
select is(pg_temp.iso('se2'),
  '{"no_proceeding": "claims_declared_without_proceeding", "publication_on_a_death": "bad_publication_date",
    "publication_before": "bad_publication_date", "publication_future": "bad_publication_date",
    "release_naming_none": "release_without_seizure", "release_of_another_client": "release_without_seizure",
    "release_before_its_seizure": "release_without_seizure", "release_naming_a_death": "release_without_seizure",
    "refers_on_a_death": "refers_to_not_allowed", "declared_other_client": "not_declarable",
    "declared_zero": "not_declarable", "declared_wrong_kind": "not_declarable",
    "declared_credit_note": "not_declarable", "declared_none": "not_declarable",
    "declared_on_a_death": "not_declarable", "rep_on_a_mandate_end": "not_an_event_with_representative",
    "rep_role": "role_mismatch", "rep_no_name": "bad_representative", "rep_five_lines": "bad_representative",
    "ops": "not allowed", "aal1": "not allowed", "written": 0, "items": 0, "first_release": "ok",
    "second_release": "release_without_seizure"}'::jsonb,
  'e: record_client_status_event refuses a declaration with no proceeding, a publication date on a death, before '
  'the judgment or in the future, a release naming nothing, another client''s seizure, a seizure effective after it '
  'or a death, a referred event on a death, a declared item of another client, of 0, of the wrong kind or a credit '
  'note, a declaration without items, items on a death, a representative on a mandate end, of the wrong role or '
  'shape; ops and aal1 are not admins at aal2; nothing written; a seizure released twice → release_without_seizure');

-- x. The raw inserts the columns, the guard and the release index refuse; the table stays append-only --------------
create or replace function pg_temp.sx1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); s uuid; v_ins text;
begin
  s := pg_temp.evt('a5', 'seizure', d - 3);
  v_ins := 'insert into public.client_status_event (organization_id, client_organization_id, kind, effective_date, '
           'evidence_document_id, recorded_by, refers_to_event_id, publication_date, qualified_at) values '
           '(''00000000-0000-0000-0000-0000000000aa'', %L, %L, %L, %L, ''10000000-0000-0000-0000-000000000004'', %L, '
           '%L, %s)';
  perform pg_temp.evt('a5', 'seizure_released', d, p_refers => s);
  return jsonb_build_object(
    'release_without_refers', pg_temp.state(format(v_ins, pg_temp.c('a5'), 'seizure_released', d, pg_temp.ev('8', 'a5'),
                                                   null, null, 'now()')),
    'death_with_refers', pg_temp.state(format(v_ins, pg_temp.c('a5'), 'death', d, pg_temp.ev('8', 'a5'), s, null,
                                              'now()')),
    'release_of_another_client', pg_temp.state(format(v_ins, pg_temp.c('a1'), 'seizure_released', d,
                                                      pg_temp.ev('8', 'a1'), s, null, 'now()')),
    'release_before_its_seizure', pg_temp.state(format(v_ins, pg_temp.c('a5'), 'seizure_released', d - 5,
                                                       pg_temp.ev('8', 'a5'), s, null, 'now()')),
    'second_release', pg_temp.state(format(v_ins, pg_temp.c('a5'), 'seizure_released', d, pg_temp.ev('8', 'a5'), s,
                                           null, 'now()')),
    'publication_on_a_death', pg_temp.state(format(v_ins, pg_temp.c('a5'), 'death', d, pg_temp.ev('8', 'a5'), null, d,
                                                   'now()')),
    'qualified_at_null', pg_temp.state(format(v_ins, pg_temp.c('a5'), 'death', d, pg_temp.ev('8', 'a5'), null, null,
                                              'null')),
    'update', pg_temp.state('update public.client_status_event set note = ''x'''),
    'delete', pg_temp.state('delete from public.client_status_event'));
end $$;
select is(pg_temp.iso('sx1'),
  '{"release_without_refers": "23514", "death_with_refers": "23514", "release_of_another_client": "23514",
    "release_before_its_seizure": "23514", "second_release": "23505", "publication_on_a_death": "23514",
    "qualified_at_null": "23514", "update": "23514", "delete": "23514"}'::jsonb,
  'x ([check 2] gap 6, [check 1] gap 3): raw inserts — a release naming nothing, a death naming an event, a release '
  'publication date on a death (the column checks), a release of another client''s seizure or effective before it, '
  'a row with qualified_at null (the guard), a second release of one seizure (client_status_event_release_uq); an '
  'UPDATE or a DELETE of an event still raises (refuse_change)');


-- s. ([check 2] gap 6) A release names its seizure: « standing » per seizure and per day -------------------------------
create or replace function pg_temp.ss1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); s1 uuid; s2 uuid; s0 uuid; w jsonb;
begin
  s1 := pg_temp.evt('a5', 'seizure', d - 10);
  s2 := pg_temp.evt('a5', 'seizure', d - 8);
  s0 := pg_temp.evt('a5', 'seizure', d - 40, '20 days');
  perform pg_temp.rec('ss-0', 'a5', 'seizure_released', d - 30, p_refers => s0);
  w := jsonb_build_object('release', pg_temp.code(pg_temp.rec('ss-1', 'a5', 'seizure_released', d - 3, p_refers => s1)));
  w := w || jsonb_build_object(
    'before_both', pg_temp.standing('a5', d - 11) = '{}'::uuid[],
    'day_before', pg_temp.standing('a5', d - 4) = array[s1, s2],
    'on_the_day', pg_temp.standing('a5', d - 3) = array[s2],
    'blockers', pg_temp.blk('a5'),
    'nightly', pg_temp.night('seizure_standing', s2));
  perform pg_temp.rec('ss-2', 'a5', 'seizure_released', d, p_refers => s2);
  return w || jsonb_build_object('both_released', pg_temp.standing('a5', d) = '{}'::uuid[],
                                 'blockers_after', pg_temp.blk('a5'),
                                 'nightly_after', pg_temp.night('seizure_standing', s2));
end $$;
select is(pg_temp.iso('ss1'),
  '{"release": "ok", "before_both": true, "day_before": true, "on_the_day": true, "blockers": ["client_status:seizure"],
    "nightly": [[true, true]], "both_released": true, "blockers_after": [], "nightly_after": []}'::jsonb,
  's ([check 2] gap 6, [critic] L14): a seizure stands from its effective date until the release naming it is '
  'effective — the day before the release both stand, on its day only the other; the blockers and seizure_standing '
  '(P0 within 15 days of its recording) still list the other; once each is released, nothing');
-- an old seizure (recorded 20 days ago) is still alerted, no longer as P0
create or replace function pg_temp.ss2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); s uuid;
begin
  s := pg_temp.evt('a5', 'seizure', d - 30, '20 days');
  return pg_temp.night('seizure_standing', s);
end $$;
select is(pg_temp.iso('ss2'), '[[true, false]]'::jsonb,
  's: a seizure recorded 20 days ago and not released → seizure_standing, no longer P0 (P0 for 15 days)');


-- rp. ([check 1] gap 3) Who acts for the client: an append-only side table --------------------------------------------
create or replace function pg_temp.srp1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); dth uuid; v_before text; r2 jsonb; me uuid; o uuid; w jsonb;
begin
  dth := pg_temp.evt('a2', 'death', d - 3);
  v_before := (select e.xmin::text || row(e.*)::text from public.client_status_event e where e.id = dth);
  perform pg_temp.rep('rp-1', dth, pg_temp.person('notary'));
  r2 := pg_temp.rep('rp-2', dth, pg_temp.person('heirs', 'Les héritiers de Mme Lilas'));
  me := pg_temp.evt('a4', 'mandate_ended', d - 3);
  o := pg_temp.old_tutelle('a7', d - 3);
  w := jsonb_build_object(
    'rows', (select count(*) from public.client_status_event_representative x where x.event_id = dth),
    'in_force', pg_temp.addr('a2'),
    'event_unchanged', (select e.xmin::text || row(e.*)::text from public.client_status_event e where e.id = dth)
                       = v_before,
    'replay', pg_temp.rep('rp-2', dth, pg_temp.person('heirs', 'Les héritiers de Mme Lilas')) = r2,
    'rows_after_replay', (select count(*) from public.client_status_event_representative x where x.event_id = dth),
    'not_an_event', pg_temp.code(pg_temp.rep('rp-3', me, pg_temp.person('heirs'))),
    'old_tutelle', pg_temp.code(pg_temp.rep('rp-3b', o, pg_temp.person('tutor'))),
    'bad_role', pg_temp.code(pg_temp.rep('rp-4', dth, pg_temp.person('notary') || '{"role": "cousin"}')),
    'no_lines', pg_temp.code(pg_temp.rep('rp-5', dth, pg_temp.person('notary') || '{"address_lines": []}')),
    'extra_key', pg_temp.code(pg_temp.rep('rp-6', dth, pg_temp.person('notary')
                                                       || '{"iban": "FR7630004000031234567890143"}')),
    'long_name', pg_temp.code(pg_temp.rep('rp-7', dth, pg_temp.person('notary', repeat('x', 141)))),
    'long_line', pg_temp.code(pg_temp.rep('rp-7b', dth, pg_temp.person('notary')
                                                         || jsonb_build_object('address_lines',
                                                                               jsonb_build_array(repeat('x', 71))))),
    'role_mismatch', pg_temp.code(pg_temp.rep('rp-8', dth, pg_temp.person('curator'))),
    'evidence_other_client', pg_temp.code(pg_temp.rep('rp-9', dth, pg_temp.person('notary'), pg_temp.ev('9', 'a1'))),
    'evidence_a_rib', pg_temp.code(pg_temp.rep('rp-10', dth, pg_temp.person('notary'), pg_temp.ev('2', 'a2'))),
    'authority_evidence', pg_temp.code(pg_temp.rep('rp-11', dth, pg_temp.person('notary'), pg_temp.ev('b', 'a2'))),
    'ops', pg_temp.code(pg_temp.rep('rp-12', dth, pg_temp.person('notary'), p_user => '01')),
    'aal1', pg_temp.code(pg_temp.rep('rp-13', dth, pg_temp.person('notary'), p_aal => 'aal1')));
  -- (each read in its own statement: a statement's snapshot never sees what the functions it calls insert)
  return w || jsonb_build_object(
    'rows_at_the_end', (select count(*) from public.client_status_event_representative x where x.event_id = dth));
end $$;
select is(pg_temp.iso('srp1'),
  '{"rows": 2, "in_force": [["heirs", "Les héritiers de Mme Lilas", false]], "event_unchanged": true, "replay": true,
    "rows_after_replay": 2, "not_an_event": "not_an_event_with_representative",
    "old_tutelle": "not_an_event_with_representative", "bad_role": "bad_representative",
    "no_lines": "bad_representative", "extra_key": "bad_representative", "long_name": "bad_representative",
    "long_line": "bad_representative", "role_mismatch": "role_mismatch", "evidence_other_client": "evidence_required",
    "evidence_a_rib": "evidence_required", "authority_evidence": "ok", "ops": "not allowed", "aal1": "not allowed",
    "rows_at_the_end": 3}'::jsonb,
  'rp ([check 1] gap 3): set_client_representative writes a row, a second a newer one that client_addressee returns; '
  'the event row is unchanged (xmin and every column); a replay writes nothing; refused on a mandate end and on an old '
  'row still to qualify, for a bad shape (role, no address, an extra key, a name of 141 or a line of 71 characters), '
  'the wrong role, evidence of another client or a RIB; an authority evidence is accepted; admins at aal2 only');


-- q. ([critic] L17) The old « Tutelle ou curatelle » rows, qualified -------------------------------------------------
create or replace function pg_temp.sq1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); o uuid; r jsonb; cu uuid; w jsonb;
begin
  o := pg_temp.old_tutelle('a7', d - 10);
  w := jsonb_build_object(
    'effective', private.client_event_effective(o),
    'blocks', pg_temp.blk('a7'),
    'end', (select count(*) from private.client_end_event(pg_temp.c('a7'), d)),
    'alert', pg_temp.night('protection_event_to_qualify', o),
    'not_old', pg_temp.code(pg_temp.qual('q-0', pg_temp.evt('a8', 'guardianship', d - 1), 'curatorship')),
    'death', pg_temp.code(pg_temp.qual('q-1', pg_temp.evt('a2', 'death', d - 1), 'guardianship')),
    'evidence', pg_temp.code(pg_temp.qual('q-2', o, 'curatorship', pg_temp.ev('9', 'a1'))),
    'bad_kind', pg_temp.code(pg_temp.qual('q-2b', o, 'death')),
    'ops', pg_temp.code(pg_temp.qual('q-2c', o, 'curatorship', p_user => '01')));
  r := pg_temp.qual('q-3', o, 'curatorship');
  cu := (r ->> 'curatorship_event_id')::uuid;
  return w || jsonb_build_object(
    'qualified', pg_temp.code(r),
    'row', (select jsonb_build_array(q.kind, q.curatorship_event_id = cu, q.evidence_document_id = pg_temp.ev('9', 'a7'))
            from public.client_status_event_qualification q where q.event_id = o),
    'curatorship_event', (select jsonb_build_array(e.kind, e.client_organization_id = pg_temp.c('a7'),
                                                   e.effective_date = d - 10,
                                                   e.evidence_document_id = pg_temp.ev('8', 'a7'),
                                                   e.qualified_at is not null)
                          from public.client_status_event e where e.id = cu),
    'old_now', private.client_event_effective(o),
    'new_counts', private.client_event_effective(cu),
    'blocks_after', pg_temp.blk('a7'),
    'end_after', (select count(*) from private.client_end_event(pg_temp.c('a7'), d)),
    'alert_after', pg_temp.night('protection_event_to_qualify', o),
    'again', pg_temp.code(pg_temp.qual('q-4', o, 'guardianship')),
    'replay', pg_temp.qual('q-3', o, 'curatorship') = r,
    'rows', (select count(*) from public.client_status_event_qualification q where q.event_id = o));
end $$;
select is(pg_temp.iso('sq1'),
  '{"effective": "guardianship_to_qualify", "blocks": ["client_status:guardianship_to_qualify"], "end": 0,
    "alert": [[true, false]],
    "not_old": "not_an_old_guardianship", "death": "not_an_old_guardianship", "evidence": "evidence_required",
    "bad_kind": "bad_kind", "ops": "not allowed", "qualified": "ok",
    "row": ["curatorship", true, true], "curatorship_event": ["curatorship", true, true, true, true], "old_now": null,
    "new_counts": "curatorship", "blocks_after": ["client_status:curatorship"], "end_after": 0, "alert_after": [],
    "again": "already_qualified", "replay": true, "rows": 1}'::jsonb,
  'q ([critic] L17, [check 1] gap 3): an old « Tutelle ou curatelle » row keeps payouts held, ends no mandate and is '
  'listed protection_event_to_qualify; qualify_protection_event refuses a row recorded since, another kind, evidence '
  'of another client, a bad kind, ops; qualified as a curatelle it inserts its qualification and a curatorship event '
  '(same client, date and evidence, qualified_at set): the old row then counts as nothing, the new one as a '
  'curatorship (the payee rule only), the alert stops; a second call → already_qualified; a replay the same result');
create or replace function pg_temp.sq2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); o uuid; r jsonb;
begin
  perform pg_temp.confirmed_ago('a7');
  o := pg_temp.old_tutelle('a7', d - 10);
  r := pg_temp.qual('q-5', o, 'guardianship');
  return jsonb_build_object(
    'qualified', pg_temp.code(r), 'curatorship_event', r -> 'curatorship_event_id',
    'effective', private.client_event_effective(o),
    'end', (select jsonb_build_array(x.kind, x.event_id = o) from private.client_end_event(pg_temp.c('a7'), d) x),
    'blocks', pg_temp.blk('a7'),
    'gate', pg_temp.match('a7', 'c6', 50000, d - 3));
end $$;
select is(pg_temp.iso('sq2'),
  '{"qualified": "ok", "curatorship_event": null, "effective": "guardianship", "end": ["guardianship", true],
    "blocks": ["client_status:guardianship"], "gate": "client_mandate_ended"}'::jsonb,
  'q: qualified as a tutelle, the old row is a guardianship from then: the end of the mandate (C. civ. 2003), its '
  'payments after it held');
-- (review round 1, MONEY-LAW-1; plan §6.1, §6.2.13 « until then the row keeps today's effect (payouts held) ») an old
-- row holds the payouts whatever account is confirmed after it, until it is qualified: then the qualified kind's payee
-- lifts it — a tutelle the protected adult's account confirmed after the old row; a curatelle only an account confirmed
-- after its curatorship event (recorded at the qualification)
create or replace function pg_temp.sq3() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); o uuid; o9 uuid; acc uuid; w jsonb;
begin
  o := pg_temp.old_tutelle('a7', d - 10);
  acc := pg_temp.payee('q3-a', 'a7', pg_temp.ib('A'), 'DURAND SARL', 'protected_adult');
  w := jsonb_build_object(
    'confirmed_after_the_old_row', pg_temp.blk('a7'),
    'payee', (select jsonb_build_array(r.kind, r.event_kind) from private.client_payee_rule(pg_temp.c('a7'), d) r),
    'page_payee', pg_temp.read_as('01', format('select public.client_events_view(%L) -> ''payee''', pg_temp.c('a7'))),
    'estate_does_not', (select count(*) from private.client_payee_rule(pg_temp.c('a7'), d) r where r.kind = 'estate'));
  w := w || jsonb_build_object('qualified', pg_temp.code(pg_temp.qual('q3-b', o, 'guardianship')));
  w := w || jsonb_build_object('qualified_tutelle', pg_temp.blk('a7'));
  o9 := pg_temp.old_tutelle('a9', d - 12);
  perform pg_temp.payee('q3-c', 'a9', pg_temp.ib('B'), 'MOREAU SA', 'protected_adult');
  w := w || jsonb_build_object('a9_before', pg_temp.blk('a9'));
  w := w || jsonb_build_object('a9_qualified', pg_temp.code(pg_temp.qual('q3-d', o9, 'curatorship')));
  w := w || jsonb_build_object('qualified_curatelle', pg_temp.blk('a9'));
  acc := pg_temp.payee('q3-e', 'a9', pg_temp.ib('C'), 'MOREAU SA', 'protected_adult');
  perform pg_temp.confirmed_at(acc, clock_timestamp());   -- confirmed after the curatorship event's recording
  return w || jsonb_build_object('confirmed_after_the_curatelle', pg_temp.blk('a9'));
end $$;
select is(pg_temp.iso('sq3'),
  '{"confirmed_after_the_old_row": ["client_status:guardianship_to_qualify"],
    "payee": ["to_qualify", "guardianship_to_qualify"],
    "page_payee": {"kind": "to_qualify", "event_kind": "guardianship_to_qualify"}, "estate_does_not": 0,
    "qualified": "ok", "qualified_tutelle": [], "a9_before": ["client_status:guardianship_to_qualify"],
    "a9_qualified": "ok", "qualified_curatelle": ["client_status:curatorship"],
    "confirmed_after_the_curatelle": []}'::jsonb,
  'q (review round 1, MONEY-LAW-1; plan §6.1, §6.2.13): an old « Tutelle ou curatelle » row keeps the payouts held '
  'whatever account is confirmed after it (a protected adult''s account in the client''s name, with the judgment, by a '
  'second admin): client_status:guardianship_to_qualify, a payee no account kind meets; qualified as a tutelle, that '
  'account lifts it; qualified as a curatelle, only an account confirmed after its curatorship event does');
select is(pg_temp.iso('sq3', true), pg_temp.iso('sq3'), 'q (MONEY-LAW-1): the same with the switch on');
-- (review round 1, TUI-2) the portfolio confirmation gate reads what each event counts as: an old row to qualify is
-- its own reason (no end of mandate stated), a row qualified as a curatelle none (a curatelle ends no mandate: C. civ.
-- 2003 names « la tutelle des majeurs »), a row qualified as a tutelle the end of the mandate, as a tutelle recorded since
create or replace function pg_temp.sq4() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); o8 uuid; o9 uuid;
begin
  perform pg_temp.old_tutelle('a7', d - 10);
  o8 := pg_temp.old_tutelle('a8', d - 11);
  o9 := pg_temp.old_tutelle('a9', d - 12);
  perform pg_temp.qual('q4-8', o8, 'curatorship');
  perform pg_temp.qual('q4-9', o9, 'guardianship');
  perform pg_temp.evt('a6', 'guardianship', d - 13);
  return (select jsonb_object_agg(x.c, (select coalesce(jsonb_agg(b order by b), '[]')
                                        from unnest(private.portfolio_confirmation_blockers(pg_temp.pf(x.c), d)) b
                                        where b ~ '^client_(mandate_ended|deceased|in_liquidation|protection_to_qualify)'))
          from unnest(array['a6', 'a7', 'a8', 'a9']) x (c))
         || jsonb_build_object('dates', jsonb_build_array(to_char(d - 10, 'YYYY-MM-DD'), to_char(d - 12, 'YYYY-MM-DD'),
                                                          to_char(d - 13, 'YYYY-MM-DD')));
end $$;
select is((select jsonb_build_object(
             'a6', v -> 'a6' = jsonb_build_array('client_mandate_ended:' || (v -> 'dates' ->> 2)),
             'a7', v -> 'a7' = jsonb_build_array('client_protection_to_qualify:' || (v -> 'dates' ->> 0)),
             'a8', v -> 'a8',
             'a9', v -> 'a9' = jsonb_build_array('client_mandate_ended:' || (v -> 'dates' ->> 1)))
           from (select pg_temp.iso('sq4') v) x),
  '{"a6": true, "a7": true, "a8": [], "a9": true}'::jsonb,
  'q (review round 1, TUI-2): the portfolio confirmation gate — an old row still to qualify blocks it as '
  'client_protection_to_qualify (no end of mandate stated), qualified as a curatelle it does not block (no end), '
  'qualified as a tutelle it is client_mandate_ended, as a tutelle recorded since 7d-1');


-- i. The side tables: money staff only, append-only, logged --------------------------------------------------------
create or replace function pg_temp.si1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); inv uuid; g uuid; o uuid; r jsonb; dc jsonb; v_read text; q jsonb;
begin
  inv := pg_temp.inv('a8', 'c7', 100000, 'c70');
  g := pg_temp.evt('a8', 'guardianship', d - 3);
  r := pg_temp.rep('i-1', g, pg_temp.person('tutor'));
  o := pg_temp.old_tutelle('a8', d - 20);
  q := pg_temp.qual('i-2', o, 'curatorship');
  perform pg_temp.evt('a8', 'proceeding_opened', d - 30);
  dc := pg_temp.rec('i-3', 'a8', 'claims_declared', d - 1, p_declared => jsonb_build_array(
          jsonb_build_object('document_kind', 'invoice', 'document_id', inv, 'amount_minor', '18000')));
  v_read := 'select to_jsonb(array[(select count(*) from public.client_status_event_representative), '
            '(select count(*) from public.client_status_event_qualification), '
            '(select count(*) from public.claims_declared_item)])';
  return jsonb_build_object(
    'made', jsonb_build_array(pg_temp.code(r), pg_temp.code(q), pg_temp.code(dc)),
    'money_staff', pg_temp.read_as('01', v_read),
    'servicer_b', pg_temp.read_as('05', v_read),
    'client_admin', pg_temp.read_as('03', v_read),
    'restricted_viewer', pg_temp.read_as('07', v_read),
    'collector', pg_temp.read_as('02', v_read),
    'client_page_read', pg_temp.code(pg_temp.read_as('03', format('select public.client_events_view(%L)',
                                                                  pg_temp.c('a8')))),
    'staff_page_read', pg_temp.read_as('01', format('select public.client_events_view(%L)', pg_temp.c('a8'))) ? 'events',
    'append_only', jsonb_build_array(
      pg_temp.state('update public.client_status_event_representative set recorded_at = now()'),
      pg_temp.state('delete from public.client_status_event_qualification'),
      pg_temp.state('update public.claims_declared_item set amount_minor = 1')),
    'change_log', jsonb_build_array(
      (select count(*) from private.change_log l where l.table_name = 'public.client_status_event_representative'
         and l.row_id = (select x.id::text from public.client_status_event_representative x where x.event_id = g)),
      (select count(*) from private.change_log l where l.table_name = 'public.client_status_event_qualification'
         and l.row_id = o::text),
      (select count(*) from private.change_log l where l.table_name = 'public.claims_declared_item'
         and l.row_id like pg_temp.eid(dc)::text || ':%')));
end $$;
select is(pg_temp.iso('si1'),
  '{"made": ["ok", "ok", "ok"], "money_staff": [1, 1, 1], "servicer_b": [0, 0, 0], "client_admin": [0, 0, 0],
    "restricted_viewer": [0, 0, 0], "collector": [0, 0, 0], "client_page_read": "not allowed", "staff_page_read": true,
    "append_only": ["23514", "23514", "23514"], "change_log": [1, 1, 1]}'::jsonb,
  'i ([check 1] gap 3, [check 2]): the representatives, the qualifications and the declared items are read by money '
  'staff only — not servicer B, the client''s admin, its restricted viewer nor a collector (the names and addresses '
  'are personal data), nor the events'' page read; append-only (refuse_change); one change-log row each');
select is((select array_agg(p order by p) from (
  select p from unnest(array['public.client_status_event_representative', 'public.client_status_event_qualification',
                             'public.claims_declared_item']) p
  where has_table_privilege('authenticated', p, 'INSERT') or has_table_privilege('authenticated', p, 'UPDATE')
     or has_table_privilege('authenticated', p, 'DELETE') or has_table_privilege('anon', p, 'SELECT')
     or not exists (select 1 from pg_class c where c.oid = p::regclass and c.relrowsecurity)) x),
  null, 'i: RLS on the three side tables; authenticated writes none (inserts, updates, deletes), anon reads none');
-- (review round 1, MONEY-LAW-2, TUI-3; plan §6.1: the representatives' names and addresses are never the client's
-- users') a letter addressed to the person who acts for the client names that person: neither its request's row (the
-- payload) nor its PDF (the document's row, the stored object) is the client's members' to read; the client's requests
-- list it without its letter (to_representative). A curatelle's letter is addressed to the client (its curator in copy:
-- plan §6.2.12): its members read it, as a plain client's
create or replace function pg_temp.si2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); a public.client_advance; b public.client_advance; e uuid; r jsonb; q jsonb;
        v_doc uuid; v_doc2 uuid; v_req uuid; v_req2 uuid; v_read text; v_list text;
begin
  -- Petit (a8; 03 its client admin, 07 its restricted viewer): a tutelle, its tutor recorded: the letter to the tutor
  a := pg_temp.adv('a8', '8c', 30000, '8c0');
  e := pg_temp.evt('a8', 'guardianship', d - 1);
  perform pg_temp.rep('i2-t', e, pg_temp.person('tutor'));
  r := pg_temp.dra('i2-1', 'a8', array[a.id]);
  v_req := (r ->> 'request_id')::uuid;
  v_doc := pg_temp.drawn(v_req);
  -- Lilas (a2; 08 its client admin): a curatelle, its curator recorded: the letter to the client, the curator in copy
  b := pg_temp.adv('a2', '2c', 30000, '2c0');
  e := pg_temp.evt('a2', 'curatorship', d - 1);
  perform pg_temp.rep('i2-c', e, pg_temp.person('curator'));
  q := pg_temp.dra('i2-2', 'a2', array[b.id]);
  v_req2 := (q ->> 'request_id')::uuid;
  v_doc2 := pg_temp.drawn(v_req2);
  v_read := 'select to_jsonb(array[(select count(*) from public.advance_repayment_request where id = %L), '
            '(select count(*) from public.document where id = %L), '
            '(select count(*) from storage.objects where bucket_id = ''documents'' and name = %L)])';
  v_list := 'select coalesce(jsonb_agg(jsonb_build_array(x ->> ''document_id'' = %L, x -> ''to_representative'', '
            'x ->> ''total_minor'')), ''[]'') from jsonb_array_elements(public.client_repayment_requests(%L) -> ''rows'') x';
  return jsonb_build_object(
    'made', jsonb_build_array(pg_temp.why_not(r), pg_temp.why_not(q)),
    'addressed_to', jsonb_build_array((pg_temp.rq(r)).payload -> 'recipient' ->> 'role',
                                      (pg_temp.rq(q)).payload -> 'recipient' ->> 'role'),
    'tutor_letter_client_admin', pg_temp.read_as('03', format(v_read, v_req, v_doc, pg_temp.dra_path(v_req))),
    'tutor_letter_money_staff', pg_temp.read_as('01', format(v_read, v_req, v_doc, pg_temp.dra_path(v_req))),
    'tutor_letter_listed_client', pg_temp.read_as('03', format(v_list, v_doc, pg_temp.c('a8'))),
    'tutor_letter_listed_staff', pg_temp.read_as('01', format(v_list, v_doc, pg_temp.c('a8'))),
    'curatelle_letter_client_admin', pg_temp.read_as('08', format(v_read, v_req2, v_doc2, pg_temp.dra_path(v_req2))),
    'curatelle_letter_listed_client', pg_temp.read_as('08', format(v_list, v_doc2, pg_temp.c('a2'))));
end $$;
select is(pg_temp.iso('si2'),
  '{"made": ["ok", "ok"], "addressed_to": ["tutor", null],
    "tutor_letter_client_admin": [0, 0, 0], "tutor_letter_money_staff": [1, 1, 1],
    "tutor_letter_listed_client": [[null, true, "30000"]], "tutor_letter_listed_staff": [[true, true, "30000"]],
    "curatelle_letter_client_admin": [1, 1, 1], "curatelle_letter_listed_client": [[true, false, "30000"]]}'::jsonb,
  'i (review round 1, MONEY-LAW-2, TUI-3; plan §6.1): a letter addressed to the person who acts for the client (the '
  'tutor) is read by money staff only — the client''s admin reads neither its request''s row (the payload names the '
  'tutor), nor its document''s row, nor its PDF; the client''s requests list it with no letter (to_representative); a '
  'curatelle''s letter, addressed to the client with its curator in copy, the client''s admin reads');


-- p. The payee after each event (§6.2.7; [critic] F16, L2, L10; founder Q8) -------------------------------------------
-- after a death: the estate's account (the notary's, or one every heir designates), with its authority evidence,
-- confirmed after the death by a second admin
create or replace function pg_temp.sp1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb; r jsonb; acc uuid;
begin
  perform pg_temp.confirmed_ago('a2');
  perform pg_temp.evt('a2', 'death', d - 3);
  w := jsonb_build_object('no_payee', pg_temp.blk('a2'));
  r := pg_temp.propose('p1-a', 'a2', pg_temp.ib('A'), 'LILAS FINANCE');
  w := w || jsonb_build_object('own_user_confirms', pg_temp.code(pg_temp.confirm('p1-a', pg_temp.pid(r), '08')));
  perform pg_temp.confirm('p1-b', pg_temp.pid(r));
  w := w || jsonb_build_object('client_kind_after', pg_temp.blk('a2'),
    'estate_without_authority', pg_temp.code(pg_temp.propose('p1-c', 'a2', pg_temp.ib('B'), 'SCP LENOIR NOTAIRES',
                                                             'estate', false)),
    'estate_without_death', pg_temp.code(pg_temp.propose('p1-c2', 'a3', pg_temp.ib('B'), 'SCP LENOIR NOTAIRES',
                                                         'estate')));
  r := pg_temp.propose('p1-d', 'a2', pg_temp.ib('B'), 'SCP LENOIR NOTAIRES', 'estate');
  w := w || jsonb_build_object('estate_own_user_confirms', pg_temp.code(pg_temp.confirm('p1-e', pg_temp.pid(r), '08')),
                               'estate_own_user_rejects', pg_temp.try('08', format(
                                 'select public.reject_payout_account(''rej-046a-p1'', %L, ''non'')', pg_temp.pid(r))));
  perform pg_temp.confirm('p1-f', pg_temp.pid(r));
  perform pg_temp.confirmed_at(pg_temp.pid(r), now() - interval '3 hours');   -- before the death was recorded
  w := w || jsonb_build_object('confirmed_before_the_death', pg_temp.blk('a2'));
  acc := pg_temp.payee('p1-g', 'a2', pg_temp.ib('C'), 'SCP LENOIR NOTAIRES', 'estate');
  w := w || jsonb_build_object('lifted', pg_temp.blk('a2'),
                               'kept', (select jsonb_build_array(a.kind, a.authority_document_id = pg_temp.ev('b', 'a2'),
                                                                 a.confirmed_via)
                                        from public.client_payout_account a where a.id = acc));
  return w;
end $$;
select is(pg_temp.iso('sp1'),
  '{"no_payee": ["client_status:death"], "own_user_confirms": "court_appointed", "client_kind_after": ["client_status:death"],
    "estate_without_authority": "authority_evidence_required", "estate_without_death": "estate_without_death",
    "estate_own_user_confirms": "court_appointed",
    "estate_own_user_rejects": "payout account refused: court_appointed",
    "confirmed_before_the_death": ["client_status:death"], "lifted": [],
    "kept": ["estate", true, "second_admin"]}'::jsonb,
  'p ([critic] L10; C. civ. 1309; founder Q8): after a death the payout is blocked; the client''s own account, even '
  'confirmed after it, does not lift it; the client''s own users confirm and refuse nothing; an estate account needs '
  'its authority evidence and a death; confirmed before the death was recorded, it does not lift; confirmed after it '
  'by a second admin with its evidence, it does');
select is(pg_temp.iso('sp1', true), pg_temp.iso('sp1'), 'p: the same with the switch on (no 7d-1 rule reads it)');

-- after a tutelle: an account in the client's name (C. civ. 427 al. 5), the judgment, the holder's name rule
create or replace function pg_temp.sp2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb; r jsonb;
begin
  perform pg_temp.confirmed_ago('a8');
  perform pg_temp.evt('a8', 'guardianship', d - 5);
  w := jsonb_build_object(
    'no_payee', pg_temp.blk('a8'),
    'tutor_s_account', pg_temp.code(pg_temp.propose('p2-a', 'a8', pg_temp.ib('D'), 'UDAF DU RHONE', 'protected_adult')),
    'without_judgment', pg_temp.code(pg_temp.propose('p2-b', 'a8', pg_temp.ib('D'), 'PETIT SAS', 'protected_adult',
                                                     false)),
    'explanation_501', pg_temp.code(pg_temp.propose('p2-c', 'a8', pg_temp.ib('D'), 'M. PETIT', 'protected_adult', true,
                                                    repeat('x', 501))),
    'explanation_blank', pg_temp.code(pg_temp.propose('p2-c2', 'a8', pg_temp.ib('D'), 'M. PETIT', 'protected_adult',
                                                      true, '   ')),
    'without_measure', pg_temp.code(pg_temp.propose('p2-c3', 'a4', pg_temp.ib('D'), 'LAMBERT SA', 'protected_adult')));
  r := pg_temp.propose('p2-d', 'a8', pg_temp.ib('D'), 'Petit SAS', 'protected_adult');
  w := w || jsonb_build_object('own_user_confirms', pg_temp.code(pg_temp.confirm('p2-e', pg_temp.pid(r), '03')),
                               'explanation_kept', (select a.holder_attestation from public.client_payout_account a
                                                    where a.id = pg_temp.pid(r)));
  perform pg_temp.confirm('p2-f', pg_temp.pid(r));
  w := w || jsonb_build_object('lifted', pg_temp.blk('a8'));
  r := pg_temp.propose('p2-g', 'a8', pg_temp.ib('E'), 'M. JEAN PETIT', 'protected_adult', true,
                       'RIB au nom du gérant, majeur protégé ; tuteur : UDAF (test)');
  return w || jsonb_build_object('explained', pg_temp.code(r),
                                 'explanation', (select a.holder_attestation from public.client_payout_account a
                                                 where a.id = pg_temp.pid(r)));
end $$;
select is(pg_temp.iso('sp2'),
  '{"no_payee": ["client_status:guardianship"], "tutor_s_account": "holder_not_client",
    "without_judgment": "authority_evidence_required", "explanation_501": "bad_attestation",
    "explanation_blank": "holder_not_client", "without_measure": "protected_adult_without_measure",
    "own_user_confirms": "court_appointed", "explanation_kept": null, "lifted": [], "explained": "ok",
    "explanation": "RIB au nom du gérant, majeur protégé ; tuteur : UDAF (test)"}'::jsonb,
  'p ([critic] L2, [check 1] gap 10; C. civ. 427 al. 5; founder Q21): after a tutelle the tutor''s own account is '
  'refused holder_not_client, an account without the judgment authority_evidence_required, an explanation of 501 '
  'characters refused and a blank one is none; a client with no measure has no protected adult''s account; the '
  'account in the client''s name with the judgment, confirmed by a second admin (never the client''s user), lifts the '
  'block; a holder spelt otherwise passes only with its explanation, kept for the confirming admin');

-- after a curatelle: payouts blocked (our rule, OQ-94), not the portfolio confirmation gate (2003 names the tutelle)
create or replace function pg_temp.sp3() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb;
begin
  perform pg_temp.confirmed_ago('a3');
  perform pg_temp.evt('a3', 'curatorship', d - 5);
  w := jsonb_build_object(
    'blocked', pg_temp.blk('a3'),
    'confirmation_gate', (select coalesce(bool_or(b like 'client_mandate_ended%' or b like 'client_deceased%'), false)
                          from unnest(private.portfolio_confirmation_blockers(pg_temp.pf('a3'), d)) b),
    'own_users', private.payout_court_appointed('client', pg_temp.c('a3')),
    'end', (select count(*) from private.client_end_event(pg_temp.c('a3'), d)));
  perform pg_temp.payee('p3-a', 'a3', pg_temp.ib('F'), 'CYPRES SA', 'protected_adult');
  return w || jsonb_build_object('lifted', pg_temp.blk('a3'));
end $$;
select is(pg_temp.iso('sp3'),
  '{"blocked": ["client_status:curatorship"], "confirmation_gate": false, "own_users": true, "end": 0,
    "lifted": []}'::jsonb,
  'p: a curatorship blocks payouts (règle du cabinet) but not the portfolio confirmation and ends no mandate; the '
  'client''s own users act on no account; an account in its name with the judgment confirmed by a second admin lifts '
  'it');

-- after a mandate end: the client's account confirmed again by a second admin
create or replace function pg_temp.sp4() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb;
begin
  perform pg_temp.confirmed_ago('a4');
  perform pg_temp.evt('a4', 'mandate_ended', d - 2);
  w := jsonb_build_object('old_account', pg_temp.blk('a4'));
  perform pg_temp.payee('p4-a', 'a4', pg_temp.ib('G'), 'LAMBERT SA', 'client', false);
  return w || jsonb_build_object('reconfirmed', pg_temp.blk('a4'));
end $$;
select is(pg_temp.iso('sp4'), '{"old_account": ["client_status:mandate_ended"], "reconfirmed": []}'::jsonb,
  'p: after a mandate end the account confirmed before it blocks; the client''s account confirmed again after it by a '
  'second admin lifts it');

-- [critic] F16: every event, the strictest payee: a tutelle then a mandate end
create or replace function pg_temp.sp5() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb; acc uuid;
begin
  perform pg_temp.confirmed_ago('a8');
  perform pg_temp.evt('a8', 'guardianship', d - 10, '3 hours');
  acc := pg_temp.payee('p5-a', 'a8', pg_temp.ib('D'), 'PETIT SAS', 'protected_adult');
  perform pg_temp.confirmed_at(acc, now() - interval '150 minutes');
  perform pg_temp.evt('a8', 'mandate_ended', d - 5, '2 hours');
  w := jsonb_build_object('between_the_two', pg_temp.blk('a8'));
  perform pg_temp.payee('p5-b', 'a8', pg_temp.ib('E'), 'PETIT SAS', 'client', false);
  w := w || jsonb_build_object('client_reconfirmed', pg_temp.blk('a8'));
  perform pg_temp.payee('p5-c', 'a8', pg_temp.ib('H'), 'PETIT SAS', 'protected_adult');
  return w || jsonb_build_object('protected_after_both', pg_temp.blk('a8'));
end $$;
select is(pg_temp.iso('sp5'),
  '{"between_the_two": ["client_status:guardianship"], "client_reconfirmed": ["client_status:guardianship"],
    "protected_after_both": []}'::jsonb,
  'p ([critic] F16): a tutelle recorded, then a mandate end — a protected adult''s account confirmed between the two '
  'does not lift, the client''s own account confirmed after both does not either (the strictest payee); a protected '
  'adult''s account with the judgment confirmed after both does');
select is(pg_temp.iso('sp5', true), pg_temp.iso('sp5'), 'p (F16): the same with the switch on');

-- a liquidation requires the liquidator's account whatever else (L641-9 I), with the judgment naming it
create or replace function pg_temp.sp6() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb; acc uuid;
begin
  perform pg_temp.confirmed_ago('a6');
  perform pg_temp.evt('a6', 'liquidation', d - 5);
  w := jsonb_build_object('no_payee', pg_temp.blk('a6'),
    'without_judgment', pg_temp.code(pg_temp.propose('p6-a', 'a6', pg_temp.ib('I'), 'SELARL MJ SYNERGIE',
                                                     'court_appointed', false)));
  acc := pg_temp.payee('p6-b', 'a6', pg_temp.ib('I'), 'SELARL MJ SYNERGIE', 'court_appointed');
  w := w || jsonb_build_object('lifted', pg_temp.blk('a6'));
  perform pg_temp.confirmed_at(acc, now() - interval '90 minutes');   -- then a death recorded after it
  perform pg_temp.evt('a6', 'death', d - 1, '1 hour');
  w := w || jsonb_build_object('and_a_death', pg_temp.blk('a6'));
  perform pg_temp.payee('p6-c', 'a6', pg_temp.ib('J'), 'SCP LENOIR NOTAIRES', 'estate');
  w := w || jsonb_build_object('estate_instead', pg_temp.blk('a6'));
  -- a court-appointed account proposed before 7d-1 (no authority evidence) does not lift
  perform pg_temp.payee('p6-d', 'a6', pg_temp.ib('K'), 'SELARL MJ SYNERGIE', 'court_appointed');
  alter table public.client_payout_account disable trigger client_payout_account_guard;
  update public.client_payout_account set authority_document_id = null
  where client_organization_id = pg_temp.c('a6') and status = 'active';
  alter table public.client_payout_account enable always trigger client_payout_account_guard;
  return w || jsonb_build_object('without_its_evidence', pg_temp.blk('a6'));
end $$;
select is(pg_temp.iso('sp6'),
  '{"no_payee": ["client_status:liquidation"], "without_judgment": "authority_evidence_required", "lifted": [],
    "and_a_death": ["client_status:liquidation"], "estate_instead": ["client_status:liquidation"],
    "without_its_evidence": ["client_status:liquidation"]}'::jsonb,
  'p (L641-9 I): after a liquidation only the liquidator''s account, with the judgment naming it, confirmed after it '
  'by a second admin lifts the block; a death recorded later asks it confirmed again, and the estate''s account does '
  'not do instead; a court-appointed account without its authority evidence never lifts');

-- [critic] L14: a standing seizure blocks whatever the account; the client's own users act on no account meanwhile
create or replace function pg_temp.sp7() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb; s uuid;
begin
  perform pg_temp.confirmed_ago('a5');
  s := pg_temp.evt('a5', 'seizure', d - 3);
  w := jsonb_build_object('blocked', pg_temp.blk('a5'),
                          'own_users', private.payout_court_appointed('client', pg_temp.c('a5')));
  perform pg_temp.rec('p7-a', 'a5', 'seizure_released', d, p_refers => s);
  w := w || jsonb_build_object('released', pg_temp.blk('a5'),
                               'own_users_after', private.payout_court_appointed('client', pg_temp.c('a5')));
  perform pg_temp.evt('a5', 'death', d - 2, '1 hour');
  perform pg_temp.payee('p7-b', 'a5', pg_temp.ib('L'), 'SCP LENOIR NOTAIRES', 'estate');
  w := w || jsonb_build_object('estate', pg_temp.blk('a5'));
  perform pg_temp.evt('a5', 'seizure', d - 1, '30 minutes');
  return w || jsonb_build_object('seized_again', pg_temp.blk('a5'));
end $$;
select is(pg_temp.iso('sp7'),
  '{"blocked": ["client_status:seizure"], "own_users": true, "released": [], "own_users_after": false, "estate": [],
    "seized_again": ["client_status:seizure"]}'::jsonb,
  'p ([critic] L14; CPCE L211-2, C. civ. 1347-7): a standing seizure blocks the payout whatever the account and keeps '
  'the client''s users from its accounts; released, nothing; seized again while the estate''s account satisfies the '
  'death, blocked again');
select is(pg_temp.iso('sp7', true), pg_temp.iso('sp7'), 'p (L14): the same with the switch on');

-- the approval reads the blockers (an N > 0 run under a seizure); a payout of a run approved before a death is held at
-- the file's generation
create or replace function pg_temp.sp8() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); v uuid; v2 uuid;
begin
  perform pg_temp.pending('a5', 'c4', 100000);
  perform pg_temp.evt('a5', 'seizure', d - 1);
  v := pg_temp.runk('a5', '{"c4": "100000"}', 0, 0, 'p8-1');
  perform pg_temp.pending('a2', 'c5', 100000);
  v2 := pg_temp.runk('a2', '{"c5": "100000"}', 0, 0, 'p8-2');
  perform pg_temp.evt('a2', 'death', d - 1, '1 minute');
  return jsonb_build_object(
    'approval', (select jsonb_build_array(r.status, r.last_failure ->> 'code') from public.remittance_run r
                 where r.id = v),
    'approved_before', (select r.status from public.remittance_run r where r.id = v2),
    'held', private.transfer_hold_reason(pg_temp.rtransfer(v2), d, d, null));
end $$;
select is(pg_temp.iso('sp8'),
  '{"approval": ["draft", "payout_blocked:client_status:seizure"], "approved_before": "approved",
    "held": "payout_blocked:client_status:death"}'::jsonb,
  'p: an approval under a seizure is refused payout_blocked:client_status:seizure (the draft stays); a payout approved '
  'before a death is held out of the file payout_blocked:client_status:death');
select is(pg_temp.iso('sp8', true), pg_temp.iso('sp8'), 'p: the same with the switch on');

-- (review round 1, MONEY-LAW-3, TUI-1) what 7d-1 does NOT bar yet, pinned so that the texts say it: an N = 0 run (every
-- collection set off) under a standing seizure is approved and its set-off posted — the blockers are read only for a
-- payout (N > 0). The bar « whatever N » is 7d-2's (plan §6.2.9; COMPLIANCE SAISIE-01: C. civ. 1347-7, CPCE L211-2);
-- until then the ops texts tell ops not to approve such a run (runs.ts, debits.ts)
create or replace function pg_temp.sp9() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); v uuid; w jsonb;
begin
  perform pg_temp.evt('a8', 'seizure', d - 2);
  perform pg_temp.pending('a8', '8b', 150000);
  v := pg_temp.request('a8', 'draft-run-8b');
  perform pg_temp.prepare_off(v, 'a8', '8b', 5, 6);
  w := jsonb_build_object('blockers', pg_temp.blk('a8'), 'approval', pg_temp.approve_plain(v, 'approve-run-8b'));
  return w || jsonb_build_object(
    'run', (select jsonb_build_array(r.status, r.net_minor, r.settlement_minor) from public.remittance_run r
            where r.id = v),
    'settled', (select jsonb_agg(jsonb_build_array(s.kind, s.amount_minor)) from public.commission_settlement s
                where s.run_id = v));
end $$;
-- (M2c-7d-2, house rule R3, ADR-0014 « M2c-7d-2 ») plan §6.2.9 [critic] L14 (carried from 7d-1): a standing seizure
-- refuses the run whatever N — this N = 0 run goes back to draft payout_blocked:client_status:seizure and sets nothing
-- off (7d-1 shipped it booked with its 150 000 set-off: the pin 7d-2 was to change)
select is(pg_temp.iso('sp9'),
  '{"blockers": ["client_status:seizure"], "approval": "back_to_draft:draft", "run": ["draft", 0, 150000],
    "settled": null}'::jsonb,
  'p (review round 1, MONEY-LAW-3, TUI-1; M2c-7d-2, R3): an N = 0 run under a standing seizure is refused whatever N '
  '(plan §6.2.9) — nothing set off');
select is(pg_temp.iso('sp9', true), pg_temp.iso('sp9'), 'p (MONEY-LAW-3): the same with the switch on');

-- (review round 1, TUI-4, plan §6.2.7 « estate > protected_adult ») a death and a tutelle: the estate's account, not a
-- protected adult's
create or replace function pg_temp.sp10() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb;
begin
  perform pg_temp.confirmed_ago('a8');
  perform pg_temp.evt('a8', 'guardianship', d - 10, '3 hours');
  perform pg_temp.evt('a8', 'death', d - 2, '2 hours');
  w := jsonb_build_object(
    'payee', (select jsonb_build_array(r.kind, r.event_kind) from private.client_payee_rule(pg_temp.c('a8'), d) r));
  perform pg_temp.payee('p10-a', 'a8', pg_temp.ib('D'), 'PETIT SAS', 'protected_adult');
  w := w || jsonb_build_object('protected_adult', pg_temp.blk('a8'));
  perform pg_temp.payee('p10-b', 'a8', pg_temp.ib('E'), 'SCP LENOIR NOTAIRES', 'estate');
  return w || jsonb_build_object('estate', pg_temp.blk('a8'));
end $$;
select is(pg_temp.iso('sp10'),
  '{"payee": ["estate", "death"], "protected_adult": ["client_status:death"], "estate": []}'::jsonb,
  'p (review round 1, TUI-4; plan §6.2.7): a tutelle then a death require the estate''s account (estate > '
  'protected_adult): a protected adult''s account confirmed after both does not lift the block, the estate''s does');

-- (review round 1, TUI-4; plan §6.6 « by the client's own user (refused) » for every kind) after a mandate end the
-- client's own users confirm and refuse no account; a second admin does
create or replace function pg_temp.sp11() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); r jsonb;
begin
  perform pg_temp.evt('a2', 'mandate_ended', d - 2);
  r := pg_temp.propose('p11-a', 'a2', pg_temp.ib('F'), 'LILAS FINANCE', 'client', false);
  return jsonb_build_object(
    'own_users', private.payout_court_appointed('client', pg_temp.c('a2')),
    'own_user_confirms', pg_temp.code(pg_temp.confirm('p11-b', pg_temp.pid(r), '08')),
    'own_user_rejects', pg_temp.try('08', format(
                          'select public.reject_payout_account(''rej-046a-p11'', %L, ''non'')', pg_temp.pid(r))),
    'second_admin', pg_temp.code(pg_temp.confirm('p11-c', pg_temp.pid(r))));
end $$;
select is(pg_temp.iso('sp11'),
  '{"own_users": true, "own_user_confirms": "court_appointed",
    "own_user_rejects": "payout account refused: court_appointed", "second_admin": "ok"}'::jsonb,
  'p (review round 1, TUI-4): after a mandate end the client''s own administrator neither confirms nor refuses its '
  'account (refused court_appointed); a second admin of the servicer confirms it');


-- k. ([check 1] gap 10, [check 2] gap 4) epc_name_key: the name as the pain.001 writer spells it ----------------------
select is(array[private.epc_name_key('Bœuf SARL'), private.epc_name_key('BOEUF SARL'), private.epc_name_key('Æther'),
                private.epc_name_key('Straße'), private.epc_name_key('Þór'), private.epc_name_key('Œuvre d''Élan'),
                private.epc_name_key('OEUVRE D ELAN'), private.epc_name_key('Bœuf d''Élan – SARL'),
                private.epc_name_key('Jean-Luc Dupont'), private.epc_name_key('JEAN LUC DUPONT'),
                private.epc_name_key('Société Martin'), private.epc_name_key('SOCIETE  MARTIN'),
                private.epc_name_key('  l’Atelier  Øst  ')],
  array['BOEUF SARL', 'BOEUF SARL', 'AETHER', 'STRASSE', 'THOR', 'OEUVRE D ELAN', 'OEUVRE D ELAN', 'BOEUF D ELAN SARL',
        'JEAN LUC DUPONT', 'JEAN LUC DUPONT', 'SOCIETE MARTIN', 'SOCIETE MARTIN', 'L ATELIER OST'],
  'k ([check 2] gap 4): epc_name_key spells as the writer does (œ→oe, æ→ae, ß→ss, þ→th, the apostrophes and dashes), '
  'drops the accents, upper-cases and collapses every run of other characters to one space');
select is(array[private.epc_name_key('Пётр Иванов') is null, private.epc_name_key('Jean' || chr(847) || 'Dupont') is null,
                private.epc_name_key('Ζωή') is null, private.epc_name_key('---') is null,
                private.epc_name_key('M. Jean Dupont') = private.epc_name_key('Jean Dupont'),
                private.epc_name_key('Dupont Jean') = private.epc_name_key('Jean Dupont')],
  array[true, true, true, true, false, false],
  'k: a name with a character left outside Basic Latin (Cyrillic, Greek, U+034F) has no key (never a false match), '
  'nor a name of no letter or digit; a title or another word order is another key');
create or replace function pg_temp.sk1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb := '[]'; x record; r jsonb; i integer := 0;
begin
  perform pg_temp.evt('a8', 'guardianship', d - 5);
  for x in select * from (values ('Société Martin', 'SOCIETE  MARTIN', null), ('Jean-Luc Dupont', 'JEAN LUC DUPONT', null),
                                 ('Œuvre d''Élan', 'OEUVRE D ELAN', null), ('Bœuf SARL', 'BOEUF SARL', null),
                                 ('Jean Dupont', 'M. Jean Dupont', null), ('Jean Dupont', 'Dupont Jean', null),
                                 ('Пётр Иванов', 'PETR IVANOV', null),
                                 ('Пётр Иванов', 'PETR IVANOV', 'RIB en caractères latins (test)'))
                  v (legal_name, holder, att) loop
    i := i + 1;
    begin
      update public.organization set legal_name = x.legal_name where id = pg_temp.c('a8');
      r := pg_temp.propose('k-' || i, 'a8', pg_temp.ib('M'), x.holder, 'protected_adult', true, x.att);
      w := w || to_jsonb(pg_temp.code(r));
      raise exception 'proposal rolled back' using errcode = 'TR005';
    exception when sqlstate 'TR005' then
      null;
    end;
  end loop;
  return w;
end $$;
select is(pg_temp.iso('sk1'),
  '["ok", "ok", "ok", "ok", "holder_not_client", "holder_not_client", "holder_not_client", "ok"]'::jsonb,
  'k ([check 1] gap 10): a protected adult''s account is accepted without explanation when the two keys are equal '
  '(« Société Martin » / « SOCIETE  MARTIN », « Jean-Luc Dupont » / « JEAN LUC DUPONT », « Œuvre d''Élan » / « OEUVRE '
  'D ELAN », « Bœuf SARL » / « BOEUF SARL »); a title, another word order or a Cyrillic name (no key) are refused '
  'holder_not_client, accepted with an explanation');


-- g. (§6.2.8) After a mandate-ending event, payments are held for ops -------------------------------------------------
create or replace function pg_temp.sg1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb;
begin
  perform pg_temp.evt('a4', 'mandate_ended', d - 5);
  perform pg_temp.evt('a2', 'death', d - 5);
  perform pg_temp.evt('a8', 'guardianship', d - 5);
  perform pg_temp.old_tutelle('a7', d - 5);
  perform pg_temp.evt('a3', 'curatorship', d - 5);
  w := jsonb_build_object(
    'after_the_end', pg_temp.match('a4', 'b1', 50000, d - 3),
    'on_its_day', pg_temp.match('a4', 'b2', 40000, d - 5),
    'before_it', pg_temp.match('a4', 'b3', 30000, d - 7),
    'after_a_death', pg_temp.match('a2', 'b4', 30000, d - 3),
    'after_a_tutelle', pg_temp.match('a8', 'b5', 30000, d - 3),
    'old_row_to_qualify', pg_temp.match('a7', 'b6', 30000, d - 3),
    'curatelle', pg_temp.match('a3', 'b7', 30000, d - 3));
  perform private.regate_account(pg_temp.f('b1'));
  return w || jsonb_build_object(
    'regated', (select p.review_reason from public.payment p where p.id = pg_temp.pay('b1')),
    'allocation_queued', (select count(*) from public.payment p where p.id = pg_temp.pay('b1')
                            and p.status = 'matched' and p.review_reason is null));
end $$;
select is(pg_temp.iso('sg1'),
  '{"after_the_end": "client_mandate_ended", "on_its_day": "client_mandate_ended", "before_it": "ready",
    "after_a_death": "client_mandate_ended", "after_a_tutelle": "client_mandate_ended", "old_row_to_qualify": "ready",
    "curatelle": "ready", "regated": "client_mandate_ended", "allocation_queued": 0}'::jsonb,
  'g (§6.2.8; R124-3; founder Q10): a payment of a file of a client whose mandate ended (an end, a death, a tutelle) '
  'on or before its booking date is held client_mandate_ended, never allocated, also after a regate; one booked '
  'before is not; an old row still to qualify and a curatelle end no mandate');
select is(pg_temp.iso('sg1', true), pg_temp.iso('sg1'), 'g: the same with the switch on');

create or replace function pg_temp.sg2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); r jsonb; r2 jsonb; w jsonb;
begin
  perform pg_temp.evt('a4', 'mandate_ended', d - 5);
  perform pg_temp.match('a4', 'b1', 50000, d - 3);
  r := pg_temp.fwd('g2-1', 'b1');
  w := jsonb_build_object(
    'forwarded', pg_temp.code(r),
    'notified', (select n.reason from public.client_notification n
                 where n.payment_id = pg_temp.pay('b1') and n.kind = 'payment_forwarded'),
    'entry', (select jsonb_build_array(e.entry_type, e.reason) from public.ledger_entry e
              where e.id = (r ->> 'entry_id')::uuid),
    'payment', (select p.status || ':' || coalesce(p.review_reason, '') from public.payment p
                where p.id = pg_temp.pay('b1')));
  -- held for the cut-off before the end was recorded, forwarded after: its reason is the end's
  perform pg_temp.match('a1', 'b2', 40000, d - 3);
  update public.payment set review_reason = 'before_servicing_start' where id = pg_temp.pay('b2');
  perform pg_temp.evt('a1', 'mandate_ended', d - 4);
  r2 := pg_temp.fwd('g2-2', 'b2');
  -- a payment ready for allocation is not forwarded
  perform pg_temp.match('a3', 'b3', 30000, d - 3);
  -- (review round 1, TUI-8) a payment after the end on a file the client recalled since: the end's reason, not the
  -- recall's (which a schedule may price)
  perform pg_temp.match('a4', 'b4', 20000, d - 2);
  update public.account set status = 'closed_recalled' where id = pg_temp.f('b4');
  perform pg_temp.fwd('g2-4', 'b4');
  return w || jsonb_build_object(
    'recalled_file', (select n.reason from public.client_notification n
                      where n.payment_id = pg_temp.pay('b4') and n.kind = 'payment_forwarded'),
    'cut_off_then_end', (select n.reason from public.client_notification n
                         where n.payment_id = pg_temp.pay('b2') and n.kind = 'payment_forwarded'),
    'ready', pg_temp.code(pg_temp.fwd('g2-3', 'b3')) like 'a payment on a file is forwarded only%');
end $$;
select is(pg_temp.iso('sg2'),
  '{"forwarded": "ok", "notified": "mandate_ended",
    "entry": ["forward", "Reversement sans imputation : paiement reçu après la fin du mandat"], "payment": "allocated:",
    "recalled_file": "mandate_ended", "cut_off_then_end": "mandate_ended", "ready": true}'::jsonb,
  'g (founder Q10): « Reverser au client » takes a payment held client_mandate_ended (a forward with the reason '
  'mandate_ended, the client told « … reçu après la fin du mandat », no schedule key: no commission); a payment held '
  'for the cut-off and booked after an end recorded since is forwarded with the end''s reason, as one on a file the '
  'client recalled since; a payment ready for allocation is not forwarded');


-- a. ([critic] L12, [check 1] gap 7) Who receives the letters --------------------------------------------------------
create or replace function pg_temp.sa1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); w jsonb; e uuid;
begin
  w := jsonb_build_object('plain', pg_temp.addr('a9'),
                          'plain_lines', (select to_jsonb(x.address_lines)
                                          from private.client_addressee(pg_temp.c('a9'), d) x));
  e := pg_temp.evt('a2', 'death', d - 3);
  w := w || jsonb_build_object('death_unknown', pg_temp.addr('a2'));
  perform pg_temp.rep('a1-1', e, pg_temp.person('notary'));
  w := w || jsonb_build_object('death', pg_temp.addr('a2'));
  e := pg_temp.evt('a8', 'guardianship', d - 3);
  w := w || jsonb_build_object('tutelle_unknown', pg_temp.addr('a8'));
  perform pg_temp.rep('a1-2', e, pg_temp.person('tutor'));
  w := w || jsonb_build_object('tutelle', pg_temp.addr('a8'));
  e := pg_temp.evt('a3', 'curatorship', d - 3);
  w := w || jsonb_build_object('curatelle_unknown', pg_temp.addr('a3'));
  perform pg_temp.rep('a1-3', e, pg_temp.person('curator'));
  w := w || jsonb_build_object('curatelle', pg_temp.addr('a3'),
                               'curator_lines', (select to_jsonb(x.address_lines)
                                                 from private.client_addressee(pg_temp.c('a3'), d) x where x.copy));
  e := pg_temp.evt('a6', 'liquidation', d - 3);
  perform pg_temp.rep('a1-4', e, pg_temp.person('liquidator'));
  w := w || jsonb_build_object('liquidation', pg_temp.addr('a6'));
  perform pg_temp.old_tutelle('a7', d - 3);
  perform pg_temp.evt('a4', 'mandate_ended', d - 3);
  perform pg_temp.evt('a5', 'proceeding_opened', d - 3);
  return w || jsonb_build_object('to_qualify', pg_temp.addr('a7'), 'mandate_ended', pg_temp.addr('a4'),
                                 'proceeding', pg_temp.addr('a5'));
end $$;
select is(pg_temp.iso('sa1'),
  '{"plain": [["client", "Moreau SA", false]], "plain_lines": ["1 rue de la Paix", "75002 Paris"],
    "death_unknown": [], "death": [["notary", "Me Claire Lenoir, notaire", false]], "tutelle_unknown": [],
    "tutelle": [["tutor", "UDAF du Rhône", false]], "curatelle_unknown": [],
    "curatelle": [["client", "Cyprès SA", false], ["curator", "Association Tutélaire de Lyon", true]],
    "curator_lines": ["3 place du Palais", "69002 Lyon"], "liquidation": [["liquidator", "SELARL MJ Synergie", false]],
    "to_qualify": [], "mandate_ended": [["client", "Lambert SA", false]],
    "proceeding": [["client", "Roux SA", false]]}'::jsonb,
  'a ([critic] L12, [check 1] gap 7; C. civ. 473 al. 1, 440 al. 1, 467 al. 3 by analogy — OQ-94): the client at its '
  'billing address; after a death the notary (none while unknown), after a tutelle the tutor alone, after a curatelle '
  'the client and its curator in copy, after a liquidation the liquidator (L641-9 I); an old row still to qualify: '
  'none; a mandate end or a proceeding: the client');
select is(pg_temp.iso('sa1', true), pg_temp.iso('sa1'), 'a: the same with the switch on');

-- the repayment request's recipient (7c-2's recipient_unknown narrowed) and the payload's addressees
create or replace function pg_temp.sa2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); a public.client_advance; e uuid; r jsonb;
begin
  a := pg_temp.adv('a9', '9c', 30000, '9c0');
  e := pg_temp.evt('a9', 'guardianship', d - 1);
  r := jsonb_build_object('tutelle_unknown', pg_temp.why_not(pg_temp.dra('a2-1', 'a9', array[a.id])));
  perform pg_temp.rep('a2-r', e, pg_temp.person('tutor'));
  r := r || jsonb_build_object('request', pg_temp.dra('a2-2', 'a9', array[a.id]));
  return jsonb_build_object('tutelle_unknown', r -> 'tutelle_unknown', 'made', pg_temp.why_not(r -> 'request'),
                            'recipient', (pg_temp.rq(r -> 'request')).payload -> 'recipient',
                            'copies', (pg_temp.rq(r -> 'request')).payload -> 'copies');
end $$;
select is(pg_temp.iso('sa2'),
  '{"tutelle_unknown": "recipient_unknown", "made": "ok",
    "recipient": {"role": "tutor", "name": "UDAF du Rhône", "address_lines": ["3 place du Palais", "69002 Lyon"],
                  "client_name": "Moreau SA"}, "copies": null}'::jsonb,
  'a ([critic] L12): a repayment request after a tutelle with no tutor recorded → recipient_unknown; with the tutor '
  'recorded the letter is addressed to the tutor, for the client');
create or replace function pg_temp.sa3() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); a public.client_advance; e uuid; u text; r jsonb;
begin
  a := pg_temp.adv('a9', '9d', 30000, '9d0');
  e := pg_temp.evt('a9', 'curatorship', d - 1);
  u := pg_temp.why_not(pg_temp.dra('a3-1', 'a9', array[a.id]));
  perform pg_temp.rep('a3-r', e, pg_temp.person('curator'));
  r := pg_temp.dra('a3-2', 'a9', array[a.id]);
  return jsonb_build_object('curator_unknown', u, 'made', pg_temp.why_not(r),
                            'recipient', (pg_temp.rq(r)).payload -> 'recipient',
                            'copies', (pg_temp.rq(r)).payload -> 'copies');
end $$;
select is(pg_temp.iso('sa3'),
  '{"curator_unknown": "recipient_unknown", "made": "ok",
    "recipient": {"name": "Moreau SA", "address": {"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris",
                                                   "country": "FR"}},
    "copies": [{"role": "curator", "name": "Association Tutélaire de Lyon",
                "address_lines": ["3 place du Palais", "69002 Lyon"]}]}'::jsonb,
  'a ([check 1] gap 7): after a curatelle with no curator recorded → recipient_unknown; with the curator recorded the '
  'letter is addressed to the client (its billing address, as before) with a copy to the curator');
create or replace function pg_temp.sa4() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); a public.client_advance; r jsonb; u text; e uuid;
begin
  a := pg_temp.adv('a9', '9e', 30000, '9e0');
  begin
    e := pg_temp.evt('a9', 'death', d - 1);
    u := pg_temp.why_not(pg_temp.dra('a4-1', 'a9', array[a.id]));
    raise exception 'death rolled back' using errcode = 'TR004';
  exception when sqlstate 'TR004' then
    null;
  end;
  perform pg_temp.evt('a9', 'mandate_ended', d - 1);
  r := pg_temp.dra('a4-2', 'a9', array[a.id]);
  return jsonb_build_object('death_unknown', u, 'after_a_mandate_end', pg_temp.why_not(r),
                            'recipient', (pg_temp.rq(r)).payload -> 'recipient' ->> 'name',
                            'copies', (pg_temp.rq(r)).payload ? 'copies');
end $$;
select is(pg_temp.iso('sa4'),
  '{"death_unknown": "recipient_unknown", "after_a_mandate_end": "ok", "recipient": "Moreau SA", "copies": false}'::jsonb,
  'a: after a death with no notary or heirs recorded → recipient_unknown; after a mandate end (7c-2 refused it) the '
  'request is made and addressed to the client');
-- (review round 1, TUI-4) the governing event's order: a death before a tutelle (the notary, not the tutor), a
-- liquidation before a death (the liquidator)
create or replace function pg_temp.sa5() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); e uuid;
begin
  e := pg_temp.evt('a8', 'guardianship', d - 10);
  perform pg_temp.rep('a5-t', e, pg_temp.person('tutor'));
  e := pg_temp.evt('a8', 'death', d - 2);
  perform pg_temp.rep('a5-n', e, pg_temp.person('notary'));
  e := pg_temp.evt('a6', 'death', d - 10);
  perform pg_temp.rep('a5-h', e, pg_temp.person('heirs'));
  e := pg_temp.evt('a6', 'liquidation', d - 2);
  perform pg_temp.rep('a5-l', e, pg_temp.person('liquidator'));
  return jsonb_build_object('tutelle_then_death', pg_temp.addr('a8'), 'death_then_liquidation', pg_temp.addr('a6'));
end $$;
select is(pg_temp.iso('sa5'),
  '{"tutelle_then_death": [["notary", "Me Claire Lenoir, notaire", false]],
    "death_then_liquidation": [["liquidator", "SELARL MJ Synergie", false]]}'::jsonb,
  'a (review round 1, TUI-4): a tutelle then a death — the notary receives the letters, not the tutor; a death then a '
  'liquidation — the liquidator (L641-9 I), not the heirs');


-- n. The full list of codes run_advance_checks emits (043 #33, 044 h, 045 x, 045b x; [critic] F12) ------------------
create or replace function pg_temp.sn() returns jsonb language plpgsql as $$
declare a public.client_advance; m public.client_advance; c uuid; r jsonb;
begin
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
  -- 7d-1's: an old « Tutelle ou curatelle » row, a standing seizure
  perform pg_temp.old_tutelle('a7', private.paris_today() - 3);
  perform pg_temp.evt('a5', 'seizure', private.paris_today() - 1);
  c := pg_temp.adv_run(private.paris_today() + 31, true);
  return (select jsonb_agg(distinct x.code order by x.code) from public.payment_check_result x where x.run_id = c);
end $$;
select is(pg_temp.iso('sn'),
  '["advance_ledger", "advance_open", "client_credit_ledger", "client_credit_owed", "protection_event_to_qualify",
    "remitted_reversal_uncovered", "repayment_request_document_missing", "seizure_standing",
    "written_off_recovery_ledger"]'::jsonb,
  'n (F12): run_advance_checks emits exactly advance_ledger, advance_open, client_credit_ledger, client_credit_owed, '
  'protection_event_to_qualify, remitted_reversal_uncovered, repayment_request_document_missing, seizure_standing, '
  'written_off_recovery_ledger (later slices extend this list)');


-- c. (review round 1) What a check costs, and the commands' settings -----------------------------------------------
-- (CC-1) the payout's blockers call the payee rule and the seizures' read only for a client with events (a seizure for
-- the latter): per payout at the file's generation and download, the client without events pays neither
create or replace function pg_temp.sc1() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); v jsonb := '{}';
begin
  set local track_functions = 'all';
  create temp table _calls (k text, n bigint) on commit drop;
  insert into _calls select f.funcname, f.calls from pg_stat_xact_user_functions f
                     where f.schemaname = 'private' and f.funcname in ('client_payee_rule', 'client_seizures_standing');
  perform pg_temp.blk('a9');
  v := v || jsonb_build_object('plain', (
    select jsonb_object_agg(f.funcname, f.calls - coalesce((select c.n from _calls c where c.k = f.funcname), 0))
    from pg_stat_xact_user_functions f
    where f.schemaname = 'private' and f.funcname in ('client_payee_rule', 'client_seizures_standing')));
  delete from _calls;
  perform pg_temp.evt('a8', 'death', d - 2);
  insert into _calls select f.funcname, f.calls from pg_stat_xact_user_functions f
                     where f.schemaname = 'private' and f.funcname in ('client_payee_rule', 'client_seizures_standing');
  perform pg_temp.blk('a8');
  v := v || jsonb_build_object('with_a_death', (
    select jsonb_object_agg(f.funcname, f.calls - coalesce((select c.n from _calls c where c.k = f.funcname), 0))
    from pg_stat_xact_user_functions f
    where f.schemaname = 'private' and f.funcname in ('client_payee_rule', 'client_seizures_standing')));
  return v || jsonb_build_object('blockers', jsonb_build_array(pg_temp.blk('a9'), pg_temp.blk('a8')));
end $$;
select is((select jsonb_build_object(
             'plain', jsonb_build_array(coalesce((v -> 'plain' ->> 'client_payee_rule')::int, 0),
                                        coalesce((v -> 'plain' ->> 'client_seizures_standing')::int, 0)),
             'with_a_death', jsonb_build_array(coalesce((v -> 'with_a_death' ->> 'client_payee_rule')::int, 0),
                                               coalesce((v -> 'with_a_death' ->> 'client_seizures_standing')::int, 0)),
             'blockers', v -> 'blockers')
           from (select pg_temp.iso('sc1') v) x),
  '{"plain": [0, 0], "with_a_death": [1, 0], "blockers": [[], ["client_status:death"]]}'::jsonb,
  'c (review round 1, CC-1): a client with no event has its blockers read without the payee rule or the seizures'' '
  'read (one keyed probe of its events each); with a death, the payee rule once and no seizure read');
-- (CC-2) an event is stamped once its command holds the payout_accounts: lock (clock_timestamp, not the transaction's
-- start), so a confirmation that took the lock first is before it; the curatelle a qualification records too
create or replace function pg_temp.sc2() returns jsonb language plpgsql as $$
declare d date := private.paris_today(); r jsonb; o uuid; q jsonb;
begin
  r := pg_temp.rec('c2-1', 'a4', 'mandate_ended', d - 1);
  o := pg_temp.old_tutelle('a9', d - 5);
  q := pg_temp.qual('c2-2', o, 'curatorship');
  return jsonb_build_object(
    'event_after_the_transaction_start', (select e.recorded_at > now() from public.client_status_event e
                                          where e.id = pg_temp.eid(r)),
    'curatelle_after_the_transaction_start', (select e.recorded_at > now() from public.client_status_event e
                                              where e.id = (q ->> 'curatorship_event_id')::uuid));
end $$;
select is(pg_temp.iso('sc2'),
  '{"event_after_the_transaction_start": true, "curatelle_after_the_transaction_start": true}'::jsonb,
  'c (review round 1, CC-2): « Enregistrer un événement » and « Préciser » stamp the event when it is inserted, under '
  'the payout_accounts: lock, not at their transaction''s start');
-- (CC-3, CC-4) the commands that take the payout_accounts: lock wait 2 s at most (lock_timeout, as propose, confirm and
-- reject); the allocation job's end read (private.client_end_event, through client_event_effective) runs as the
-- worker's service role
select is((select jsonb_object_agg(p.proname, coalesce('lock_timeout=2s' = any (p.proconfig), false))
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname in ('record_client_status_event', 'set_client_representative', 'qualify_protection_event'))
          || jsonb_build_object(
               'client_end_event', has_function_privilege('service_role', 'private.client_end_event(uuid, date)',
                                                          'execute'),
               'client_event_effective', has_function_privilege('service_role',
                                                                'private.client_event_effective(uuid)', 'execute'),
               'not_authenticated', not has_function_privilege('authenticated', 'private.client_end_event(uuid, date)',
                                                               'execute')),
  '{"record_client_status_event": true, "set_client_representative": true, "qualify_protection_event": true,
    "client_end_event": true, "client_event_effective": true, "not_authenticated": true}'::jsonb,
  'c (review round 1, CC-3, CC-4): lock_timeout 2s on the three commands; the end read executable by service_role '
  '(the allocation job), never by authenticated');


-- The switch is still off (no M2c-7 migration writes it) --------------------------------------------------------------
select is(private.switch_on('downloaded_file_cancellation'), false,
  'the cancellation-after-download switch is still off');

select * from finish();
rollback;
