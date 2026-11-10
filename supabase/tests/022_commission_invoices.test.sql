-- M2c-4 (M2-15 numbering): commission invoices and credit notes, issued by private.issue_commission_documents (the
-- approval's and the cancellation's). One gapless yearly series per servicer for invoices and credit notes (founder #12),
-- the number from a counter row locked in the issuing transaction, the date read after it; the guard refusing a gap, a
-- date going back, a number the counter did not give, an entry not its own; a credit note naming its invoice, its VAT
-- off the pending VAT first, never crediting more than the invoice charged; the settlement sub-ledger (I18) and its
-- check; the read policies (clients A/B, a restricted viewer, a collector, another servicer). Design
-- docs/design/m2c-remittances.md §8.4, §14, §15, §18 M2-15; ADR-0014 M2c-4.
begin;
select plan(32);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS', '732829320'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Autre cabinet SAS', '732829320');
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Martin SAS',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Lilas Finance',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Bleu SARL',
   '552100554');
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@inv.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '07', '08']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a2', 'client_admin');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', 'P1'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'P2'),
  ('20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000b1', 'P3');
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a1');
insert into public.billing_identity (organization_id, legal_form, share_capital_minor, rcs_city, registered_office,
                                     vat_number, is_professional)
select o.id, case when o.kind = 'servicer' then 'SAS' end, case when o.kind = 'servicer' then 1000000 end,
       case when o.kind = 'servicer' then 'Paris' end,
       '{"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris", "country": "FR"}',
       case when o.kind = 'servicer'
            then 'FR' || lpad(((12 + 3 * (o.siren::bigint % 97)) % 97)::text, 2, '0') || o.siren end, true
from public.organization o where o.id::text like '00000000-0000-0000-0000-0000000000%'
  and o.id in ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000bb',
               '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2',
               '00000000-0000-0000-0000-0000000000b1');
insert into public.servicer_billing_settings (organization_id, invoice_prefix)
values ('00000000-0000-0000-0000-0000000000aa', 'FA');
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on) values
  ('70000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
   'M-A1', 'mandate_amicable', '2026-01-01'),
  ('70000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
   'M-A2', 'mandate_amicable', '2026-01-01'),
  ('70000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000bb', '00000000-0000-0000-0000-0000000000b1',
   'M-B1', 'mandate_amicable', '2026-01-01');
insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                            legal_regime, currency, status)
select ('a1000000-0000-0000-0000-0000000000' || x.c)::uuid, ('00000000-0000-0000-0000-0000000000' || x.s)::uuid,
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, ('20000000-0000-0000-0000-0000000000' || x.c)::uuid,
       'b2b_invoice', 'D-' || x.c, 'commercial_b2b', 'EUR', 'in_collection'
from (values ('a1', 'aa'), ('a2', 'aa'), ('b1', 'bb')) x (c, s);

-- One document for a client: an invoice of `p_ht` HT at 20 % charging its file's key, or a credit note of `p_ht`
-- (negative) on invoice `p_of` (its VAT `p_vat`, split v1 / v2, applied / excess as given).
create or replace function pg_temp.doc(p_servicer text, p_client text, p_kind text, p_ht bigint, p_of uuid default null,
                                       p_vat bigint default null, p_v1 bigint default null, p_applied bigint default null)
returns jsonb language sql as $$
  select private.issue_commission_documents(('00000000-0000-0000-0000-0000000000' || p_servicer)::uuid,
    ('00000000-0000-0000-0000-0000000000' || p_client)::uuid, null, jsonb_build_array(
      case p_kind when 'invoice' then jsonb_build_object(
        'id', gen_random_uuid(), 'ref', 'x', 'key', 'test-inv-' || gen_random_uuid(), 'kind', 'invoice',
        'mandate_id', '70000000-0000-0000-0000-0000000000' || p_client, 'ht', p_ht::text,
        'vat', round(p_ht * 0.2)::bigint::text, 'ttc', (p_ht + round(p_ht * 0.2)::bigint)::text, 'vat_rate', '0.2',
        'settlement', 'netted',
        'lines', jsonb_build_array(jsonb_build_object('kind', 'commission', 'designation_fr', 'Commission (test)',
                                                      'ht', p_ht::text, 'vat_rate', '0.2')),
        'charges', jsonb_build_array(jsonb_build_object('account_id', 'a1000000-0000-0000-0000-0000000000' || p_client,
                                                        'tier_key', 'k', 'amount', p_ht::text)))
      else jsonb_build_object(
        'id', gen_random_uuid(), 'ref', 'y', 'key', 'test-crn-' || gen_random_uuid(), 'kind', 'credit_note',
        'mandate_id', '70000000-0000-0000-0000-0000000000' || p_client, 'ht', p_ht::text, 'vat', (-p_vat)::text,
        'ttc', (p_ht - p_vat)::text,
        'lines', jsonb_build_array(jsonb_build_object('kind', 'credit', 'designation_fr', 'Avoir (test)',
                                                      'ht', p_ht::text, 'vat_rate', '0.2', 'original_invoice_id', p_of)),
        'allocations', jsonb_build_array(jsonb_build_object('original_invoice_id', p_of,
                                                            'account_id', 'a1000000-0000-0000-0000-0000000000' || p_client,
                                                            'tier_key', 'k', 'ht', p_ht::text)),
        'corrections', jsonb_build_array(jsonb_build_object('original_invoice_id', p_of, 'vat_rate', '0.2',
                                                            'ht', p_ht::text, 'vat', (-p_vat)::text,
                                                            'vat_pending', p_v1::text, 'vat_collected', (p_vat - p_v1)::text,
                                                            'applied', p_applied::text,
                                                            'excess', (-p_ht + p_vat - p_applied)::text))) end),
    'commission');
$$;
create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
grant execute on all functions in schema pg_temp to authenticated;
create temporary table t (k text primary key, v uuid) on commit drop;
grant all on t to authenticated;

-- The series ---------------------------------------------------------------------------------------
select is(pg_temp.doc('aa', 'a1', 'invoice', 10000) #>> '{documents,x,number}',
  'FA-' || extract(year from private.paris_today()) || '-000001', 'the servicer''s first number: its prefix, the year, 1');
insert into t select 'i1', id from public.commission_invoice where number = 'FA-' || extract(year from private.paris_today()) || '-000001';
select is(pg_temp.doc('bb', 'b1', 'invoice', 5000) #>> '{documents,x,number}',
  'FC-' || extract(year from private.paris_today()) || '-000001', 'another servicer has its own series (default FC)');
select is(pg_temp.doc('aa', 'a2', 'invoice', 20000) #>> '{documents,x,number}',
  'FA-' || extract(year from private.paris_today()) || '-000002', 'one series across the servicer''s clients');
select results_eq($$ select series, year, last_seq, last_issue_date from private.invoice_counter
                     where organization_id = '00000000-0000-0000-0000-0000000000aa' $$,
  $$ values ('FA'::text, extract(year from private.paris_today())::integer, 2, private.paris_today()) $$,
  'the counter of the year at the last number, dated');
select results_eq($$ select ht_minor, vat_minor, ttc_minor, vat_book, issue_date from public.commission_invoice
                     where id = (select v from t where k = 'i1') $$,
  $$ values (10000::bigint, 2000::bigint, 12000::bigint, 'vat_pending'::text, private.paris_today()) $$,
  'TTC = HT + VAT, the VAT pending (VAT on encaissements), dated today');

-- The guard -----------------------------------------------------------------------------------------
select throws_ok($$ insert into public.commission_invoice (id, organization_id, client_organization_id, mandate_id, kind,
                      series, year, seq, number, issue_date, currency, ht_minor, vat_rate, vat_minor, ttc_minor, vat_book,
                      settlement, reason, payload, payload_sha256, ledger_entry_id)
                    select gen_random_uuid(), organization_id, client_organization_id, mandate_id, kind, series, year,
                           4, series || '-' || year || '-000004', issue_date, currency, ht_minor, vat_rate, vat_minor,
                           ttc_minor, vat_book, settlement, reason, payload, payload_sha256, ledger_entry_id
                    from public.commission_invoice where id = (select v from t where k = 'i1') $$,
  '23514', null, 'a gap is refused');
select throws_ok($$ insert into public.commission_invoice (id, organization_id, client_organization_id, mandate_id, kind,
                      series, year, seq, number, issue_date, currency, ht_minor, vat_rate, vat_minor, ttc_minor, vat_book,
                      settlement, reason, payload, payload_sha256, ledger_entry_id)
                    select gen_random_uuid(), organization_id, client_organization_id, mandate_id, kind, series, year,
                           3, series || '-' || year || '-000003', issue_date, currency, ht_minor, vat_rate, vat_minor,
                           ttc_minor, vat_book, settlement, reason, payload, payload_sha256, ledger_entry_id
                    from public.commission_invoice where id = (select v from t where k = 'i1') $$,
  '23514', null, 'the next number, but one the counter did not give, is refused');
update private.invoice_counter set last_seq = 3 where organization_id = '00000000-0000-0000-0000-0000000000aa';
select throws_ok($$ insert into public.commission_invoice (id, organization_id, client_organization_id, mandate_id, kind,
                      series, year, seq, number, issue_date, currency, ht_minor, vat_rate, vat_minor, ttc_minor, vat_book,
                      settlement, reason, payload, payload_sha256, ledger_entry_id)
                    select gen_random_uuid(), organization_id, client_organization_id, mandate_id, kind, series, year,
                           3, series || '-' || year || '-000003', issue_date, currency, ht_minor, vat_rate, vat_minor,
                           ttc_minor, vat_book, settlement, reason, payload, payload_sha256, ledger_entry_id
                    from public.commission_invoice where id = (select v from t where k = 'i1') $$,
  '23514', 'commission invoice FA-' || extract(year from private.paris_today()) || '-000003: its entry is its own (type, document, date, client)',
  'nor a document on another''s entry');
select throws_ok($$ insert into public.commission_invoice (id, organization_id, client_organization_id, mandate_id, kind,
                      series, year, seq, number, issue_date, currency, ht_minor, vat_rate, vat_minor, ttc_minor, vat_book,
                      settlement, reason, payload, payload_sha256, ledger_entry_id)
                    select gen_random_uuid(), organization_id, client_organization_id, mandate_id, kind, series, year,
                           3, series || '-' || year || '-000003', issue_date - 1, currency, ht_minor, vat_rate, vat_minor,
                           ttc_minor, vat_book, settlement, reason, payload, payload_sha256,
                           (select e.id from public.ledger_entry e where e.entry_type = 'commission_invoice'
                              and e.source_id <> (select v from t where k = 'i1')::text
                              and e.organization_id = '00000000-0000-0000-0000-0000000000aa' limit 1)
                    from public.commission_invoice where id = (select v from t where k = 'i1') $$,
  '23514', null, 'a date before the previous number''s is refused');
update private.invoice_counter set last_seq = 2 where organization_id = '00000000-0000-0000-0000-0000000000aa';
select throws_ok($$ update public.commission_invoice set number = 'X' where id = (select v from t where k = 'i1') $$,
  '23514', null, 'a document never changes');
select throws_ok($$ delete from public.commission_invoice_line where invoice_id = (select v from t where k = 'i1') $$,
  '23514', null, 'nor its lines');
-- a rolled-back issue leaves no gap
savepoint s1;
select pg_temp.doc('aa', 'a1', 'invoice', 1000);
rollback to savepoint s1;
select is((select last_seq from private.invoice_counter where organization_id = '00000000-0000-0000-0000-0000000000aa'),
  2, 'an issue rolled back takes its number back (the counter row in the issuing transaction)');

-- Credit notes ---------------------------------------------------------------------------------------
select throws_ok($$ select pg_temp.doc('aa', 'a1', 'credit_note', -12000, (select v from t where k = 'i1'), 2400, 2400, 14400) $$,
  '23514', 'commission credit note: more credited than the invoice charged', 'never more than the invoice charged');
select throws_ok($$ select pg_temp.doc('aa', 'a1', 'credit_note', -4000, (select v from t where k = 'i1'), 800, 900, 4800) $$,
  '23514', null, 'its VAT split adds up to its VAT');
select is(pg_temp.doc('aa', 'a1', 'credit_note', -4000, (select v from t where k = 'i1'), 800, 800, 4800)
          #>> '{documents,y,number}',
  'FA-' || extract(year from private.paris_today()) || '-000003', 'a credit note takes the series'' next number');
insert into t select 'c1', id from public.commission_invoice where number = 'FA-' || extract(year from private.paris_today()) || '-000003';
select results_eq($$ select kind, ht_minor, vat_minor, ttc_minor, vat_rate from public.commission_invoice
                     where id = (select v from t where k = 'c1') $$,
  $$ values ('credit_note'::text, -4000::bigint, -800::bigint, -4800::bigint, null::numeric) $$,
  'negative amounts, each corrected invoice''s rate on its correction');
select results_eq($$ select l.original_invoice_id, l.kind from public.commission_invoice_line l
                     where l.invoice_id = (select v from t where k = 'c1') $$,
  $$ values ((select v from t where k = 'i1'), 'credit'::text) $$,
  'its line names the invoice it corrects (289 I 5)');
select results_eq($$ select la.book, p.amount_minor from public.commission_invoice i
                     join public.ledger_posting p on p.entry_id = i.ledger_entry_id
                     join public.ledger_account la on la.id = p.ledger_account_id
                     where i.id = (select v from t where k = 'c1') order by p.line_no $$,
  $$ values ('commission_receivable'::text, -4800::bigint), ('servicer_revenue', 4000::bigint),
            ('vat_pending', 800::bigint) $$,
  'its entry: −4111 TTC / +7060 HT / +44574 (the pending VAT first)');
select results_eq($$ select kind, amount_minor, vat_moved_minor from public.commission_settlement
                     where credit_note_id = (select v from t where k = 'c1') $$,
  $$ values ('credit_note'::text, 4800::bigint, 800::bigint) $$,
  'it reduces the invoice it corrects at once (a price correction)');
select is(private.document_open((select v from t where k = 'i1')), 7200::bigint, 'the invoice open for 7 200');
select is(private.document_pending_vat((select v from t where k = 'i1')), 1200::bigint, 'its pending VAT 1 200');
select is(private.document_open((select v from t where k = 'c1')), 0::bigint, 'no refund owed (all applied)');
-- a second credit note crediting what remains, beyond the invoice's open part: the excess is a refund owed
select is(pg_temp.doc('aa', 'a1', 'credit_note', -6000, (select v from t where k = 'i1'), 1200, 1200, 7200)
          #>> '{documents,y,number}', 'FA-' || extract(year from private.paris_today()) || '-000004',
  'the rest of the invoice credited');
select is(private.document_open((select v from t where k = 'i1')), 0::bigint, 'the invoice closed');

-- The settlement sub-ledger check (I18) --------------------------------------------------------------
insert into t select 'chk1', (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
select is((select count(*)::int from public.payment_check_result r
           where r.run_id = (select v from t where k = 'chk1')
             and r.severity = 'violation' and r.code in ('settlement_ledger', 'vat_pending_ledger', 'invoice_numbering',
                                                         'invoice_ledger')), 0,
  'documents = 4111 per client, pending VAT = 44574, numbers and entries hold');
insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id, kind,
                                          amount_minor, settled_on)
select '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'invoice', id, 'compensation',
       100, private.paris_today()
from public.commission_invoice where client_organization_id = '00000000-0000-0000-0000-0000000000a2';
insert into t select 'chk2', (private.run_payment_checks('00000000-0000-0000-0000-0000000000aa') ->> 'run_id')::uuid;
select is((select string_agg(r.code, ',') from public.payment_check_result r
           where r.run_id = (select v from t where k = 'chk2') and r.severity = 'violation'),
  'settlement_ledger', 'a settlement the ledger does not show is found');

-- Read policies ------------------------------------------------------------------------------------
select pg_temp.as_user('03');
set local role authenticated;
select is((select count(*)::int from public.commission_invoice), 3, 'Martin''s admin reads its invoice and credit notes');
select is((select count(*)::int from public.commission_invoice_line) + (select count(*)::int
                                                                         from public.commission_credit_correction), 5,
  'their lines and corrections');
select is((select count(*)::int from public.commission_invoice_charge) + (select count(*)::int
                                                                           from public.commission_credit_alloc), 0,
  'not the per-file charges (the servicer''s history)');
select pg_temp.as_user('08');
select is((select string_agg(number, ',') from public.commission_invoice),
  'FA-' || extract(year from private.paris_today()) || '-000002', 'Lilas''s admin reads only its own');
select pg_temp.as_user('07');
select is((select count(*)::int from public.commission_invoice), 0, 'a restricted viewer reads none');
select pg_temp.as_user('02');
select is((select count(*)::int from public.commission_invoice) + (select count(*)::int
                                                                    from public.commission_settlement), 0,
  'nor a collector');
reset role;

select * from finish();
rollback;
