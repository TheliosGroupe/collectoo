-- M2c-2 (CPCE-03, M2-13 data): identities and terms. Billing identities (servicer and clients) and the servicer's
-- billing settings; client documents (the RIB, the signed mandate, the evidence of an event); payout accounts confirmed
-- by a second person (founder #10: the client's administrator at aal2, or another admin of the servicer) and their
-- IBANs read as the client's at import; client status events; the money terms of a mandate (commission-1,
-- remittance-1, R124-3 2°–4°: validators, immutability once in force, restrict, set_mandate_terms with compare and set);
-- the confirmation gate (§9.1, founder #13); the receipt issuer block (R123-237/238). RLS for clients A/B, restricted
-- client users (OQ-48), collectors and another servicer. Design docs/design/m2c-remittances.md §6, §8, §9.1, §10, §14.2,
-- §16, §17, §21; ADR-0014 (M2c-2).
begin;
select plan(201);

-- Fixtures --------------------------------------------------------------------------------------
-- Synthetic SIRENs (Luhn) and their VAT numbers (collectoo_worker.synth.ids); synthetic IBANs.
insert into public.organization (id, kind, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo', '849678297'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Autre cabinet', '594097214');
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Martin SAS', '825944093'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Lilas', '190190223'),
  ('00000000-0000-0000-0000-0000000000a3', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Sans identité', null),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Bleu SARL', '438120669');
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@terms.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000bb', 'admin'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-0000000000a2', 'client_admin'),
  ('10000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-0000000000b1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-0000000000a1', 'client_viewer');  -- whole client
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on) values
  ('70000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
   'MAND-A1', 'mandate_amicable', '2026-01-15'),
  ('70000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
   'MAND-A2', 'mandate_amicable', '2026-01-15'),
  ('70000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a3',
   'MAND-A3', 'mandate_amicable', '2026-01-15'),
  ('70000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000b1',
   'MAND-B1', 'mandate_amicable', '2026-01-15');
insert into public.portfolio (id, organization_id, client_organization_id, name, mandate_id) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
   'P1', '70000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
   'P2', '70000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
   'P3', '70000000-0000-0000-0000-000000000002'),
  ('20000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a3',
   'P4', '70000000-0000-0000-0000-000000000003'),
  ('20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000b1',
   'PB', '70000000-0000-0000-0000-000000000009');
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a1'),   -- a viewer of P1 only
  ('10000000-0000-0000-0000-000000000008', '20000000-0000-0000-0000-0000000000a1');   -- an administrator of P1 only
insert into public.bank_account (id, organization_id, purpose, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000cf', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
   'FR7697872919606945315603659', 'EUR', 'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000a0', '00000000-0000-0000-0000-0000000000aa', 'own',
   'FR7623754538827637495136203', 'EUR', 'Compte propre', null, '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000b0', '00000000-0000-0000-0000-0000000000bb', 'own',
   'FR7625006153088170839583250', 'EUR', 'Compte propre B', null, '2026-01-01');
-- client documents of a1 (two RIBs, the liquidator's, its signed mandate, an evidence), a2 (mandate, RIB, an
-- evidence), b1 (RIB)
create or replace function pg_temp.d(p_n text) returns uuid language sql as $$
  select ('d0000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.key(p_client text, p_doc uuid) returns text language sql as $$
  select 'client/' || case p_client when 'b1' then '00000000-0000-0000-0000-0000000000bb'
                                    else '00000000-0000-0000-0000-0000000000aa' end
         || '/00000000-0000-0000-0000-0000000000' || p_client || '/' || p_doc || '.pdf';
$$;
insert into public.document (id, organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                             mime_type, file_name)
select pg_temp.d(n), case c when 'b1' then '00000000-0000-0000-0000-0000000000bb'
                            else '00000000-0000-0000-0000-0000000000aa' end::uuid,
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, k, 'documents', pg_temp.key(c, pg_temp.d(n)), repeat('a', 64),
       'application/pdf', k || '.pdf'
from (values ('01', 'a1', 'payout_rib'), ('02', 'a1', 'payout_rib'), ('03', 'a1', 'payout_rib'),
             ('04', 'a1', 'mandate_document'), ('05', 'a1', 'client_status_evidence'), ('06', 'a2', 'mandate_document'),
             ('07', 'a2', 'payout_rib'), ('08', 'b1', 'payout_rib'), ('09', 'a2', 'client_status_evidence')) v (n, c, k);

-- The money terms of the §8.1 / §8.2 examples (clause references are columns of the version).
create temporary table j (k text primary key, v jsonb) on commit drop;
grant all on j to authenticated;
insert into j values
  ('schedule', '{"schema": "commission-1", "basis": {"families": "all", "forwards": {"file_recalled": false,
     "before_servicing_start": false, "client_ratification": false}, "on_reversal": "credit"},
     "rules": [{"id": "b2b", "tier_key": "b2b", "label_fr": "Factures entre professionnels",
                "match": {"claim_types": ["b2b_invoice"]}, "rate": {"kind": "flat", "rate": "0.1500"}},
               {"id": "autres", "tier_key": "autres", "label_fr": "Autres créances", "match": {},
                "rate": {"kind": "marginal", "tiers": [{"up_to_minor": "500000", "rate": "0.1000"},
                                                       {"up_to_minor": null, "rate": "0.0600"}]},
                "min_per_file_minor": "3000"}]}'),
  ('terms', '{"schema": "remittance-1", "frequency": "twice_monthly", "netting": {"clause_ref": "art. 7.2"},
     "clawback": {"clause_ref": "art. 7.4"}, "invoice_payment_days": 30, "holdback": []}'),
  ('office', '{"line1": "10 rue de la Bourse", "postcode": "75002", "city": "Paris", "country": "FR"}');
-- M1 (a1): its first version complete; M2 (a2): a version written before M2c-2 (a rate only); M3 (a3): complete terms
insert into public.mandate_terms (mandate_id, valid_from, commission_schedule, commission_clause_ref, remittance_terms,
                                  remittance_clause_ref, document_id)
values ('70000000-0000-0000-0000-000000000001', '2026-01-15', (select v from j where k = 'schedule'), 'art. 6',
        (select v from j where k = 'terms'), 'art. 7', pg_temp.d('04'));
insert into public.mandate_terms (mandate_id, valid_from, commission_rate)
values ('70000000-0000-0000-0000-000000000002', '2026-01-15', 0.15);
update public.mandate set insurance_clause_ref = 'art. 9 — Garantie' where id = '70000000-0000-0000-0000-000000000001';

create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
grant execute on all functions in schema pg_temp to authenticated;
create temporary table t (k text primary key, v uuid) on commit drop;
grant all on t to authenticated;

-- Pure helpers ------------------------------------------------------------------------------------
select is(array[private.postal_address_valid((select v from j where k = 'office')),
                private.postal_address_valid('{"line1": "1 rue X", "line2": null, "postcode": "1000", "city": "Bruxelles", "country": "BE"}'),
                private.postal_address_valid('{"line1": "1 rue X", "postcode": "7500", "city": "Paris", "country": "FR"}'),
                private.postal_address_valid('{"line1": "1 rue X", "postcode": "75002", "city": "Paris", "country": "fr"}'),
                private.postal_address_valid('{"line1": "1 rue X", "postcode": "75002", "city": "Paris", "country": "FR", "cedex": "1"}'),
                private.postal_address_valid('{"line1": " ", "postcode": "75002", "city": "Paris", "country": "FR"}'),
                private.postal_address_valid('"1 rue X"')],
  array[true, true, false, false, false, false, false],
  'a postal address: line, postcode (five digits in France), city, ISO country; nothing else');
select is(array[(private.establishment_of('{"postcode": "75002", "country": "FR"}') ->> 'mainland_france')::boolean,
                (private.establishment_of('{"postcode": "20000", "country": "FR"}') ->> 'mainland_france')::boolean,
                (private.establishment_of('{"postcode": "97100", "country": "FR"}') ->> 'mainland_france')::boolean,
                (private.establishment_of('{"postcode": "98000", "country": "MC"}') ->> 'mainland_france')::boolean,
                (private.establishment_of('{"postcode": "98800", "country": "FR"}') ->> 'mainland_france')::boolean,
                (private.establishment_of('{"postcode": "1000", "country": "BE"}') ->> 'mainland_france')::boolean],
  array[true, true, false, false, false, false],
  'mainland France from the registered office: Corsica is, overseas postcodes (97x, 98x) and other countries are not');
select is(array[private.fr_vat_number_valid('FR33849678297', '849678297'), private.fr_vat_number_valid('FR34849678297', '849678297'),
                private.fr_vat_number_valid('FR33849678297', '594097214'), private.fr_vat_number_valid('FR3384967829', '849678297')],
  array[true, false, false, false], 'a French VAT number: its key (12 + 3 × (SIREN mod 97)) mod 97 and its SIREN');
select is(array[private.legal_form_mention('SAS'), private.legal_form_mention('SA_DIRECTOIRE'), private.legal_form_mention('EI'),
                coalesce(private.legal_form_mention('OTHER'), '-')],
  array['SAS', 'société anonyme à directoire et conseil de surveillance', 'EI', '-'],
  'the legal form as R123-238 (and R123-237 9° for EI) print it');
select is(array[private.legal_form_states_capital('SAS'), private.legal_form_states_capital('SARL'),
                private.legal_form_states_capital('SNC'), private.legal_form_states_capital('EI')],
  array[true, true, false, false], 'the capital follows the name for SARL and sociétés par actions (R123-238 3°, 4° b)');

-- Billing identities ------------------------------------------------------------------------------
select pg_temp.as_user('04');
set local role authenticated;
select is(public.set_billing_identity('identity-aa-0001', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('legal_name', 'Collectoo', 'siren', '849678297', 'legal_form', 'SAS', 'share_capital_minor', '1000000',
                     'rcs_city', 'Paris', 'registered_office', (select v from j where k = 'office'),
                     'vat_number', 'FR 33 849678297', 'is_professional', true), null),
  '{"organization_id": "00000000-0000-0000-0000-0000000000aa", "version": 1, "gaps": []}'::jsonb,
  'an admin saves the servicer''s identity: complete (the VAT number typed with spaces)');
select is(public.set_billing_identity('identity-aa-0001', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('legal_name', 'Collectoo', 'siren', '849678297', 'legal_form', 'SAS', 'share_capital_minor', '1000000',
                     'rcs_city', 'Paris', 'registered_office', (select v from j where k = 'office'),
                     'vat_number', 'FR 33 849678297', 'is_professional', true), null) ->> 'version', '1',
  'a replay returns the same result');
select throws_ok($$ select public.set_billing_identity('identity-aa-0002', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('legal_name', 'Collectoo', 'siren', '849678297', 'legal_form', 'SAS', 'share_capital_minor', '1000000',
                     'rcs_city', 'Paris', 'registered_office', (select v from j where k = 'office'),
                     'vat_number', 'FR33849678297', 'is_professional', true), null) $$, '40001',
  'billing identity changed since it was read', 'compare and set: the page''s version');
select throws_ok($$ select public.set_billing_identity('identity-aa-0003', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('legal_name', 'Collectoo', 'siren', '849678297', 'legal_form', 'SAS', 'share_capital_minor', '1000000',
                     'registered_office', (select v from j where k = 'office'), 'vat_number', 'FR33849678297',
                     'is_professional', true), 1) $$, '23514', null,
  'the servicer''s identity is saved complete or not at all (no RCS city)');
select throws_ok($$ select public.set_billing_identity('identity-aa-0004', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('legal_name', 'Collectoo', 'siren', '849678297', 'legal_form', 'SAS', 'rcs_city', 'Paris',
                     'registered_office', (select v from j where k = 'office'), 'vat_number', 'FR33849678297',
                     'is_professional', true), 1) $$, '23514', null, 'nor without the capital of an SAS (R123-238 4° b)');
select throws_ok($$ select public.set_billing_identity('identity-aa-0005', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('legal_name', 'Collectoo', 'siren', '849678297', 'legal_form', 'SAS', 'share_capital_minor', '1000000',
                     'rcs_city', 'Paris', 'registered_office', (select v from j where k = 'office'),
                     'vat_number', 'FR74594097214', 'is_professional', true), 1) $$, '23514',
  'billing identity: the VAT number does not match the SIREN', 'a VAT number of another SIREN');
select is(public.set_billing_identity('identity-a1-0001', '00000000-0000-0000-0000-0000000000a1',
  jsonb_build_object('legal_name', 'Martin SAS', 'siren', '825944093',
                     'registered_office', '{"line1": "12 rue des Artisans", "postcode": "69003", "city": "Lyon", "country": "FR"}'::jsonb,
                     'billing_address', '{"line1": "BP 12", "postcode": "69003", "city": "Lyon", "country": "FR"}'::jsonb,
                     'is_professional', true, 'invoice_acceptance_ref', 'art. 11 du mandat'), null) -> 'gaps',
  '[]'::jsonb, 'and a client''s: a professional established in mainland France, complete');
select is(public.set_billing_identity('identity-a2-0001', '00000000-0000-0000-0000-0000000000a2',
  jsonb_build_object('legal_name', 'Lilas', 'siren', '190190223',
                     'registered_office', '{"line1": "1 rue des Fleurs", "postcode": "97100", "city": "Basse-Terre", "country": "FR"}'::jsonb,
                     'is_professional', false), null) -> 'gaps',
  '["professional", "mainland_france"]'::jsonb,
  'a client that is not a professional, in Guadeloupe: saved, its gaps named (founder #13)');
reset role;
select is((select array[legal_form, share_capital_minor::text, rcs_city, vat_number, (established_in ->> 'mainland_france'),
                        entrepreneur_individuel::text, version::text]
           from public.billing_identity where organization_id = '00000000-0000-0000-0000-0000000000aa'),
  array['SAS', '1000000', 'Paris', 'FR33849678297', 'true', 'false', '1'],
  'stored: the VAT number normalised, the establishment derived from the registered office');
select is((select count(*)::int from private.change_log where table_name = 'public.billing_identity'
           and row_id like '00000000-0000-0000-0000-0000000000a%'), 3,
  'each identity change is in the change log');
select pg_temp.as_user('04', 'aal1');
set local role authenticated;
select throws_ok($$ select public.set_billing_identity('identity-a1-0009', '00000000-0000-0000-0000-0000000000a1',
  '{}'::jsonb, 1) $$, '42501', null, 'an admin below aal2 sets nothing');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.set_billing_identity('identity-a1-0010', '00000000-0000-0000-0000-0000000000a1',
  '{}'::jsonb, 1) $$, '42501', null, 'nor an ops manager (admins only)');
reset role;
select pg_temp.as_user('06');
set local role authenticated;
select throws_ok($$ select public.set_billing_identity('identity-a1-0011', '00000000-0000-0000-0000-0000000000a1',
  '{}'::jsonb, 1) $$, '42501', null, 'nor another servicer''s admin');
select throws_ok($$ insert into public.billing_identity (organization_id, registered_office, is_professional)
  values ('00000000-0000-0000-0000-0000000000b1', '{"line1": "x", "postcode": "75001", "city": "Paris", "country": "FR"}', true) $$,
  '42501', null, 'nobody writes an identity directly');
reset role;
select throws_ok($$ delete from public.billing_identity where organization_id = '00000000-0000-0000-0000-0000000000a2' $$,
  '23514', null, 'an identity is never deleted');
select throws_ok($$ update public.billing_identity set vat_number = 'FR34849678297'
  where organization_id = '00000000-0000-0000-0000-0000000000aa' $$, '23514', null,
  'the guard keeps the VAT number the SIREN''s, whoever writes');
select is(private.billing_identity_gaps('00000000-0000-0000-0000-0000000000a3'), array['identity', 'siren'],
  'a client without identity nor SIREN: both named');

-- Who reads identities: the servicer's staff (its own and its clients'), a client its own and its servicer's
select pg_temp.as_user('02');
set local role authenticated;
select is((select array_agg(organization_id::text order by organization_id) from public.billing_identity),
  array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2',
        '00000000-0000-0000-0000-0000000000aa'], 'a collector of the servicer reads its own and its clients'' identities');
reset role;
select pg_temp.as_user('03', 'aal1');
set local role authenticated;
select is((select array_agg(organization_id::text order by organization_id) from public.billing_identity),
  array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa'],
  'client A reads its own and its servicer''s, never client B''s');
select is(public.billing_identity_gaps('00000000-0000-0000-0000-0000000000a1'), '{}'::text[], 'and its gaps');
select throws_ok($$ select public.billing_identity_gaps('00000000-0000-0000-0000-0000000000a2') $$, '42501', null,
  'not client B''s gaps');
reset role;
select pg_temp.as_user('06');
set local role authenticated;
select is((select count(*)::int from public.billing_identity), 0, 'another servicer reads none of them');
reset role;

-- Servicer billing settings -------------------------------------------------------------------------
select pg_temp.as_user('04');
set local role authenticated;
select is(public.set_servicer_billing_settings('settings-aa-0001', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('invoice_prefix', 'fc', 'own_bank_account_id', '80000000-0000-0000-0000-0000000000a0',
                     'bank_cutoff', jsonb_build_object('80000000-0000-0000-0000-0000000000cf', '15:30')), null) ->> 'version',
  '1', 'an admin sets the billing settings: prefix, own account, a cut-off for the dedicated account');
select throws_ok($$ select public.set_servicer_billing_settings('settings-aa-0002', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('own_bank_account_id', '80000000-0000-0000-0000-0000000000cf'), 1) $$, '23514', null,
  'invoices are paid to an own account, never to the dedicated account');
select throws_ok($$ select public.set_servicer_billing_settings('settings-aa-0003', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('own_bank_account_id', '80000000-0000-0000-0000-0000000000b0'), 1) $$, '23514', null,
  'nor to another servicer''s');
select throws_ok($$ select public.set_servicer_billing_settings('settings-aa-0004', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('bank_cutoff', jsonb_build_object('80000000-0000-0000-0000-0000000000cf', '25:00')), 1) $$, '23514', null,
  'a cut-off is an HH:MM time');
select throws_ok($$ select public.set_servicer_billing_settings('settings-aa-0005', '00000000-0000-0000-0000-0000000000aa',
  jsonb_build_object('invoice_prefix', 'F'), 1) $$, '23514', null, 'a prefix has 2 to 6 capital letters');
select throws_ok($$ select public.set_servicer_billing_settings('settings-aa-0006', '00000000-0000-0000-0000-0000000000aa',
  '{}'::jsonb, null) $$, '40001', null, 'compare and set');
select throws_ok($$ select public.close_bank_account('close-own-0001', '80000000-0000-0000-0000-0000000000a0', 'fin') $$,
  '23514', 'the own account is named in the billing settings: choose another one first',
  'the own account invoices are paid to is not closed');
reset role;
select is((select array[invoice_prefix, vat_on_debits::text,
                        (penalty_text like '%Banque centrale européenne%majoré de 10 points de pourcentage.')::text]
           from public.servicer_billing_settings where organization_id = '00000000-0000-0000-0000-0000000000aa'),
  array['FC', 'false', 'true'],
  'stored: the prefix in capitals, VAT on encaissements by default, the statutory penalty text (L441-10 II)');
select pg_temp.as_user('01');
set local role authenticated;
select is((select count(*)::int from public.servicer_billing_settings), 1, 'ops managers read the settings');
select throws_ok($$ select public.set_servicer_billing_settings('settings-aa-0007', '00000000-0000-0000-0000-0000000000aa',
  '{}'::jsonb, 1) $$, '42501', null, 'but only admins set them');
reset role;
select pg_temp.as_user('02');
set local role authenticated;
select is((select count(*)::int from public.servicer_billing_settings), 0, 'collectors read no settings');
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select is((select count(*)::int from public.servicer_billing_settings), 0, 'nor clients');
reset role;

-- Client documents -----------------------------------------------------------------------------------
insert into t values ('newdoc', 'd0000000-0000-0000-0000-0000000000f1');
select pg_temp.as_user('01');
set local role authenticated;
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('documents', %L) $$,
  pg_temp.key('a1', 'd0000000-0000-0000-0000-0000000000f1')), 'money staff upload a client''s file at its key');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('documents', %L) $$,
  pg_temp.key('b1', 'd0000000-0000-0000-0000-0000000000f2')), '42501', null, 'never at another servicer''s client''s key');
select throws_ok(format($$ select public.register_client_document('doc-reg-0001', '00000000-0000-0000-0000-0000000000a1',
  'payout_rib', %L, 'rib.pdf', %L, 'application/pdf') $$, pg_temp.key('a1', 'd0000000-0000-0000-0000-0000000000f3'),
  repeat('b', 64)), '23514', 'document: the file is not uploaded yet', 'a file not uploaded is not registered');
select throws_ok(format($$ select public.register_client_document('doc-reg-0002', '00000000-0000-0000-0000-0000000000a2',
  'payout_rib', %L, 'rib.pdf', %L, 'application/pdf') $$, pg_temp.key('a1', 'd0000000-0000-0000-0000-0000000000f1'),
  repeat('b', 64)), '23514', 'document: the file is not at a key of this client', 'nor as another client''s');
insert into t select 'newdoc', (public.register_client_document('doc-reg-0003', '00000000-0000-0000-0000-0000000000a1',
  'payout_rib', pg_temp.key('a1', 'd0000000-0000-0000-0000-0000000000f1'), 'RIB Martin.pdf', repeat('B', 64),
  'application/pdf') ->> 'document_id')::uuid on conflict (k) do update set v = excluded.v;
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('documents', %L) $$,
  pg_temp.key('a1', 'd0000000-0000-0000-0000-0000000000f1')), '42501', null, 'a registered key is never uploaded again');
reset role;
select is((select array[kind, sha256, file_name, organization_id::text] from public.document
           where id = (select v from t where k = 'newdoc')),
  array['payout_rib', repeat('b', 64), 'RIB Martin.pdf', '00000000-0000-0000-0000-0000000000aa'],
  'registered: a document of the client, its hash in lower case');
select pg_temp.as_user('02');
set local role authenticated;
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('documents', %L) $$,
  pg_temp.key('a1', 'd0000000-0000-0000-0000-0000000000f4')), '42501', null, 'collectors upload no client document');
select is((select count(*)::int from public.document where kind in ('payout_rib', 'mandate_document', 'client_status_evidence')),
  0, 'and read none');
reset role;
select pg_temp.as_user('03', 'aal1');
set local role authenticated;
select is((select array_agg(kind order by kind) from (select distinct kind from public.document) x),
  array['mandate_document', 'payout_rib'], 'client A''s administrator reads its RIBs and its mandate, not the evidence');
select is((select count(*)::int from public.document where client_organization_id <> '00000000-0000-0000-0000-0000000000a1'),
  0, 'never client B''s');
select is((select count(*)::int from storage.objects where bucket_id = 'documents' and name like 'client/%'), 1,
  'and the file of the one uploaded');
reset role;
select pg_temp.as_user('07');
set local role authenticated;
select is((select count(*)::int from public.document), 0, 'a client viewer reads no client document');
reset role;
select pg_temp.as_user('11');
set local role authenticated;
select is((select count(*)::int from public.document), 0,
  'nor a client viewer of the whole client (the role is checked, not only the portfolio restriction)');
reset role;
select pg_temp.as_user('08');
set local role authenticated;
select is((select count(*)::int from public.document), 0,
  'nor a client administrator restricted to some portfolios (whole-client data, OQ-48)');
reset role;

-- Payout accounts: a second person confirms (founder #10) -------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
insert into t select 'pa1', (public.propose_payout_account('payout-prop-0001', '00000000-0000-0000-0000-0000000000a1',
  'EUR', 'fr76 4260 6140 1141 7660 6002 310', 'MARTIN SAS', 'bnpafrpp', pg_temp.d('01')) ->> 'payout_account_id')::uuid;
select is((select array[status, iban, bic, holder_name, kind] from public.client_payout_account
           where id = (select v from t where k = 'pa1')),
  array['proposed', 'FR7642606140114176606002310', 'BNPAFRPP', 'MARTIN SAS', 'client'],
  'ops propose the client''s IBAN as on its RIB (normalised)');
select throws_ok(format($$ select public.propose_payout_account('payout-prop-0002', '00000000-0000-0000-0000-0000000000a1',
  'EUR', 'FR7663953752338647431575659', 'MARTIN SAS', null, %L) $$, pg_temp.d('02')), '23514',
  'payout account: a proposal already waits for confirmation', 'one proposal at a time per client and currency');
select throws_ok(format($$ select public.propose_payout_account('payout-prop-0003', '00000000-0000-0000-0000-0000000000a2',
  'EUR', 'FR7697872919606945315603659', 'LILAS', null, %L) $$, pg_temp.d('07')), '23514',
  'payout account: this IBAN is one of the servicer''s own bank accounts', 'never one of the servicer''s accounts');
select throws_ok(format($$ select public.propose_payout_account('payout-prop-0004', '00000000-0000-0000-0000-0000000000a2',
  'EUR', 'FR7642606140114176606002310', 'LILAS', null, %L) $$, pg_temp.d('07')), '23514',
  'payout account: this IBAN is another client''s payout account', 'never another client''s IBAN');
select throws_ok(format($$ select public.propose_payout_account('payout-prop-0005', '00000000-0000-0000-0000-0000000000a2',
  'EUR', 'FR7631378633091943291265273', 'LILAS', null, %L) $$, pg_temp.d('01')), '23514',
  'payout account: the client''s RIB is required', 'the RIB is a document of that client');
select throws_ok(format($$ select public.propose_payout_account('payout-prop-0006', '00000000-0000-0000-0000-0000000000a2',
  'EUR', 'FR7631378633091943291265274', 'LILAS', null, %L) $$, pg_temp.d('07')), '23514', 'invalid IBAN',
  'an IBAN with wrong check digits');
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0001', %L, 'FR7642606140114176606002310') $$,
  (select v from t where k = 'pa1')), '42501', null, 'an ops manager confirms nothing (admins and the client do)');
reset role;
select pg_temp.as_user('02');
set local role authenticated;
select throws_ok(format($$ select public.propose_payout_account('payout-prop-0007', '00000000-0000-0000-0000-0000000000a1',
  'USD', 'FR7663953752338647431575659', 'MARTIN SAS', null, %L) $$, pg_temp.d('02')), '42501', null,
  'collectors propose nothing');
select is((select count(*)::int from public.client_payout_account), 0, 'and read no payout account');
reset role;
select pg_temp.as_user('03', 'aal1');
set local role authenticated;
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0002', %L, 'FR7642606140114176606002310') $$,
  (select v from t where k = 'pa1')), '42501', null, 'the client''s administrator confirms only at aal2');
select is((select count(*)::int from public.client_payout_account), 0, 'client users read no payout row');
select is((select array[iban_masked, status, proposed_by_me::text, paid_before::text]
           from public.payout_accounts('00000000-0000-0000-0000-0000000000a1')),
  array['FR76 •••• •••• 2310', 'proposed', 'false', 'false'], 'its administrator reads it masked through the page''s read');
reset role;
select pg_temp.as_user('08');
set local role authenticated;
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0003', %L, 'FR7642606140114176606002310') $$,
  (select v from t where k = 'pa1')), '42501', null, 'nor an administrator restricted to some portfolios');
select throws_ok($$ select * from public.payout_accounts('00000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'who does not read them either');
reset role;
select pg_temp.as_user('07');
set local role authenticated;
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0004', %L, 'FR7642606140114176606002310') $$,
  (select v from t where k = 'pa1')), '42501', null, 'nor a client viewer');
reset role;
select pg_temp.as_user('11');
set local role authenticated;
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0008', %L, 'FR7642606140114176606002310') $$,
  (select v from t where k = 'pa1')), '42501', null, 'nor a client viewer of the whole client, at aal2');
select throws_ok(format($$ select public.reject_payout_account('payout-rej-0008', %L, 'non') $$,
  (select v from t where k = 'pa1')), '42501', null, 'who refuses nothing either');
select throws_ok($$ select * from public.payout_accounts('00000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'and does not read them');
reset role;
select pg_temp.as_user('09');
set local role authenticated;
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0005', %L, 'FR7642606140114176606002310') $$,
  (select v from t where k = 'pa1')), '42501', null, 'nor client B''s administrator');
select throws_ok($$ select * from public.payout_accounts('00000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'who does not read client A''s');
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0006', %L, 'FR7663953752338647431575659') $$,
  (select v from t where k = 'pa1')), '23514', 'payout account: the IBAN typed is not the one proposed',
  'the IBAN typed from the RIB must be the one proposed');
select is(public.confirm_payout_account('payout-conf-0007', (select v from t where k = 'pa1'), 'FR76 4260 6140 1141 7660 6002 310')
          ->> 'confirmed_via', 'client_portal', 'the client''s administrator confirms it at aal2');
select is(public.confirm_payout_account('payout-conf-0007', (select v from t where k = 'pa1'), 'FR76 4260 6140 1141 7660 6002 310')
          ->> 'status', 'active', 'a replay returns the same result');
reset role;
select is((select array[status, confirmed_via, confirmed_by::text] from public.client_payout_account
           where id = (select v from t where k = 'pa1')),
  array['active', 'client_portal', '10000000-0000-0000-0000-000000000003'], 'active, confirmed by the client');

-- A new IBAN: an admin proposes it, the same admin cannot confirm it, another admin does; the old one is retired
select pg_temp.as_user('04');
set local role authenticated;
insert into t select 'pa2', (public.propose_payout_account('payout-prop-0010', '00000000-0000-0000-0000-0000000000a1',
  'EUR', 'FR7663953752338647431575659', 'MARTIN SAS', null, pg_temp.d('02')) ->> 'payout_account_id')::uuid;
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0010', %L, 'FR7663953752338647431575659') $$,
  (select v from t where k = 'pa2')), '23514',
  'payout account: the person who proposed it cannot confirm it (a second person confirms)',
  'the admin who proposed an IBAN cannot confirm it');
reset role;
select throws_ok(format($$ update public.client_payout_account set status = 'active', confirmed_by = proposed_by,
  confirmed_at = now(), confirmed_via = 'second_admin' where id = %L $$, (select v from t where k = 'pa2')), '23514', null,
  'nor anyone, whoever writes (constraint: confirmed by another person)');
select pg_temp.as_user('05');
set local role authenticated;
select is(public.confirm_payout_account('payout-conf-0011', (select v from t where k = 'pa2'), 'FR7663953752338647431575659')
          ->> 'confirmed_via', 'second_admin', 'a second admin of the servicer confirms it');
reset role;
select is((select array_agg(status order by proposed_at) from public.client_payout_account
           where client_organization_id = '00000000-0000-0000-0000-0000000000a1'),
  array['retired', 'active'], 'the new account replaces the current one (one current account per client and currency)');
select is((select closed_reason from public.client_payout_account where id = (select v from t where k = 'pa1')),
  'Remplacé par FR7663953752338647431575659', 'the old one names its replacement');
select throws_ok(format($$ update public.client_payout_account set iban = 'FR7631378633091943291265273' where id = %L $$,
  (select v from t where k = 'pa2')), '23514', null, 'what was proposed never changes');
select throws_ok(format($$ update public.client_payout_account set status = 'proposed', confirmed_by = null,
  confirmed_at = null, confirmed_via = null where id = %L $$, (select v from t where k = 'pa2')), '23514', null,
  'and its status only moves forward');
select throws_ok($$ delete from public.client_payout_account $$, '23514', null, 'payout accounts are never deleted');
select is((select count(*)::int from private.change_log where table_name = 'public.client_payout_account'), 5,
  'every proposal and decision is in the change log');

-- Read as the client's at import: every confirmed IBAN (current or retired), never a proposal
select pg_temp.as_user('01');
set local role authenticated;
insert into t select 'pa3', (public.propose_payout_account('payout-prop-0020', '00000000-0000-0000-0000-0000000000a2',
  'EUR', 'FR7631378633091943291265273', 'LILAS', null, pg_temp.d('07')) ->> 'payout_account_id')::uuid;
reset role;
select is(private.registered_client_ibans('00000000-0000-0000-0000-0000000000aa'),
  array['FR7642606140114176606002310', 'FR7663953752338647431575659'],
  'the clients'' confirmed IBANs, current and retired; not a proposal');
select is((select client_ibans from private.statement_classification_ibans('80000000-0000-0000-0000-0000000000cf')),
  array['FR7642606140114176606002310', 'FR7663953752338647431575659'], 'what the parser receives for the statement');
select is(private.bank_line_refined_kind('debtor_credit', 'credit', 'E2E-1', 'FR7642606140114176606002310', '{}',
                                         private.registered_client_ibans('00000000-0000-0000-0000-0000000000aa')),
  'client_transfer_in', 'a credit from a client''s payout IBAN is the client''s, never a debtor payment (design §12)');
select is(private.registered_client_ibans('00000000-0000-0000-0000-0000000000bb'), '{}'::text[],
  'another servicer''s list is its own');
-- A refusal, by the client's administrator, with a reason
select pg_temp.as_user('09');
set local role authenticated;
select throws_ok(format($$ select public.reject_payout_account('payout-rej-0001', %L, ' ') $$, (select v from t where k = 'pa3')),
  '23514', 'a reason is required', 'a refusal says why');
select is(public.reject_payout_account('payout-rej-0002', (select v from t where k = 'pa3'), 'Ce n''est pas notre compte')
          ->> 'status', 'rejected', 'the client''s administrator refuses a proposal');
reset role;
-- Money terms: validators (SQL twin of collectoo_worker.remittance.terms) -----------------------------------------
select is(private.commission_schedule_error((select v from j where k = 'schedule')), null, 'the §8.1 example is valid');
select is(private.remittance_terms_error((select v from j where k = 'terms')), null, 'the §8.2 example is valid');
select is(array[private.commission_schedule_error((select v from j where k = 'schedule') || '{"clause_ref": "art. 6"}'),
                private.commission_schedule_error(jsonb_set((select v from j where k = 'schedule'), '{rules,0,rate,rate}', '0.15')),
                private.commission_schedule_error(jsonb_set((select v from j where k = 'schedule'), '{rules,0,rate,rate}', '"1.5"')),
                private.commission_schedule_error(jsonb_set((select v from j where k = 'schedule'), '{rules,1,match}', '{"families": ["principal"]}')),
                private.commission_schedule_error(jsonb_set((select v from j where k = 'schedule'), '{rules,1,tier_key}', '"b2b"')),
                private.commission_schedule_error(jsonb_set((select v from j where k = 'schedule'), '{rules,1,rate,tiers,0,up_to_minor}', 'null')),
                private.commission_schedule_error(jsonb_set((select v from j where k = 'schedule'), '{rules,0,rate,kind}', '"whole_tiers"'))],
  array['keys', 'rule.rate', 'rule.rate', 'rules.last_not_catch_all', 'rules.duplicate_tier_key', 'rule.rate', 'rule.rate'],
  'refused: an unknown key, a rate as a number or above 1, a last rule that is not a catch-all, a repeated tier key, '
  'an unbounded tier before the last, whole-rate tiers');
select is(array[private.remittance_terms_error((select v from j where k = 'terms') || '{"frequency": "monthly"}'),
                private.remittance_terms_error((select v from j where k = 'terms') || '{"weekday": 2}'),
                private.remittance_terms_error((select v from j where k = 'terms') || '{"invoice_payment_days": 46}'),
                private.remittance_terms_error((select v from j where k = 'terms') || '{"holdback": [{"days": 60}]}'),
                private.remittance_terms_error((select v from j where k = 'terms') - 'netting'),
                private.remittance_terms_error((select v from j where k = 'terms') || '{"frequency": "weekly", "weekday": 5}')],
  array['frequency', 'weekday', 'invoice_payment_days', 'holdback', 'keys', null],
  'refused: a monthly frequency, a weekday without a weekly one, a term above 45 days (L441-10 I), a hold-back (M5), '
  'a missing netting key; a weekly frequency on a Friday is valid');
select throws_ok($$ insert into public.mandate_terms (mandate_id, valid_from, commission_schedule)
  values ('70000000-0000-0000-0000-000000000009', '2026-01-15', '{"schema": "commission-1"}') $$, '23514', null,
  'the column refuses an invalid schedule, whoever writes');
select is(private.commission_schedule_error(private.legacy_commission_schedule(0.15)), null,
  'the back-fill''s schedule (one flat rule at the old rate) is valid');
select is((select array[coalesce(commission_schedule::text, '-'), coalesce(commission_clause_ref, '-'),
                        coalesce(schedule_sha256, '-')]
           from public.mandate_terms where mandate_id = '70000000-0000-0000-0000-000000000002'),
  array['-', '-', '-'], 'a version written after the migration with a rate only has no schedule (incomplete)');
select is((select schedule_sha256 from public.mandate_terms where mandate_id = '70000000-0000-0000-0000-000000000001'),
  private.terms_sha256((select v from j where k = 'schedule'), (select v from j where k = 'terms')),
  'each version carries the hash of its schedule and terms');

-- Immutability once in force (§6.1), restrict --------------------------------------------------------------
select throws_ok($$ update public.mandate_terms set commission_clause_ref = 'art. 6 bis'
  where mandate_id = '70000000-0000-0000-0000-000000000001' $$, '23514', null,
  'a version in force never changes, whoever writes');
select throws_ok($$ update public.mandate_terms set valid_to = '2026-03-01'
  where mandate_id = '70000000-0000-0000-0000-000000000001' $$, '23514', null, 'nor ends in the past');
select lives_ok($$ update public.mandate_terms set valid_to = private.paris_today() + 60
  where mandate_id = '70000000-0000-0000-0000-000000000001' $$, 'its end may move to a day not yet passed');
select lives_ok($$ update public.mandate_terms set valid_to = null
  where mandate_id = '70000000-0000-0000-0000-000000000001' $$, 'or open again');
select throws_ok($$ delete from public.mandate_terms where mandate_id = '70000000-0000-0000-0000-000000000001' $$, '23514',
  null, 'a version in force is never deleted');
select throws_ok($$ insert into public.mandate_terms (mandate_id, valid_from, valid_to, commission_rate)
  values ('70000000-0000-0000-0000-000000000002', '2025-01-01', '2026-01-15', 0.1) $$, '23514',
  'mandate terms refused: starts_too_early', 'a second version never starts before today (never retroactive)');
-- M5 (a2): no portfolio, a first version that ended in February
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on) values
  ('70000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
   'MAND-A2-BIS', 'mandate_amicable', '2026-01-15');
insert into public.mandate_terms (mandate_id, valid_from, valid_to, commission_rate)
values ('70000000-0000-0000-0000-000000000005', '2026-01-15', '2026-02-01', 0.1);
select throws_ok($$ insert into public.mandate_terms (mandate_id, valid_from, commission_rate)
  values ('70000000-0000-0000-0000-000000000005', private.paris_today(), 0.1) $$, '23514',
  'mandate terms refused: starts_too_early',
  'nor today: a new version starts tomorrow at the earliest, whoever writes (never on money encaissé that day)');
select lives_ok($$ insert into public.mandate_terms (mandate_id, valid_from, commission_rate)
  values ('70000000-0000-0000-0000-000000000005', private.paris_today() + 1, 0.1) $$, 'tomorrow it may');
select is((select confdeltype::text from pg_constraint where conname = 'mandate_terms_mandate_id_fkey'), 'r',
  'the versions'' foreign key is ON DELETE RESTRICT');
select throws_ok($$ delete from public.mandate where id = '70000000-0000-0000-0000-000000000005' $$, '23503',
  'update or delete on table "mandate" violates foreign key constraint "mandate_terms_mandate_id_fkey" on table "mandate_terms"',
  'a mandate with versions is never deleted (ON DELETE RESTRICT; no portfolio names it)');

-- set_mandate_terms (admin at aal2) -------------------------------------------------------------------------------
insert into t select 'm1v1', id from public.mandate_terms where mandate_id = '70000000-0000-0000-0000-000000000001';
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok($$ select public.set_mandate_terms('terms-0001', '70000000-0000-0000-0000-000000000001',
  private.paris_today() - 1, (select v from j where k = 'schedule'), 'art. 6', (select v from j where k = 'terms'), 'art. 7',
  pg_temp.d('04'), 30, (select v from t where k = 'm1v1')) $$, '23514', 'mandate terms refused: starts_too_early',
  'never from a past day');
select throws_ok($$ select public.set_mandate_terms('terms-0012', '70000000-0000-0000-0000-000000000001',
  private.paris_today(), (select v from j where k = 'schedule'), 'art. 6', (select v from j where k = 'terms'), 'art. 7',
  pg_temp.d('04'), 30, (select v from t where k = 'm1v1')) $$, '23514', 'mandate terms refused: starts_too_early',
  'nor from today: tomorrow at the earliest (Paris), so money encaissé today stays under the terms in force');
select throws_ok($$ select public.set_mandate_terms('terms-0002', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 7, (select v from j where k = 'schedule'), ' ', (select v from j where k = 'terms'), 'art. 7',
  pg_temp.d('04'), 30, (select v from t where k = 'm1v1')) $$, '23514',
  'mandate terms: the clause references are required (R124-3 3° and 4°)', 'never without its clause references');
select throws_ok($$ select public.set_mandate_terms('terms-0003', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 7, (select v from j where k = 'schedule'), 'art. 6', (select v from j where k = 'terms'), 'art. 7',
  pg_temp.d('06'), 30, (select v from t where k = 'm1v1')) $$, '23514', 'mandate terms: the signed document is required',
  'the signed document is a mandate document of that client');
select throws_ok($$ select public.set_mandate_terms('terms-0004', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 7, jsonb_set((select v from j where k = 'schedule'), '{rules,0,match,claim_types}', '["yacht_loan"]'),
  'art. 6', (select v from j where k = 'terms'), 'art. 7', pg_temp.d('04'), 30, (select v from t where k = 'm1v1')) $$,
  '23514', 'mandate terms: unknown claim type', 'claim types it names exist');
select throws_ok($$ select public.set_mandate_terms('terms-0005', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 7, jsonb_set((select v from j where k = 'schedule'), '{rules,0,match}',
  '{"portfolio_ids": ["20000000-0000-0000-0000-0000000000a3"]}'), 'art. 6', (select v from j where k = 'terms'), 'art. 7',
  pg_temp.d('04'), 30, (select v from t where k = 'm1v1')) $$, '23514', 'mandate terms: a portfolio of another mandate',
  'portfolios it names are the mandate''s');
select throws_ok($$ select public.set_mandate_terms('terms-0006', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 7, (select v from j where k = 'schedule') || '{"rules": []}', 'art. 6',
  (select v from j where k = 'terms'), 'art. 7', pg_temp.d('04'), 30, (select v from t where k = 'm1v1')) $$, '23514',
  'mandate terms: invalid commission schedule (rules)', 'the schedule is validated, its first error named');
select throws_ok($$ select public.set_mandate_terms('terms-0007', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 7, (select v from j where k = 'schedule'), 'art. 6', (select v from j where k = 'terms'), 'art. 7',
  pg_temp.d('04'), 31, (select v from t where k = 'm1v1')) $$, '23514', null, 'the delay is 1 to 30 days (R124-6)');
select throws_ok($$ select public.set_mandate_terms('terms-0008', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 7, (select v from j where k = 'schedule'), 'art. 6', (select v from j where k = 'terms'), 'art. 7',
  pg_temp.d('04'), 30, null) $$, '40001', 'mandate terms changed since they were read',
  'compare and set on the latest version the page showed');
insert into t select 'm1v2', (public.set_mandate_terms('terms-0009', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 7, jsonb_set((select v from j where k = 'schedule'), '{rules,0,rate,rate}', '"0.12"'),
  'art. 6 (avenant n° 1)', (select v from j where k = 'terms') || '{"frequency": "weekly", "weekday": 2}', 'art. 7',
  pg_temp.d('04'), 20, (select v from t where k = 'm1v1')) ->> 'mandate_terms_id')::uuid;
select is((public.set_mandate_terms('terms-0009', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 7, jsonb_set((select v from j where k = 'schedule'), '{rules,0,rate,rate}', '"0.12"'),
  'art. 6 (avenant n° 1)', (select v from j where k = 'terms') || '{"frequency": "weekly", "weekday": 2}', 'art. 7',
  pg_temp.d('04'), 20, (select v from t where k = 'm1v1')) ->> 'mandate_terms_id')::uuid, (select v from t where k = 'm1v2'),
  'a replay returns the same version');
reset role;
select is((select array_agg(array[(valid_from - private.paris_today())::text, coalesce((valid_to - private.paris_today())::text, '-'),
                                  remittance_max_days::text, created_by::text] order by valid_from)
           from public.mandate_terms where mandate_id = '70000000-0000-0000-0000-000000000001')
          [2:2][1:4],
  array[array['7', '-', '20', '10000000-0000-0000-0000-000000000004']],
  'the new version starts on its day, open, with its delay and who set it');
select is((select valid_to - private.paris_today() from public.mandate_terms where id = (select v from t where k = 'm1v1')), 7,
  'the version in force ends that day (it applied until then)');
select pg_temp.as_user('04');
set local role authenticated;
select is(public.set_mandate_terms('terms-0010', '70000000-0000-0000-0000-000000000001',
  private.paris_today() + 3, (select v from j where k = 'schedule'), 'art. 6 (avenant n° 2)',
  (select v from j where k = 'terms'), 'art. 7', pg_temp.d('04'), 30, (select v from t where k = 'm1v2')) ->> 'superseded',
  '1', 'an earlier start supersedes the version not yet in force (it never applied)');
reset role;
select is((select array_agg(case when valid_from = '2026-01-15' then 'v1' else (valid_from - private.paris_today())::text end
                            || '/' || coalesce((valid_to - private.paris_today())::text, '-') order by valid_from)
           from public.mandate_terms where mandate_id = '70000000-0000-0000-0000-000000000001'),
  array['v1/3', '3/-'], 'and ends the one in force that day');
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.set_mandate_terms('terms-0011', '70000000-0000-0000-0000-000000000002',
  private.paris_today() + 7, (select v from j where k = 'schedule'), 'art. 6', (select v from j where k = 'terms'), 'art. 7',
  pg_temp.d('06'), 30, null) $$, '42501', null, 'admins only set terms');
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select is((select count(*)::int from public.mandate_terms), 2, 'the client reads its own mandate''s terms');
reset role;
-- the insurance clause (R124-3 2°), compare and set
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok($$ select public.set_mandate_insurance_clause('insurance-0001', '70000000-0000-0000-0000-000000000002',
  'art. 8', 'art. 1') $$, '40001', null, 'the insurance clause: compare and set on the value shown');
select is(public.set_mandate_insurance_clause('insurance-0002', '70000000-0000-0000-0000-000000000002', ' art. 8 — Garantie ', null)
          ->> 'insurance_clause_ref', 'art. 8 — Garantie', 'an admin records it');
reset role;

-- The confirmation gate (§9.1, founder #13) --------------------------------------------------------------------
-- The first version of M1 is in force today (its successor starts in 3 days).
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000a1', private.paris_today()), '{}'::text[],
  'P1 is ready: terms complete, both identities complete');
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000a3', private.paris_today()),
  array['commission_schedule_missing', 'commission_clause_missing', 'remittance_terms_missing', 'remittance_clause_missing',
        'terms_document_missing', 'client_not_professional', 'client_not_mainland_france'],
  'P3 (a version with a rate only, a client neither professional nor in mainland France): each reason named');
insert into public.mandate_terms (mandate_id, valid_from, commission_schedule, commission_clause_ref, remittance_terms,
                                  remittance_clause_ref, document_id)
values ('70000000-0000-0000-0000-000000000003', '2026-01-15', (select v from j where k = 'schedule'), 'art. 6',
        (select v from j where k = 'terms'), 'art. 7', pg_temp.d('06'));
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000a4', private.paris_today()),
  array['insurance_clause_missing', 'client_identity_incomplete'],
  'P4: no insurance clause (R124-3 2°), a client without identity');
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000b1', private.paris_today()),
  array['no_active_mandate', 'insurance_clause_missing', 'servicer_identity_incomplete', 'client_identity_incomplete'],
  'PB: no version in force, no insurance clause, a servicer and a client without identity');
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000a1', '2026-01-14'),
  array['no_active_mandate'], 'the gate reads the version in force on the day asked');
-- A batch of P1 committed; then of P3 (refused); the gate again in the job
create or replace function pg_temp.committed_batch(p_id uuid, p_portfolio uuid) returns void language plpgsql as $$
begin
  insert into public.boarding_batch (id, organization_id, client_organization_id, portfolio_id, version, cut_off_date,
                                     dq_report)
  select p_id, p.organization_id, p.client_organization_id, p.id,
         (select coalesce(max(b.version), 0) + 1 from public.boarding_batch b where b.portfolio_id = p.id), '2026-09-30',
         '{"staging": {"opening": {"currencies": {}}}}'
  from public.portfolio p where p.id = p_portfolio;
  perform private.transition_batch(p_id, s, 'test')
  from unnest(array['uploaded', 'profiled', 'mapping_proposed', 'mapping_approved', 'transformed', 'validated', 'staged',
                    'committing']) with ordinality as x (s, n) order by n;
  perform private.complete_batch_commit(p_id);
end $$;
select pg_temp.committed_batch('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1');
select pg_temp.committed_batch('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-0000000000a3');
select pg_temp.committed_batch('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a2');
insert into public.account (organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                            legal_regime, currency, status, boarding_batch_id)
values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a2',
        'b2b_invoice', 'USD-1', 'commercial_b2b', 'USD', 'staged', '30000000-0000-0000-0000-000000000002');
select pg_temp.as_user('01');
set local role authenticated;
select is(public.boarding_batch_readiness('30000000-0000-0000-0000-000000000002'), array['currency_not_eur'],
  'a batch with an account outside EUR: refused (founder #13)');
select throws_ok($$ select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000003') $$, '23514',
  'the portfolio is not ready for confirmation: commission_schedule_missing, commission_clause_missing, '
  'remittance_terms_missing, remittance_clause_missing, terms_document_missing, client_not_professional, '
  'client_not_mainland_france', 'confirmation is refused while the terms or identities are incomplete');
select throws_ok($$ select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000002') $$, '23514', null,
  'or the batch holds an account outside EUR');
select lives_ok($$ select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000001') $$,
  'a ready portfolio''s batch is confirmed (requested)');
reset role;
select is((select status from public.boarding_batch where id = '30000000-0000-0000-0000-000000000003'), 'committed',
  'the refused batch stays committed');
-- the client stops being a professional before the job runs: the job checks again and posts nothing
update public.billing_identity set is_professional = false where organization_id = '00000000-0000-0000-0000-0000000000a1';
select is(private.complete_batch_confirmation('30000000-0000-0000-0000-000000000001'), 'not_ready',
  'the job checks the gate again');
select is((select array[status, failed_job ->> 'error', failed_job ->> 'blockers'] from public.boarding_batch
           where id = '30000000-0000-0000-0000-000000000001'),
  array['committed', 'not_ready', '["client_not_professional"]'], 'back to committed with the reasons, nothing posted');
update public.billing_identity set is_professional = true where organization_id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.as_user('01');
set local role authenticated;
select lives_ok($$ select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000001') $$, 'requested again');
reset role;
select is(private.complete_batch_confirmation('30000000-0000-0000-0000-000000000001'), 'confirmed',
  'and confirmed once ready');
select pg_temp.as_user('02');
set local role authenticated;
select is((select array_agg(portfolio_name || ':' || cardinality(blockers) order by portfolio_name)
           from public.client_readiness('00000000-0000-0000-0000-0000000000a1')), array['P1:0', 'P2:0'],
  'staff read a client''s readiness per portfolio');
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select throws_ok($$ select public.client_readiness('00000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'clients do not');
select throws_ok($$ select public.boarding_batch_readiness('30000000-0000-0000-0000-000000000001') $$, '42501', null,
  'nor a batch''s');
reset role;
select pg_temp.as_user('06');
set local role authenticated;
select throws_ok($$ select public.client_readiness('00000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'nor another servicer');
reset role;

-- The liquidator's account (court-appointed): confirmed by a second admin only, never by the client's users (L641-9)
select pg_temp.as_user('04');
set local role authenticated;
select lives_ok($$ select public.retire_payout_account('payout-ret-0001', (select v from t where k = 'pa2'), 'Liquidation') $$,
  'an admin retires the current account');
insert into t select 'pa4', (public.propose_payout_account('payout-prop-0030', '00000000-0000-0000-0000-0000000000a1',
  'EUR', 'FR7643625512382429355294717', 'SELARL MANDATAIRE ès qualités', null, pg_temp.d('03'), 'court_appointed')
  ->> 'payout_account_id')::uuid;
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0030', %L, 'FR7643625512382429355294717') $$,
  (select v from t where k = 'pa4')), '42501', 'payout account refused: court_appointed',
  'the client''s administrator does not confirm a liquidator''s account');
select throws_ok(format($$ select public.reject_payout_account('payout-rej-0030', %L, 'pas notre compte') $$,
  (select v from t where k = 'pa4')), '42501', 'payout account refused: court_appointed', 'nor refuses it');
reset role;
select pg_temp.as_user('05');
set local role authenticated;
select is(public.confirm_payout_account('payout-conf-0031', (select v from t where k = 'pa4'), 'FR7643625512382429355294717')
          ->> 'confirmed_via', 'second_admin', 'a second admin does');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select is((select count(*)::int from public.client_payout_account), 4, 'money staff read every payout account of the servicer');
reset role;
select pg_temp.as_user('06');
set local role authenticated;
select is((select count(*)::int from public.client_payout_account), 0, 'another servicer reads none');
select throws_ok($$ select * from public.payout_accounts('00000000-0000-0000-0000-0000000000a1') $$, '42501', null,
  'nor through the read');
reset role;

-- Client status events (2003, L622-7, L641-9): append-only, with evidence ------------------------------------------
-- (a batch of P2 requested before the liquidation is recorded: ready then)
select pg_temp.committed_batch('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-0000000000a2');
select pg_temp.as_user('01');
set local role authenticated;
select lives_ok($$ select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000004') $$,
  'a batch of P2 is requested while the client has no event');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok($$ select public.record_client_status_event('event-0001', '00000000-0000-0000-0000-0000000000a1',
  'liquidation', private.paris_today() + 1, pg_temp.d('05'), null) $$, '23514', 'client event: the date cannot be in the future',
  'an event is recorded once it happened');
select throws_ok($$ select public.record_client_status_event('event-0002', '00000000-0000-0000-0000-0000000000a1',
  'liquidation', '2026-11-02', pg_temp.d('01'), null) $$, '23514', 'client event: the evidence is required',
  'its evidence is a document of that kind');
select throws_ok($$ select public.record_client_status_event('event-0003', '00000000-0000-0000-0000-0000000000a1',
  'liquidation', '2026-11-02', pg_temp.d('05'), null, (select v from t where k = 'pa2')) $$, '23514', null,
  'only a court-appointed account is named');
insert into t select 'ev1', (public.record_client_status_event('event-0004', '00000000-0000-0000-0000-0000000000a1',
  'liquidation', '2026-11-02', pg_temp.d('05'), 'Jugement du TC de Lyon', (select v from t where k = 'pa4'))
  ->> 'client_status_event_id')::uuid;
reset role;
select is((select array[kind, effective_date::text, note] from public.client_status_event
           where id = (select v from t where k = 'ev1')),
  array['liquidation', '2026-11-02', 'Jugement du TC de Lyon'], 'an admin records the liquidation with its evidence');
select throws_ok($$ update public.client_status_event set note = 'x' $$, '23514', null, 'events are append-only');
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.record_client_status_event('event-0005', '00000000-0000-0000-0000-0000000000a1',
  'death', '2026-11-02', pg_temp.d('05'), null) $$, '42501', null, 'admins only record them');
select is((select count(*)::int from public.client_status_event), 1, 'money staff read them');
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select is((select count(*)::int from public.client_status_event), 0, 'clients do not');
reset role;
select pg_temp.as_user('02');
set local role authenticated;
select is((select count(*)::int from public.client_status_event), 0, 'nor collectors');
reset role;

-- Once the liquidation is recorded, the client's own users act on no payout account (L641-9 I); money staff still do
select pg_temp.as_user('01');
set local role authenticated;
insert into t select 'pa5', (public.propose_payout_account('payout-prop-0040', '00000000-0000-0000-0000-0000000000a1',
  'EUR', 'FR7611790967787158343046874', 'MARTIN SAS', null, pg_temp.d('01')) ->> 'payout_account_id')::uuid;
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select throws_ok(format($$ select public.confirm_payout_account('payout-conf-0040', %L, 'FR7611790967787158343046874') $$,
  (select v from t where k = 'pa5')), '42501', 'payout account refused: court_appointed',
  'after the liquidation, the client''s administrator confirms no IBAN, even of its own kind');
select throws_ok(format($$ select public.reject_payout_account('payout-rej-0040', %L, 'non') $$,
  (select v from t where k = 'pa5')), '42501', 'payout account refused: court_appointed', 'refuses none');
select throws_ok(format($$ select public.retire_payout_account('payout-ret-0040', %L, 'non') $$,
  (select v from t where k = 'pa4')), '42501', 'payout account refused: court_appointed', 'and retires none');
reset role;
select is((select status from public.client_payout_account where id = (select v from t where k = 'pa5')), 'proposed',
  'the proposal waits for the servicer');
select pg_temp.as_user('04');
set local role authenticated;
select is(public.reject_payout_account('payout-rej-0041', (select v from t where k = 'pa5'), 'Le liquidateur a son compte')
          ->> 'status', 'rejected', 'money staff decide it');
reset role;

-- The gate stops on the client's recorded events, each named with its date (C. civ. 2003; liquidation: product choice)
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000a1', private.paris_today()),
  array['client_in_liquidation:2026-11-02'], 'P1: its client is in liquidation since 2 November');
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000a1', '2026-11-01'), '{}'::text[],
  'not on a day before the event');
select is(private.complete_batch_confirmation('30000000-0000-0000-0000-000000000004'), 'not_ready',
  'the job checks the events again: the batch requested before the liquidation is not confirmed');
select is((select array[status, failed_job ->> 'error', failed_job ->> 'blockers'] from public.boarding_batch
           where id = '30000000-0000-0000-0000-000000000004'),
  array['committed', 'not_ready', '["client_in_liquidation:2026-11-02"]'], 'back to committed with the event and its date');
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.confirm_boarding_batch('30000000-0000-0000-0000-000000000004') $$, '23514',
  'the portfolio is not ready for confirmation: client_in_liquidation:2026-11-02', 'nor requested again');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select lives_ok($$ select public.record_client_status_event('event-0010', '00000000-0000-0000-0000-0000000000a2',
  'proceeding_opened', '2026-11-03', pg_temp.d('09'), null) $$, 'a2: a proceeding opened');
reset role;
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000a3', private.paris_today()),
  array['commission_schedule_missing', 'commission_clause_missing', 'remittance_terms_missing', 'remittance_clause_missing',
        'terms_document_missing', 'client_not_professional', 'client_not_mainland_france'],
  'a proceeding opened does not stop the gate (servicing goes on, design §13 #9)');
select pg_temp.as_user('04');
set local role authenticated;
select lives_ok($$ select public.record_client_status_event('event-0011', '00000000-0000-0000-0000-0000000000a2',
  'mandate_ended', '2026-11-05', pg_temp.d('09'), null) $$, 'the mandate ended');
select lives_ok($$ select public.record_client_status_event('event-0012', '00000000-0000-0000-0000-0000000000a2',
  'guardianship', '2026-11-04', pg_temp.d('09'), null) $$, 'a guardianship');
select lives_ok($$ select public.record_client_status_event('event-0013', '00000000-0000-0000-0000-0000000000a2',
  'death', '2026-11-06', pg_temp.d('09'), null) $$, 'a death');
reset role;
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000a3', private.paris_today()),
  array['client_mandate_ended:2026-11-04', 'client_deceased:2026-11-06', 'commission_schedule_missing',
        'commission_clause_missing', 'remittance_terms_missing', 'remittance_clause_missing', 'terms_document_missing',
        'client_not_professional', 'client_not_mainland_france'],
  'P3: the mandate ended (the earliest of its end and the guardianship), the death; then the other reasons');
select is(private.portfolio_confirmation_blockers('20000000-0000-0000-0000-0000000000a3', '2026-11-05'),
  array['client_mandate_ended:2026-11-04', 'commission_schedule_missing', 'commission_clause_missing',
        'remittance_terms_missing', 'remittance_clause_missing', 'terms_document_missing', 'client_not_professional',
        'client_not_mainland_france'], 'each event from its date');

-- A credit from a client's IBAN released as a debtor payment the client relays --------------------------------------
insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                   size_bytes, storage_path)
values ('e2000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
        'EUR', 'camt053', 'r.xml', repeat('c', 64), 1, 'test/e2');
update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = 'e2000000-0000-0000-0000-000000000001';
insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                     amount_minor, currency, booking_date, kind, end_to_end_id, counterparty_iban,
                                     counterparty_name, remittance_text)
values ('e2100000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
        'e2000000-0000-0000-0000-000000000001', 1, 't:CL1', 'credit', 2500, 'EUR', '2026-11-06', 'client_transfer_in',
        'E2E-CL1', 'FR7642606140114176606002310', 'MARTIN SAS', 'REGLEMENT DUPONT DOSSIER 12'),
       ('e2100000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf',
        'e2000000-0000-0000-0000-000000000001', 2, 't:CL2', 'credit', 900, 'EUR', '2026-11-06', 'debtor_credit',
        'E2E-CL2', 'FR7616693172992875188907588', 'M. DURAND', null);
select pg_temp.as_user('01');
set local role authenticated;
select is((select count(*)::int from public.debit_queue('a-classer', 0, 100) q
           where q.bank_transaction_id = 'e2100000-0000-0000-0000-000000000001'), 1,
  'a credit from a client''s IBAN waits in « À classer »');
select throws_ok($$ select public.release_own_credit('release-cl-0001', 'e2100000-0000-0000-0000-000000000001', ' ') $$,
  '23514', 'own credit release refused: reason_required', 'its release needs a motif');
select throws_ok($$ select public.release_own_credit('release-cl-0002', 'e2100000-0000-0000-0000-000000000002', 'x') $$,
  '23514', 'own credit release refused: not_own_credit', 'a debtor''s credit is not released (it is a payment already)');
insert into t select 'relay_cl', (public.release_own_credit('release-cl-0003', 'e2100000-0000-0000-0000-000000000001',
  'Martin SAS nous reverse le paiement de M. Dupont') ->> 'payment_id')::uuid;
select is(public.release_own_credit('release-cl-0003', 'e2100000-0000-0000-0000-000000000001',
  'Martin SAS nous reverse le paiement de M. Dupont'),
  jsonb_build_object('payment_id', (select v from t where k = 'relay_cl'), 'status', 'unmatched'),
  'ops release it as a debtor payment the client relays (a replay returns the same)');
select throws_ok($$ select public.release_own_credit('release-cl-0004', 'e2100000-0000-0000-0000-000000000001', 'encore') $$,
  '23514', 'own credit release refused: already_booked', 'once');
select is((select count(*)::int from public.debit_queue('a-classer', 0, 100) q
           where q.bank_transaction_id = 'e2100000-0000-0000-0000-000000000001'), 0, 'it leaves « À classer »');
reset role;
select is((select array[p.status, p.review_reason, p.payer_name, coalesce(p.payer_iban, '-'), p.amount_minor::text,
                        p.booking_date::text, p.method, p.remittance_text]
           from public.payment p where p.id = (select v from t where k = 'relay_cl')),
  array['unmatched', 'no_match', 'Versement relayé par le client', '-', '2500', '2026-11-06', 'other',
        'REGLEMENT DUPONT DOSSIER 12'],
  'a payment of the dedicated account, for ops to assign; never the client''s IBAN as payer');
select is((select count(*)::int from public.bank_own_credit_release
           where bank_transaction_id = 'e2100000-0000-0000-0000-000000000001'), 1, 'ops'' decision and motif kept');

-- « Nouvel IBAN »: until a payout of that client to that IBAN is booked and not returned (founder #10) ------------------
create or replace function pg_temp.entry(p_key text) returns uuid language plpgsql as $$
declare v uuid;
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, '00000000-0000-0000-0000-0000000000aa', 'cash_in', '2026-11-06', p_key, 'bank_statement',
          'e2000000-0000-0000-0000-000000000001');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', 100, 'EUR', '80000000-0000-0000-0000-0000000000cf'),
    (1, 2, 'unallocated_payment', -100, 'EUR', null);
  select r.entry_id into v from private.ledger_post_set() r;
  return v;
end $$;
create or replace function pg_temp.payout(p_e2e text, p_client text, p_iban text) returns uuid language sql as $$
  insert into public.bank_transfer (organization_id, client_organization_id, kind, debtor_bank_account_id, currency,
                                    amount_minor, payee_name, payee_iban, end_to_end_id, requested_execution_date)
  values ('00000000-0000-0000-0000-0000000000aa', ('00000000-0000-0000-0000-0000000000' || p_client)::uuid, 'payout',
          '80000000-0000-0000-0000-0000000000cf', 'EUR', 100, 'PAYEE', p_iban, p_e2e, '2026-11-09')
  returning id;
$$;
select throws_ok($$ insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, currency, amount_minor,
  payee_name, payee_iban, end_to_end_id, requested_execution_date) values ('00000000-0000-0000-0000-0000000000aa', 'payout',
  '80000000-0000-0000-0000-0000000000cf', 'EUR', 100, 'X', 'FR7663953752338647431575659', 'RMT0000000000F1', '2026-11-09') $$,
  '23514', null, 'a payout names its client');
select throws_ok($$ select pg_temp.payout('RMT0000000000F2', 'b1', 'FR7663953752338647431575659') $$, '23514',
  'bank transfer: a payout goes to a client of the servicer', 'a client of the servicer');
-- a1: a payout booked to pa2's IBAN; one to pa1's that came back; a2: one booked to pa4's IBAN (another client's)
insert into t values ('t1', pg_temp.payout('RMT0000000000A1', 'a1', 'FR7663953752338647431575659')),
                     ('t2', pg_temp.payout('RMT0000000000A2', 'a1', 'FR7642606140114176606002310')),
                     ('t3', pg_temp.payout('RMT0000000000A3', 'a2', 'FR7643625512382429355294717')),
                     ('e1', pg_temp.entry('payout:t1')), ('e2', pg_temp.entry('payout:t2')),
                     ('e2r', pg_temp.entry('payout:t2r')), ('e3', pg_temp.entry('payout:t3'));
update public.bank_transfer x set status = 'booked', entry_id = e.v
from t p join t e on e.k = 'e' || substr(p.k, 2) where p.k in ('t1', 't2', 't3') and x.id = p.v;
update public.bank_transfer set status = 'returned', return_entry_id = (select v from t where k = 'e2r')
where id = (select v from t where k = 't2');
select is((select count(*)::int from public.bank_transfer where kind = 'payout' and status = 'booked'), 2,
  'two payouts booked, one returned');
select throws_ok($$ update public.bank_transfer set client_organization_id = '00000000-0000-0000-0000-0000000000a2'
  where end_to_end_id = 'RMT0000000000A1' $$, '23514', null, 'the client of a payout never changes');
select pg_temp.as_user('01');
set local role authenticated;
select is((select array_agg(iban_last4 || ':' || status || ':' || paid_before order by iban_last4)
           from public.payout_accounts('00000000-0000-0000-0000-0000000000a1')),
  array['2310:retired:false', '4717:active:false', '5659:retired:true', '6874:rejected:false'],
  'paid before: the IBAN a payout of that client was booked to; not the one whose payout came back, nor one only '
  'another client''s payout went to');
reset role;

-- The import's classification joins the lines with the clients' IBANs once (plan robustness, review fix) --------------
create temp table _bi_stage (line_no integer primary key, kind text, direction text, end_to_end_id text,
                             counterparty_iban text) on commit drop;
insert into _bi_stage
select g, 'debtor_credit', 'credit', 'E2E-' || g,
       case g % 4 when 0 then 'FR7642606140114176606002310'      -- a1's, retired: still the client's
                  when 1 then 'FR7611790967787158343046874'      -- a proposal refused: never confirmed
                  when 2 then 'FR7623754538827637495136203'      -- our own account
                  else 'FR7616693172992875188907588' end         -- a debtor's
from generate_series(1, 4000) g;
analyze _bi_stage;
create temp table _mark_cpa (seq_scan bigint, idx_scan bigint);
insert into _mark_cpa select x.seq_scan, x.idx_scan from pg_stat_xact_user_tables x
where x.relid = 'public.client_payout_account'::regclass;
create temp table _refined as
select * from private.stage_refined_kinds('00000000-0000-0000-0000-0000000000aa', array['FR7623754538827637495136203']);
select is((select array_agg(k.kind || ':' || k.n order by k.kind)
           from (select r.kind, count(*) as n from _refined r group by r.kind) k),
  array['client_transfer_in:1000', 'own_transfer_in:1000'],
  'the lines from a client''s confirmed IBAN are the client''s, from our own IBAN ours; the others unchanged');
select is((select (x.seq_scan + x.idx_scan) - (m.seq_scan + m.idx_scan) from pg_stat_xact_user_tables x, _mark_cpa m
           where x.relid = 'public.client_payout_account'::regclass), 1::bigint,
  'the clients'' IBANs are read once for the 4 000 lines (one join), never per line');
drop table _bi_stage;

select is((select array_agg(indexname::text order by indexname) from pg_indexes
           where indexname in ('document_client_kind_idx', 'bank_transfer_payout_iban_idx')),
  array['bank_transfer_payout_iban_idx', 'document_client_kind_idx'],
  'a client''s documents by kind, and the payouts of a client by IBAN, are indexed');

-- The receipt issuer block (R123-237 1°–4°, 9°; R123-238) -----------------------------------------------------
select is(private.receipt_issuer('00000000-0000-0000-0000-0000000000aa'),
  jsonb_build_object('name', 'Collectoo', 'siren', '849678297', 'legal_form', 'SAS', 'share_capital_minor', '1000000',
                     'currency', 'EUR', 'rcs_city', 'Paris', 'registered_office', (select v from j where k = 'office'),
                     'in_liquidation', false, 'entrepreneur_individuel', false),
  'receipts carry the servicer''s SIREN, RCS city, registered office, legal form and capital');
select is(private.receipt_issuer('00000000-0000-0000-0000-0000000000bb'), '{"name": "Autre cabinet"}'::jsonb,
  'a servicer without identity: its name only (as before M2c-2)');

-- Privileges ------------------------------------------------------------------------------------------------
select is((select array_agg(p order by p) from (
  select p from unnest(array['public.billing_identity', 'public.servicer_billing_settings', 'public.client_payout_account',
                             'public.client_status_event']) p
  where has_table_privilege('authenticated', p, 'INSERT') or has_table_privilege('authenticated', p, 'UPDATE')
     or has_table_privilege('authenticated', p, 'DELETE') or has_table_privilege('anon', p, 'SELECT')) x),
  null, 'no direct write by the API''s roles, no read by anon');
select is((select array_agg(c.relname order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relname in ('billing_identity', 'servicer_billing_settings',
                                                        'client_payout_account', 'client_status_event')
             and c.relrowsecurity),
  array['billing_identity', 'client_payout_account', 'client_status_event', 'servicer_billing_settings']::name[],
  'RLS on every new table');
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('set_billing_identity', 'set_servicer_billing_settings',
             'register_client_document', 'propose_payout_account', 'confirm_payout_account', 'reject_payout_account',
             'retire_payout_account', 'record_client_status_event', 'set_mandate_terms', 'set_mandate_insurance_clause')
             and p.prosecdef and p.proconfig @> array['search_path=""']
             and not has_function_privilege('anon', p.oid, 'EXECUTE')),
  array['confirm_payout_account', 'propose_payout_account', 'record_client_status_event', 'register_client_document',
        'reject_payout_account', 'retire_payout_account', 'set_billing_identity', 'set_mandate_insurance_clause',
        'set_mandate_terms', 'set_servicer_billing_settings'],
  'the commands are SECURITY DEFINER with an empty search path, not executable by anon');

select * from finish();
rollback;
