-- M2b-5 (M2-10, M2-11): receipts (R124-6) and the client payment feed (R124-5). Design docs/design/m2b-payments.md
-- §6, §10, §13; ADR-0013 (M2b-5 addendum). The worker's receipts job is played here: private.receipt_begin, then
-- private.receipt_prepare, then the rendered PDFs' hashes written into pg_temp._receipt_pdf, then private.receipt_issue.
begin;
select plan(79);

-- Fixtures --------------------------------------------------------------------------------------
insert into public.organization (id, kind, legal_name) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Other servicer');
insert into public.organization (id, kind, servicer_organization_id, legal_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Martin SAS'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Lilas Finance'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Client B1');
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@receipts.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '06']) n;
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000a2', 'client_admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000a1', 'client_viewer');
insert into public.portfolio (id, organization_id, client_organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', 'P1'),
  ('20000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', 'P1bis'),
  ('20000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2', 'P2');
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a3'),  -- the collector works P1bis only
  ('10000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-0000000000a3');  -- this client user reads P1bis only
insert into public.bank_account (id, organization_id, iban, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000aa', 'FR3430001007940000000001001', 'EUR',
   'Fonds de tiers', 'camt053', '2026-01-01');

create or replace function pg_temp.f(p_n text) returns uuid language sql as $$
  select ('a1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.it(p_n text, p_i text) returns uuid language sql as $$
  select ('c1000000-0000-0000-0000-000000000' || p_n || p_i)::uuid;
$$;
create or replace function pg_temp.pay(p_n text) returns uuid language sql as $$
  select ('f1000000-0000-0000-0000-0000000000' || p_n)::uuid;
$$;
create or replace function pg_temp.file(p_n text, p_portfolio uuid, p_name text) returns void language sql as $$
  insert into public.account (id, organization_id, client_organization_id, portfolio_id, claim_type_code, external_ref,
                              legal_regime, currency, status)
  select pg_temp.f(p_n), p.organization_id, p.client_organization_id, p.id, 'b2b_invoice', 'D-' || p_n,
         'commercial_b2b', 'EUR', 'in_collection'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.claim_ownership_period (account_id, owner_organization_id, servicer_organization_id, mandate_type,
                                             valid_from)
  select pg_temp.f(p_n), p.client_organization_id, p.organization_id, 'mandate_amicable', '2026-09-30'
  from public.portfolio p where p.id = p_portfolio;
  insert into public.party (id, organization_id, client_organization_id, kind, display_name)
  select ('b1000000-0000-0000-0000-0000000000' || p_n)::uuid, p.organization_id, p.client_organization_id,
         'legal_entity', p_name
  from public.portfolio p where p.id = p_portfolio;
  insert into public.account_party (account_id, party_id, role, capacity)
  values (pg_temp.f(p_n), ('b1000000-0000-0000-0000-0000000000' || p_n)::uuid, 'borrower', 'legal_entity');
$$;
create or replace function pg_temp.item(p_n text, p_i text, p_due date, p_amount bigint) returns void language sql as $$
  insert into public.claim_item (id, account_id, kind, ref, due_date, original_minor)
  values (pg_temp.it(p_n, p_i), pg_temp.f(p_n), 'invoice', 'F-' || p_n || p_i, p_due, p_amount);
  select entry_id from private.ledger_post(
    '00000000-0000-0000-0000-0000000000aa', 'adjustment', '2026-09-30', 'rcpt-owe-' || p_n || p_i,
    jsonb_build_array(
      jsonb_build_object('book', 'debtor_receivable', 'amount_minor', p_amount, 'currency', 'EUR',
                         'claim_item_id', pg_temp.it(p_n, p_i), 'component', 'principal'),
      jsonb_build_object('book', 'owner_claim', 'amount_minor', -p_amount, 'currency', 'EUR', 'component', 'principal')),
    jsonb_build_object('account_id', pg_temp.f(p_n), 'reason', 'ouverture (test)'));
$$;
-- A credit line of an imported statement and its payment (booked 2026-10-05 + p_day days).
create or replace function pg_temp.payment(p_n text, p_amount bigint, p_payer text, p_day integer default 0)
returns void language plpgsql as $$
declare s uuid := ('e1000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000aa', 'EUR', 'camt053', 'r.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (id, organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000aa', s, 1, 't:' || s, 'credit',
          p_amount, 'EUR', '2026-10-05'::date + p_day, 'debtor_credit');
  insert into public.payment (id, organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, value_date, payer_name, end_to_end_id)
  values (pg_temp.pay(p_n), '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000aa', s,
          'camt053', 'sct', p_amount, 'EUR', '2026-10-05'::date + p_day, '2026-10-05'::date + p_day, p_payer,
          'E2E-' || p_n);
end $$;
create or replace function pg_temp.match(p_n text, p_file text, p_reason text default null) returns void language sql as $$
  update public.payment set account_id = pg_temp.f(p_file), status = 'matched', match_method = 'rf_structured',
                            matched_at = now(), review_reason = p_reason
  where id = pg_temp.pay(p_n);
$$;
create or replace function pg_temp.allocate(p_n text, p_file text, p_lines jsonb) returns jsonb language plpgsql as $$
begin
  perform private.allocation_begin();
  insert into pg_temp._alloc_target (payment_id, ord, account_id, outcome, effective_date, policy, inputs_hash)
  values (pg_temp.pay(p_n), 1, pg_temp.f(p_file), 'allocate',
          (select booking_date from public.payment where id = pg_temp.pay(p_n)),
          '{"accessory_rank": "before_principal", "unclassified": "last"}', repeat('0', 64));
  insert into pg_temp._alloc_line (payment_id, seq, claim_item_id, component, amount_minor)
  select pg_temp.pay(p_n), x.ord::integer, pg_temp.it(p_file, x.l ->> 0), 'principal', (x.l ->> 1)::bigint
  from jsonb_array_elements(p_lines) with ordinality as x (l, ord);
  return private.post_allocations('00000000-0000-0000-0000-0000000000aa', 'ready', 'alloc-1');
end $$;
create or replace function pg_temp.as_user(p_user text, p_aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', '10000000-0000-0000-0000-0000000000' || p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
-- The receipts job, played: prepare, "render" (a hash per receipt), issue. Returns how many were issued.
create or replace function pg_temp.receipts(variadic p_payments text[]) returns integer language plpgsql as $$
begin
  perform private.receipt_begin();
  perform private.receipt_prepare('00000000-0000-0000-0000-0000000000aa',
                                  array(select pg_temp.pay(x) from unnest(p_payments) x));
  insert into pg_temp._receipt_pdf (payment_id, pdf_sha256)
  select r.payment_id, encode(sha256(convert_to(r.payment_id || ':' || r.version, 'UTF8')), 'hex')
  from pg_temp._receipt_new r;
  return private.receipt_issue('quittance-fr-1', 'test-renderer');
end $$;
create or replace function pg_temp.queued(p_n text) returns integer language sql as $$
  select count(*)::integer from pgmq.q_payments
  where message ->> 'type' = 'receipts' and message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000aa'
    and message -> 'payment_ids' ? pg_temp.pay(p_n)::text;
$$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 'Durand SA');
select pg_temp.item('01', '1', '2026-08-01', 50000);
select pg_temp.item('01', '2', '2026-09-01', 30000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 'Jean-Pierre Lilas');
select pg_temp.item('02', '1', '2026-08-01', 40000);
select pg_temp.file('03', '20000000-0000-0000-0000-0000000000a3', 'Bloqué SARL');
select pg_temp.item('03', '1', '2026-08-01', 10000);
select pg_temp.file('04', '20000000-0000-0000-0000-0000000000a1', 'Autre SA');
select pg_temp.item('04', '1', '2026-08-01', 10000);
insert into public.document (id, organization_id, client_organization_id, account_id, kind, storage_path, sha256, mime_type)
values ('d1000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
        pg_temp.f('03'), 'evidence', 'test/rcpt-jugement.pdf', repeat('a', 64), 'application/pdf');
insert into public.account_hold (organization_id, client_organization_id, portfolio_id, account_id, kind, scope,
                                 evidence_document_id, reason)
values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a3',
        pg_temp.f('03'), 'surendettement', array['outbound', 'payment_requests'], 'd1000000-0000-0000-0000-000000000003',
        'recevabilité');
select pg_temp.payment('01', 60000, 'DURAND S.A.');                     -- the debtor pays (a party: named)
select pg_temp.payment('02', 45000, 'M OU MME LILAS JEAN-PIERRE ET MARIE', 1);  -- a joint account: someone else too
select pg_temp.payment('03', 5000, 'SOC GENERALE POUR BLOQUE', 2);      -- held file, a third party
select pg_temp.payment('04', 7000, null, 3);                            -- matched, ready (allocation follows)
select pg_temp.payment('05', 1000, 'INCONNU', 4);                       -- never matched

-- Structure ---------------------------------------------------------------------------------------
select ok((select bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where (n.nspname, c.relname) in (('public', 'receipt'), ('private', 'receipt_counter'))),
  'RLS is on for the receipt tables');
select is((select count(*)::int from pg_policies where tablename in ('receipt', 'receipt_counter') and cmd <> 'SELECT'),
  0, 'read policies only: no user writes');
select is((select count(*)::int from pg_trigger
           where tgname in ('receipt_guard', 'receipt_append_only', 'ledger_entry_receipts', 'payment_receipts')
             and tgenabled = 'A'), 4, 'the receipt guards and the queueing triggers fire ALWAYS');
select ok(not has_function_privilege('authenticated', 'private.receipt_prepare(uuid, uuid[])', 'execute')
          and not has_function_privilege('authenticated', 'private.receipt_issue(text, text)', 'execute')
          and has_function_privilege('service_role', 'private.receipt_prepare(uuid, uuid[])', 'execute')
          and has_function_privilege('service_role', 'private.receipt_issue(text, text)', 'execute'),
  'only the worker issues receipts');
select ok(not has_function_privilege('anon', 'public.client_payment_feed(uuid, text, integer)', 'execute')
          and has_function_privilege('authenticated', 'public.client_payment_feed(uuid, text, integer)', 'execute'),
  'the feed is for signed-in users');
select ok(not has_function_privilege('authenticated', 'private.queue_receipt_backfill(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'private.receipt_payload(uuid)', 'execute'),
  'users cannot build payloads or queue receipts');
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname in ('public', 'private')
             and p.proname in ('receipt_payload', 'receipt_prepare', 'receipt_issue', 'queue_receipts',
                               'receipts_after_entry', 'receipts_after_payment', 'queue_receipt_backfill',
                               'client_payment_feed', 'can_read_receipt_object', 'receipt_guard')
             and pg_get_functiondef(p.oid) ~* 'not\s+in\s*\(\s*select'),
  null, 'no NOT IN over a subquery (anti-joins at any size)');
select ok(exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                  and policyname = 'receipt_object_read' and cmd = 'SELECT'),
  'receipt PDFs are read through a storage policy');
set local role authenticated;
select pg_temp.as_user('01');
select throws_ok($$insert into public.receipt (organization_id, client_organization_id, portfolio_id, account_id,
  payment_id, number, version, kind, payload, payload_sha256, template_version, renderer_version, known_at, document_id,
  pdf_sha256) values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
  '20000000-0000-0000-0000-0000000000a1', pg_temp.f('01'), pg_temp.pay('01'), 'Q-2026-000001', 1, 'original', '{}',
  repeat('0', 64), 'x', 'x', now(), 'd1000000-0000-0000-0000-000000000003', repeat('0', 64))$$,
  '42501', null, 'users cannot write receipts');
reset role;

-- The payer is named only when he is a party (founder #15) ----------------------------------------
select is(private.name_word_set('M. Jean-Pierre DUPONT'), array['DUPONT', 'JEAN', 'PIERRE'],
  'words: titles and initials dropped, accents and case folded');
select is(private.name_word_set('S.A.R.L. Les Jardins de l''Œuvre'), array['DE', 'JARDINS', 'OEUVRE'],
  'legal forms spelt out, joining words and elisions dropped, ligatures written out');
select is(private.name_word_set('M OU MME LILAS JEAN-PIERRE'), private.name_word_set('Jean-Pierre Lilas'),
  'the same person written by a bank');
select is(private.name_word_set('SAS'), '{}'::text[], 'a name of noise words only has no words');

-- Queueing (design §10: the job runs after any change of an identified payment) ---------------------
select pg_temp.match('01', '01');
select pg_temp.match('02', '02');
select pg_temp.match('03', '03', 'hold_blocks_allocation');
select pg_temp.match('04', '04');
select is(pg_temp.queued('04'), 0, 'a payment ready for allocation queues no receipt (its allocation will)');
select is(pg_temp.queued('03'), 1, 'a payment held on its file queues its receipt');
select pg_temp.allocate('01', '01', '[["1", 50000], ["2", 10000]]');
select is(pg_temp.queued('01'), 1, 'an allocation entry queues the receipt of its payment');
select pg_temp.allocate('02', '02', '[["1", 40000]]');
select is(private.queue_receipts((select jsonb_agg(jsonb_build_object(
             'organization_id', '00000000-0000-0000-0000-0000000000bb', 'payment_id', gen_random_uuid()))
           from generate_series(1, 450))), 3, '200 payments per job: 450 payments, 3 jobs');
select is((select array_agg(jsonb_array_length(message -> 'payment_ids') order by jsonb_array_length(message -> 'payment_ids'))
           from pgmq.q_payments where message ->> 'type' = 'receipts'
             and message ->> 'organization_id' = '00000000-0000-0000-0000-0000000000bb'), array[50, 200, 200],
  'each job names its payments');

-- The payload (design §10), from the ledger -------------------------------------------------------
create temp table _p as select pg_temp.pay(n) as payment_id, n, b.recipient_party_id, b.payload
from unnest(array['01', '02', '03']) n cross join lateral private.receipt_payload(pg_temp.pay(n)) b;
select is((select array[payload #>> '{issuer,name}', payload #>> '{creditor,name}', payload #>> '{file,reference}',
                        payload #>> '{debtor,name}'] from _p where n = '01'),
  array['Collectoo SAS', 'Martin SAS', 'D-01', 'Durand SA'],
  'issuer, acting for the client, the file and its debtor');
select is((select recipient_party_id from _p where n = '01'), 'b1000000-0000-0000-0000-000000000001'::uuid,
  'the receipt is for the file''s debtor (R124-6)');
select is((select payload -> 'payer' from _p where n = '01'), '{"name": "DURAND S.A.", "third_party": false}'::jsonb,
  'a payer who is a party is named as the bank gives him');
select is((select payload -> 'payer' from _p where n = '02'), '{"name": null, "third_party": true}'::jsonb,
  'a joint account naming someone else too is a third party: no name');
select is((select payload -> 'payer' from _p where n = '03'), '{"name": null, "third_party": true}'::jsonb,
  'a third party is never named (GDPR minimisation)');
select is((select payload -> 'payment' from _p where n = '01'),
  '{"amount_minor": "60000", "currency": "EUR", "exponent": 2, "method": "sct", "booking_date": "2026-10-05",
    "value_date": "2026-10-05", "reference": "E2E-01"}'::jsonb,
  'the payment as the bank reported it, the amount as text');
select is((select payload -> 'allocation' from _p where n = '01'),
  '[{"file_reference": "D-01", "item_ref": "F-011", "item_kind": "invoice", "due_date": "2026-08-01",
     "component": "principal", "component_label": "Principal", "amount_minor": "50000"},
    {"file_reference": "D-01", "item_ref": "F-012", "item_kind": "invoice", "due_date": "2026-09-01",
     "component": "principal", "component_label": "Principal", "amount_minor": "10000"}]'::jsonb,
  'the allocation per item and component, oldest due first');
select is((select payload -> 'totals' from _p where n = '01'),
  '{"allocated_minor": "60000", "forwarded_minor": "0", "returned_minor": "0", "unallocated_minor": "0"}'::jsonb,
  'totals from the ledger');
select is((select (payload #>> '{totals,allocated_minor}')::bigint from _p where n = '01'),
  (select -sum(lp.amount_minor)::bigint from public.ledger_entry e join public.ledger_posting lp on lp.entry_id = e.id
   join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'debtor_receivable'
   where e.payment_id = pg_temp.pay('01')),
  'the amount allocated is what the postings credit');
select is((select payload -> 'totals' from _p where n = '02'),
  '{"allocated_minor": "40000", "forwarded_minor": "0", "returned_minor": "0", "unallocated_minor": "5000"}'::jsonb,
  'an overpayment reads as not allocated');
select is((select array[payload ->> 'allocation', payload #>> '{totals,unallocated_minor}'] from _p where n = '03'),
  array['[]', '5000'], 'a held payment: nothing allocated, in neutral words (no reason in the payload)');
select ok((select bool_and(not (payload ? 'remaining_minor') and payload::text !~* 'balance|solde|hold|surendettement')
           from _p), 'no remaining balance before M3 (founder #14), no hold named');
select is((select payload ->> 'first_letter' from _p where n = '01'), null, 'no first letter before M4 (R124-4)');
select is((select encode(sha256(convert_to(payload::text, 'UTF8')), 'hex') from _p where n = '01'),
  'a0ea25cae5988a9290104dfd9bd1eb3a787ac7bf65d42dfff0c4719a13d529cb',
  'golden payload hash (canonical jsonb), pinned to the payload schema 1');

-- Issuing (the job played) --------------------------------------------------------------------------
select pg_temp.as_user('01');  -- the job runs as the worker; claims do not matter here
select is(pg_temp.receipts('01', '02', '03', '04', '05'), 3,
  'payments on a file get a receipt: allocated, overpaid, held — not one waiting for allocation, nor one without a file');
select results_eq($$select p.n, r.number, r.version, r.kind from public.receipt r
                    join (values ('01'), ('02'), ('03')) p (n) on r.payment_id = pg_temp.pay(p.n) order by p.n$$,
  $$values ('01', 'Q-2026-000001', 1, 'original'), ('02', 'Q-2026-000002', 1, 'original'),
           ('03', 'Q-2026-000003', 1, 'original')$$,
  'numbers Q-AAAA-NNNNNN drawn in processing order; first versions are originals');
select is((select last_number from private.receipt_counter where organization_id = '00000000-0000-0000-0000-0000000000aa'
             and year = extract(year from now() at time zone 'Europe/Paris')::integer), 3::bigint,
  'one counter per servicer and year');
select results_eq($$select d.storage_bucket, d.storage_path, d.kind, d.mime_type, d.sha256 = r.pdf_sha256,
                           d.account_id, d.party_id
                    from public.receipt r join public.document d on d.id = r.document_id
                    where r.payment_id = pg_temp.pay('01')$$,
  $$values ('documents'::text, 'receipts/00000000-0000-0000-0000-0000000000aa/2026/Q-2026-000001-v1.pdf'::text,
            'receipt'::text, 'application/pdf'::text, true, pg_temp.f('01'), 'b1000000-0000-0000-0000-000000000001'::uuid)$$,
  'each version is a document of the file, in the private bucket, with its SHA-256');
select ok((select bool_and(r.payload_sha256 = encode(sha256(convert_to(r.payload::text, 'UTF8')), 'hex')
                           and r.template_version = 'quittance-fr-1')
           from public.receipt r where r.organization_id = '00000000-0000-0000-0000-0000000000aa'),
  'the payload hash is the canonical jsonb''s');
select is(pg_temp.receipts('01', '02', '03'), 0, 'the same job again issues nothing (idempotent)');
select pg_temp.allocate('04', '04', '[["1", 7000]]');
select is(pg_temp.receipts('04'), 1, 'once allocated, its receipt follows');

-- A new version on every change; a void one when the payment leaves its file ----------------------
select lives_ok($$select public.reverse_allocation('rcpt-rev-01', pg_temp.pay('01'), pg_temp.f('01'),
                  array(select id from public.ledger_entry where payment_id = pg_temp.pay('01')), 'mauvais dossier')$$,
  'ops reverse the allocation');
select is(pg_temp.queued('01'), 2, 'the reversal queues the receipt again');
select is(pg_temp.receipts('01'), 1, 'a reversal issues a new version');
select results_eq($$select number, version, kind, payload -> 'allocation', payload #>> '{totals,unallocated_minor}'
                    from public.receipt where payment_id = pg_temp.pay('01') order by version$$,
  $$values ('Q-2026-000001'::text, 1, 'original'::text,
            (select payload -> 'allocation' from _p where n = '01'), '0'::text),
           ('Q-2026-000001', 2, 'update', '[]'::jsonb, '60000')$$,
  'same number, version 2 replaces version 1 (kept)');
select lives_ok($$select public.unassign_payment('rcpt-unassign-01', pg_temp.pay('01'), 'ne concerne pas ce dossier')$$,
  'ops take the payment off the file');
select is(pg_temp.queued('01'), 3, 'leaving the file queues the receipt');
select is(pg_temp.receipts('01'), 1, 'leaving the file issues a version');
select results_eq($$select version, kind, account_id, payload ->> 'state', payload ? 'allocation', payload ? 'payer'
                    from public.receipt where payment_id = pg_temp.pay('01') and version = 3$$,
  $$values (3, 'void'::text, pg_temp.f('01'), 'void'::text, false, false)$$,
  'a void version, about the file it cancels');
select is(pg_temp.receipts('01'), 0, 'void stays void: nothing more');
select pg_temp.match('01', '02', 'nothing_due');
select is(pg_temp.receipts('01'), 1, 'on another file: a new version for its debtor');
select results_eq($$select version, kind, account_id, client_organization_id, recipient_party_id,
                           payload #>> '{debtor,name}'
                    from public.receipt where payment_id = pg_temp.pay('01') and version = 4$$,
  $$values (4, 'update'::text, pg_temp.f('02'), '00000000-0000-0000-0000-0000000000a2'::uuid,
            'b1000000-0000-0000-0000-000000000002'::uuid, 'Jean-Pierre Lilas'::text)$$,
  'version 4 names the new file, its client and its debtor; the number stays');
select pg_temp.as_user('01');
reset role;

-- Receipts are append-only and follow each other -----------------------------------------------------
select throws_ok($$update public.receipt set kind = 'void' where payment_id = pg_temp.pay('02')$$, '23514', null,
  'a receipt is never changed');
select throws_ok($$delete from public.receipt where payment_id = pg_temp.pay('02')$$, '23514', null,
  'nor deleted');
insert into public.document (id, organization_id, client_organization_id, account_id, kind, storage_path, sha256, mime_type)
values ('d1000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
        pg_temp.f('02'), 'receipt', 'receipts/test/gap.pdf', repeat('e', 64), 'application/pdf');
select throws_ok($$insert into public.receipt (organization_id, client_organization_id, portfolio_id, account_id,
  payment_id, number, version, kind, payload, payload_sha256, template_version, renderer_version, known_at, document_id,
  pdf_sha256) values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
  '20000000-0000-0000-0000-0000000000a2', pg_temp.f('02'), pg_temp.pay('02'), 'Q-2026-000002', 3, 'update', '{}',
  encode(sha256(convert_to('{}'::jsonb::text, 'UTF8')), 'hex'), 'x', 'x', now(), 'd1000000-0000-0000-0000-0000000000f2',
  repeat('e', 64))$$, '23514', null, 'no gap between versions');
select throws_ok($$insert into public.receipt (organization_id, client_organization_id, portfolio_id, account_id,
  payment_id, number, version, kind, payload, payload_sha256, template_version, renderer_version, known_at, document_id,
  pdf_sha256) values ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a2',
  '20000000-0000-0000-0000-0000000000a2', pg_temp.f('02'), pg_temp.pay('02'), 'Q-2026-000009', 2, 'update', '{}',
  encode(sha256(convert_to('{}'::jsonb::text, 'UTF8')), 'hex'), 'x', 'x', now(), 'd1000000-0000-0000-0000-0000000000f2',
  repeat('e', 64))$$, '23514', null, 'a payment keeps its number');
create or replace function pg_temp.stray_pdf() returns integer language plpgsql as $$
begin
  perform private.receipt_begin();
  insert into pg_temp._receipt_pdf values (pg_temp.pay('02'), repeat('f', 64));
  return private.receipt_issue('quittance-fr-1', 'x');
end $$;
select throws_ok($$select pg_temp.stray_pdf()$$, '23514', null, 'a rendered PDF nobody prepared is refused');

-- Who reads receipts (design §6; founder #18) ---------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('01');
select is((select count(*)::int from public.receipt), 7, 'ops read every receipt of their servicer');
select pg_temp.as_user('05');
select is((select count(*)::int from public.receipt), 0, 'another servicer reads none');
select pg_temp.as_user('03', 'aal1');
select is((select array_agg(distinct client_organization_id) from public.receipt),
  array['00000000-0000-0000-0000-0000000000a1'::uuid], 'a client reads its own receipts only');
select ok(private.can_read_receipt_object('receipts/00000000-0000-0000-0000-0000000000aa/2026/Q-2026-000001-v1.pdf')
          and not private.can_read_receipt_object('receipts/00000000-0000-0000-0000-0000000000aa/2026/Q-2026-000002-v1.pdf'),
  'and their PDF only');
select pg_temp.as_user('04', 'aal1');
select is((select count(*)::int from public.receipt where client_organization_id = '00000000-0000-0000-0000-0000000000a1'),
  0, 'client A2 never reads client A1''s');
select pg_temp.as_user('02');
select is((select array_agg(distinct portfolio_id) from public.receipt),
  array['20000000-0000-0000-0000-0000000000a3'::uuid], 'a collector reads the receipts of his portfolios');
select pg_temp.as_user('06', 'aal1');
select is((select array_agg(distinct portfolio_id) from public.receipt),
  array['20000000-0000-0000-0000-0000000000a3'::uuid], 'a client user limited to a portfolio reads that portfolio''s');
select pg_temp.as_user('05');
select ok(not private.can_read_receipt_object('receipts/00000000-0000-0000-0000-0000000000aa/2026/Q-2026-000001-v1.pdf'),
  'another servicer cannot read the PDF');

-- The client payment feed (R124-5; founder #17) ---------------------------------------------------------
select pg_temp.as_user('03', 'aal1');
create temp table _feed as select * from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1');
grant select on _feed to authenticated;
select results_eq($$select kind, file_reference, amount_minor, reason from _feed order by kind, file_reference$$,
  $$values ('payment_allocated'::text, 'D-01'::text, '60000'::text, null::text),
           ('payment_allocated', 'D-04', '7000', null),
           ('payment_allocation_reversed', 'D-01', '60000', 'ops_correction'),
           ('payment_held', 'D-03', '5000', 'hold_blocks_allocation')$$,
  'the client reads what was allocated, reversed and held on its files; amounts from the postings');
select is((select lines from _feed where kind = 'payment_allocated' and file_reference = 'D-01'),
  '[{"item_ref": "F-011", "item_kind": "invoice", "due_date": "2026-08-01", "component": "principal",
     "amount_minor": "50000"},
    {"item_ref": "F-012", "item_kind": "invoice", "due_date": "2026-09-01", "component": "principal",
     "amount_minor": "10000"}]'::jsonb,
  'with the items each allocation credited');
select is((select array_agg(distinct debtor_name order by debtor_name) from _feed), array['Autre SA', 'Bloqué SARL', 'Durand SA'],
  'and each file''s debtor');
select is((select receipt_number || ' v' || receipt_version from _feed where kind = 'payment_allocated'
             and file_reference = 'D-01'), 'Q-2026-000001 v3',
  'the receipt as this client last had it (version 4 is another client''s)');
select ok((select bool_and(first_view and delivered_at is not null) from _feed), 'reading the feed delivers it');
select ok((select bool_and(not first_view) from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1')),
  'once');
select is((select count(*)::int from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1', null, 1)), 1,
  'pages of the asked size');
select is((select array_agg(x.notification_id order by x.created_at desc, x.notification_id desc)
           from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1',
                  (select f.cursor from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1', null, 1) f),
                  10) x),
  (select (array_agg(f.notification_id order by f.created_at desc, f.notification_id desc))[2:]
   from _feed f), 'the next page starts after the cursor');
select throws_ok($$select * from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1', 'n''importe quoi')$$,
  '22023', null, 'an unreadable cursor is refused');
select pg_temp.as_user('04', 'aal1');
select throws_ok($$select * from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1')$$, '42501', null,
  'another client cannot read it');
select pg_temp.as_user('02');
select throws_ok($$select * from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1')$$, '42501', null,
  'nor a collector');
select pg_temp.as_user('05');
select throws_ok($$select * from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1')$$, '42501', null,
  'nor another servicer');
select pg_temp.as_user('06', 'aal1');
select is((select array_agg(file_reference) from public.client_payment_feed('00000000-0000-0000-0000-0000000000a1')),
  array['D-03'], 'a client user limited to a portfolio reads that portfolio''s rows');
reset role;
select is((select count(*)::int from public.client_notification
           where client_organization_id = '00000000-0000-0000-0000-0000000000a2' and delivered_at is not null), 0,
  'nothing of another client is marked delivered');
set local role authenticated;
select pg_temp.as_user('01');
select is((select array_agg(file_reference order by file_reference)
           from public.client_payment_feed('00000000-0000-0000-0000-0000000000a2')), array['D-02'],
  'ops read a client''s feed');
reset role;
select is((select count(*)::int from public.client_notification
           where client_organization_id = '00000000-0000-0000-0000-0000000000a2' and delivered_at is not null), 0,
  'staff reading is no delivery');

select * from finish();
rollback;
