-- M2c-6a: transfers and pain.001 files (design §11, §9.7–§9.9, §15, §16; ADR-0014 M2c-6a).
--   * who: admins and ops managers at aal2 generate, download, mark and cancel files — not a collector, a client, an
--     admin at aal1, another servicer's staff; the pain.001 version is an admin's;
--   * generation: one file per paying account holding every ordered payout and file-mode refund that passes the
--     checks, and the sweep S = max(0, −Σ4679 − Σ sweeps ordered or in a file) in its own PmtInf; the cash check (the
--     last closing balance − later debits − transfers in flight − manual refunds ≥ CtrlSum; short: the sweep is left
--     out first, then refused); the per-client cap (payout_not_covered), the payee (payee_name_mismatch), a late date
--     only with a reason; a file not downloaded yet replaced by the next one (superseded, new MsgId);
--   * the job's functions (begin, record, failed), the guards (what was generated never changes, items append-only,
--     in_file → ordered only with its file closed);
--   * download (the hash checked, every download recorded, the second one only with the warning acknowledged; runs
--     sent), « Marquer comme transmis », cancel a file before download (superseded) and after (review T1: asked with
--     the attestation once statements cover its execution date and the next business day without its debit,
--     confirmed by another person; rejected), a refused transfer of a downloaded file cancelled the same way, then its
--     run (`payout_in_downloaded_file` before), a file never served again once it holds a cancelled transfer;
--   * refunds in the file (execution_mode, the transfer following its refund: booked by its debit, a pending file
--     superseded; cancelled with it);
--   * verification of payee (four eyes to clear), RLS (staff, client A/B, a restricted viewer, a collector, another
--     servicer) and the storage policy, the nightly alerts.
-- Since review round 2 (D1, 030) a cancellation needs its days over: the downloaded files whose cancellation is asked
-- are set back to a past business day (pg_temp.backdate: « time moves on »), the evidence statements dated then.
-- No ledger entry is posted by any of it (client money leaves 5120 at the bank's debit, M2c-6b).
begin;
select plan(116);

-- Fixtures (as 027: Martin (a1), Lilas (a2), Cyprès (a3) of the servicer aa; Bleu (b1) of another servicer bb) ------
insert into public.organization (id, kind, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000aa', 'servicer', 'Collectoo SAS', '732829320'),
  ('00000000-0000-0000-0000-0000000000bb', 'servicer', 'Autre cabinet SAS', null);
insert into public.organization (id, kind, servicer_organization_id, legal_name, siren) values
  ('00000000-0000-0000-0000-0000000000a1', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Martin SAS',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a2', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Lilas Finance',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000a3', 'creditor_client', '00000000-0000-0000-0000-0000000000aa', 'Cyprès SA',
   '552100554'),
  ('00000000-0000-0000-0000-0000000000b1', 'creditor_client', '00000000-0000-0000-0000-0000000000bb', 'Bleu SARL', null);
insert into auth.users (id, email, aud, role)
select ('10000000-0000-0000-0000-0000000000' || n)::uuid, 'u' || n || '@files.test', 'authenticated', 'authenticated'
from unnest(array['01', '02', '03', '04', '05', '06', '07', '08', '09']) n;
update public.app_user set display_name = 'Léa' where id = '10000000-0000-0000-0000-000000000001';
insert into public.membership (user_id, organization_id, role) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'collector'),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'client_admin'),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'admin'),
  ('10000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000bb', 'ops_manager'),
  ('10000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000bb', 'admin'),
  ('10000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000a1', 'client_viewer'),
  ('10000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-0000000000a2', 'client_admin'),
  ('10000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-0000000000aa', 'admin');
insert into public.portfolio (id, organization_id, client_organization_id, name)
select ('20000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'P' || c
from unnest(array['a1', 'a2', 'a3']) c;
insert into public.portfolio_access (user_id, portfolio_id) values
  ('10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-0000000000a1');
insert into public.bank_account (id, organization_id, purpose, iban, bic, currency, label, feed, opened_on) values
  ('80000000-0000-0000-0000-0000000000cf', '00000000-0000-0000-0000-0000000000aa', 'client_funds',
   'FR3430001007940000000001001', 'TESTFRPPXXX', 'EUR', 'Fonds de tiers', 'camt053', '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000c0', '00000000-0000-0000-0000-0000000000aa', 'own',
   'FR7610107001011234567890129', null, 'EUR', 'Compte propre', null, '2026-01-01'),
  ('80000000-0000-0000-0000-0000000000bf', '00000000-0000-0000-0000-0000000000bb', 'client_funds',
   'FR7630006000011234567890189', null, 'EUR', 'Fonds de tiers B', 'camt053', '2026-01-01');
insert into public.servicer_billing_settings (organization_id, own_bank_account_id)
values ('00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000c0');
insert into public.billing_identity (organization_id, legal_form, share_capital_minor, rcs_city, registered_office,
                                     vat_number, is_professional)
select o.id, case when o.kind = 'servicer' then 'SAS' end, case when o.kind = 'servicer' then 1000000 end,
       case when o.kind = 'servicer' then 'Paris' end,
       '{"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris", "country": "FR"}',
       case when o.kind = 'servicer'
            then 'FR' || lpad(((12 + 3 * (o.siren::bigint % 97)) % 97)::text, 2, '0') || o.siren end, true
from public.organization o where o.id in ('00000000-0000-0000-0000-0000000000aa', '00000000-0000-0000-0000-0000000000a1',
                                          '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a3');
insert into public.document (id, organization_id, client_organization_id, kind, storage_path, sha256, mime_type)
select ('d0000000-0000-0000-0000-0000000000' || x.n)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, x.kind, 'client/test/' || x.n || '.pdf', repeat('a', 64),
       'application/pdf'
from (values ('01', 'a1', 'mandate_document'), ('02', 'a2', 'mandate_document'), ('03', 'a1', 'payout_rib'),
             ('04', 'a2', 'payout_rib'), ('05', 'a3', 'mandate_document'), ('06', 'a3', 'payout_rib')) x (n, c, kind);
insert into public.mandate (id, organization_id, client_organization_id, reference, mandate_type, signed_on,
                            insurance_clause_ref)
select ('70000000-0000-0000-0000-0000000000' || c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || c)::uuid, 'MAND-' || c, 'mandate_amicable', '2026-01-01', 'art. 9'
from unnest(array['a1', 'a2', 'a3']) c;
insert into public.mandate_terms (id, mandate_id, valid_from, commission_schedule, commission_clause_ref, remittance_terms,
                                  remittance_clause_ref, document_id)
select ('71000000-0000-0000-0000-0000000000' || x.c)::uuid, ('70000000-0000-0000-0000-0000000000' || x.c)::uuid,
       '2026-01-01',
       '{"schema": "commission-1", "basis": {"families": "all", "forwards": {"file_recalled": false,
         "before_servicing_start": false, "client_ratification": false}, "on_reversal": "credit"},
         "rules": [{"id": "tout", "tier_key": "tout", "label_fr": "Toutes créances", "match": {},
                    "rate": {"kind": "flat", "rate": "0.15"}}]}',
       'art. 6', '{"schema": "remittance-1", "frequency": "twice_monthly", "netting": {"clause_ref": "art. 7.2"},
                   "clawback": null, "invoice_payment_days": 30}', 'art. 7',
       ('d0000000-0000-0000-0000-0000000000' || x.d)::uuid
from (values ('a1', '01'), ('a2', '02'), ('a3', '05')) x (c, d);
update public.portfolio set mandate_id = ('70000000-0000-0000-0000-0000000000' || right(id::text, 2))::uuid
where organization_id = '00000000-0000-0000-0000-0000000000aa';
insert into public.client_payout_account (id, organization_id, client_organization_id, currency, iban, holder_name,
                                          evidence_document_id, proposed_by)
select ('90000000-0000-0000-0000-0000000000' || x.c)::uuid, '00000000-0000-0000-0000-0000000000aa',
       ('00000000-0000-0000-0000-0000000000' || x.c)::uuid, 'EUR', x.iban, x.holder,
       ('d0000000-0000-0000-0000-0000000000' || x.d)::uuid, '10000000-0000-0000-0000-000000000004'
from (values ('a1', '03', 'FR7630004000031234567890143', 'MARTIN SAS'),
             ('a2', '04', 'FR1420041010050500013M02606', 'LILAS FINANCE'),
             ('a3', '06', 'FR7630006000011234567890189', 'CYPRES SA')) x (c, d, iban, holder);
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
-- [{e2e, amount, kind, pmt_inf}] booked on p_to.
create or replace function pg_temp.statement(p_n text, p_to date, p_closing bigint, p_debits jsonb default '[]',
                                             p_from date default null)
returns uuid language plpgsql as $$
declare s uuid := ('e2000000-0000-0000-0000-0000000000' || p_n)::uuid;
begin
  insert into public.bank_statement (id, organization_id, bank_account_id, currency, format, file_name, file_sha256,
                                     size_bytes, storage_path)
  values (s, '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', 'EUR', 'camt053', 's.xml',
          encode(sha256(convert_to(s::text, 'UTF8')), 'hex'), 1, 'test/' || s);
  update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = s;
  insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
                                       amount_minor, currency, booking_date, kind, end_to_end_id, payment_info_id)
  select '00000000-0000-0000-0000-0000000000aa', '80000000-0000-0000-0000-0000000000cf', s, d.ord, 't:' || s || d.ord,
         'debit', (d.v ->> 'amount')::bigint, 'EUR', p_to, coalesce(d.v ->> 'kind', 'transfer_out'), d.v ->> 'e2e',
         d.v ->> 'pmt_inf'
  from jsonb_array_elements(p_debits) with ordinality d (v, ord);
  update public.bank_statement set status = 'imported', from_date = coalesce(p_from, p_to), to_date = p_to,
    opening_booked_minor = 0, closing_booked_minor = p_closing, counts = '{}', finished_at = clock_timestamp(),
    -- the bank's creation time the import keeps (review round 3, E4): here its upload's; the section's period, the
    -- whole days it shows and its balances, as the parser gives them (review round 4, G3: its opening, the previous
    -- statement's closing — the balances follow, no « relevé manquant »)
    sections = jsonb_build_array(jsonb_build_object(
      'from_date', coalesce(p_from, p_to), 'to_date', p_to, 'covers_from', coalesce(p_from, p_to), 'covers_to', p_to,
      'opening_minor', coalesce((select p.closing_booked_minor from public.bank_statement p
                                 where p.bank_account_id = '80000000-0000-0000-0000-0000000000cf'
                                   and p.status = 'imported' and p.format = 'camt053'
                                   and p.to_date < coalesce(p_from, p_to)
                                 order by p.to_date desc, p.finished_at desc limit 1), 0)::text,
      'closing_minor', p_closing::text, 'created_at', now()))
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
grant all on j to authenticated;

-- Martin 200 000 → net 164 000; Lilas 512 000 → net 419 840 (their invoices set off); Cyprès 12 000, all set off (N = 0:
-- settled at approval, the servicer's 12 000 now on the dedicated account: −4679)
select pg_temp.file('01', '20000000-0000-0000-0000-0000000000a1', 200000);
select pg_temp.file('02', '20000000-0000-0000-0000-0000000000a2', 512000);
select pg_temp.file('03', '20000000-0000-0000-0000-0000000000a3', 12000);
select pg_temp.collect('01', 200000, private.paris_today() - 3);
select pg_temp.collect('02', 512000, private.paris_today() - 3);
select pg_temp.collect('03', 12000, private.paris_today() - 3);
insert into t select 'r1', pg_temp.run('a1', '{"01": "200000"}', 36000, 6000);
insert into t select 'r2', pg_temp.run('a2', '{"02": "512000"}', 92160, 15360);
insert into t select 'r3', pg_temp.run('a3', '{"03": "12000"}', 12000, 2000, 10, 12);
create temporary table _entries on commit drop as select count(*) as n from public.ledger_entry;
select results_eq($$ select r.status, r.net_minor, t.status, t.kind, left(t.end_to_end_id, 3), t.amount_minor
                     from public.remittance_run r left join public.bank_transfer t on t.id = r.transfer_id
                     where r.id in (select v from t where k in ('r1', 'r2', 'r3')) order by r.number $$,
  $$ values ('approved'::text, 164000::bigint, 'ordered'::text, 'payout'::text, 'RMT'::text, 164000::bigint),
            ('approved', 419840, 'ordered', 'payout', 'RMT', 419840),
            ('booked', 0, null, null, null, null) $$,
  'fixture: two payouts ordered at approval, Cyprès settled at approval (N = 0)');
select is((select -sum(lp.amount_minor) from public.ledger_posting lp join public.ledger_account la
           on la.id = lp.ledger_account_id where la.book = 'due_to_servicer'
             and la.organization_id = '00000000-0000-0000-0000-0000000000aa'), 12000::numeric,
  'fixture: 120,00 € of the servicer on the dedicated account (−4679)');

-- Schema and privileges --------------------------------------------------------------------------------------------
select ok((select bool_and(relrowsecurity) from pg_class
           where oid in ('public.transfer_file'::regclass, 'public.transfer_file_item'::regclass,
                         'public.transfer_file_download'::regclass, 'public.payee_name_check'::regclass,
                         'public.transfer_cancellation_request'::regclass)),
  'RLS on the files, their items, their downloads, the payee checks and the cancellation requests');
select is((select pain_version from public.bank_account where id = '80000000-0000-0000-0000-0000000000cf'),
  'pain.001.001.09', 'a paying account writes pain.001.001.09 by default (design §11)');
select ok(not has_function_privilege('anon', 'public.generate_transfer_file(text, uuid, text)', 'execute')
          and not has_function_privilege('anon', 'public.transfer_file_download(uuid, text, boolean)', 'execute')
          and not has_function_privilege('authenticated', 'private.transfer_file_record(uuid, uuid, text, bigint, text, boolean, text, integer, bigint)', 'execute')
          and has_function_privilege('service_role', 'private.transfer_file_begin(uuid, uuid)', 'execute')
          and not has_function_privilege('authenticated', 'private.transfer_file_failed(uuid, uuid, text)', 'execute'),
  'the commands are not anon''s; only the worker writes a file');
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname in ('public', 'private') and p.prosecdef
             and p.proname in ('generate_transfer_file', 'transfer_file_download', 'mark_transfer_file_sent',
                               'cancel_transfer_file', 'record_payee_name_mismatch', 'clear_payee_name_mismatch',
                               'set_bank_account_pain_version', 'transfer_overview', 'transfer_file_detail',
                               'transfer_file_begin', 'transfer_file_record', 'transfer_file_failed',
                               'transfer_file_release', 'transfer_hold_reason', 'run_transfer_checks',
                               'request_refund', 'cancel_remittance_run', 'refund_transfer_follow',
                               'request_transfer_file_cancellation', 'confirm_transfer_file_cancellation',
                               'request_transfer_cancellation', 'confirm_transfer_cancellation',
                               'transfer_cancel_evidence', 'transfer_cancellation_card', 'transfer_checks_due',
                               'queue_remittance_schedule', 'can_read_transfer_file_object')
             and coalesce(array_to_string(p.proconfig, ','), '') !~ 'search_path=""'), null,
  'every definer function of the slice pins its search_path');

-- Who generates ------------------------------------------------------------------------------------------------------
select throws_ok($$ select pg_temp.gen('02', 'tf-who-02') $$, '42501', 'not allowed', 'a collector cannot generate a file');
select throws_ok($$ select pg_temp.gen('03', 'tf-who-03') $$, '42501', 'not allowed', 'nor the client''s administrator');
select throws_ok($$ select pg_temp.gen('01', 'tf-who-01a', null, 'aal1') $$, '42501', 'not allowed',
  'nor an ops manager at aal1');
select throws_ok($$ select pg_temp.gen('05', 'tf-who-05') $$, '42501', 'not allowed',
  'nor another servicer''s staff (another tenant''s account)');
select throws_ok($$ select pg_temp.gen('01', 'tf-own-0001', null, 'aal2', '80000000-0000-0000-0000-0000000000c0') $$,
  '23514', 'transfer file refused: not_a_paying_account', 'the own account pays no file here (top-up files: M2c-7)');

-- The cash check -----------------------------------------------------------------------------------------------------
select throws_ok($$ select pg_temp.gen('01', 'tf-cash-0001') $$, '23514', 'transfer file refused: no_closing_balance',
  'no statement with a closing balance: refused (ops import one)');
select pg_temp.statement('01', private.paris_today() - 3, 500000);
select throws_ok($$ select pg_temp.gen('01', 'tf-cash-0002') $$, '23514', 'transfer file refused: cash_not_covered',
  'a closing balance of 5 000,00 € does not cover 5 838,40 € of payouts: refused');
select pg_temp.statement('02', private.paris_today() - 2, 590000);
insert into j select 'g1', pg_temp.gen('01', 'tf-gen-0001');
select results_eq($$ select (v ->> 'nb_of_txs')::int, v ->> 'ctrl_sum_minor', v ->> 'sweep_minor', v ->> 'sweep_left_minor',
                            v ->> 'status'
                     from j where k = 'g1' $$,
  $$ values (2, '583840', '0', '12000', 'pending') $$,
  'enough for the payouts, not the sweep: the servicer''s share is left out first (clients are paid first, founder #9)');
insert into t select 'f1', (v ->> 'file_id')::uuid from j where k = 'g1';
select results_eq($$ select f.number ~ '^TF-[0-9]{4}-[0-9]{6}$', f.msg_id = f.number, f.status, f.pain_version,
                            f.debtor_iban, f.debtor_bic, f.initiating_party, f.created_at_iso ~ '^[0-9-]{10}T[0-9:]{8}\+0[12]:00$',
                            f.cash_check ->> 'available_minor', f.cash_check ->> 'closing_minor'
                     from public.transfer_file f where f.id = (select v from t where k = 'f1') $$,
  $$ values (true, true, 'pending'::text, 'pain.001.001.09'::text, 'FR3430001007940000000001001'::text,
             'TESTFRPPXXX'::text, 'Collectoo SAS'::text, true, '590000'::text, '590000'::text) $$,
  'the file: its number is its MsgId, CreDtTm frozen in Paris time, the debtor and the cash check as they stood');
select results_eq($$ select count(*)::int, count(distinct i.pmt_inf_id)::int, min(i.execution_date) = private.next_business_day(private.paris_today()),
                            bool_and(t.status = 'in_file' and t.transfer_file_id = i.file_id)
                     from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
                     where i.file_id = (select v from t where k = 'f1') $$,
  $$ values (2, 1, true, true) $$,
  'its two payouts in one PmtInf, executed the next business day (no cut-off recorded: never today), in_file');
select is((select count(*) from public.ledger_entry) - (select n from _entries), 0::bigint,
  'generating a file posts nothing (client money leaves 5120 at the bank''s debit, M2c-6b)');
select is(pg_temp.gen('01', 'tf-gen-0001') ->> 'file_id', (select v::text from t where k = 'f1'),
  'the same key replays the same file');
select throws_ok($$ select pg_temp.gen('04', 'tf-gen-0001') $$, '22023', null,
  'the key of another user''s request is refused');

-- The job (emulated) -------------------------------------------------------------------------------------------------
select is(private.transfer_file_begin((select v from t where k = 'f1'), gen_random_uuid()), null,
  'another job''s token: nothing to write');
insert into j select 'b1', private.transfer_file_begin(f.id, f.job_token) from public.transfer_file f
where f.id = (select v from t where k = 'f1');
select results_eq($$ select v ->> 'version', v ->> 'msg_id' = v ->> 'number', jsonb_array_length(v -> 'payment_infos'),
                            x ->> 'instr_id' = (select number from public.remittance_run where id = (select v from t where k = 'r1')),
                            x ->> 'end_to_end_id' ~ '^RMT[0-9A-F]{12}$', x ->> 'amount_minor',
                            x ->> 'remittance_info' ~ '^REVERSEMENT RV-[0-9-]+ FACTURE FC-', x ->> 'creditor_name',
                            v ->> 'storage_path' ~ '/TF-.*\.xml$'
                     from j cross join lateral jsonb_array_elements(j.v #> '{payment_infos,0,transactions}') x
                     where k = 'b1' and x ->> 'end_to_end_id' = (pg_temp.tr((select v from t where k = 'r1'))).end_to_end_id $$,
  $$ values ('pain.001.001.09'::text, true, 1, true, true, '164000'::text, true, 'MARTIN SAS'::text, true) $$,
  'begin: what the writer needs, frozen (InstrId = the run number, our RMT id, the amount as text, the payee as on the RIB)');
select throws_ok(format($$ select private.transfer_file_record(%L, %L, %L, 10, %L, false, 'pain001-1', 3, 583840) $$,
  (select v from t where k = 'f1'), (pg_temp.fl((select v from t where k = 'f1'))).job_token, repeat('a', 64),
  (select v ->> 'storage_path' from j where k = 'b1')),
  '23514', null, 'a written file whose NbOfTxs differs from what was generated is refused');
select is(pg_temp.write((select v from t where k = 'f1')) ->> 'status', 'generated', 'recorded: generated');
select is(private.transfer_file_begin(f.id, f.job_token), null, 'a second delivery finds it generated: nothing to do')
from public.transfer_file f where f.id = (select v from t where k = 'f1');
select throws_ok($$ update public.transfer_file set ctrl_sum_minor = 1 where id = (select v from t where k = 'f1') $$,
  '23514', null, 'what was generated never changes');
select throws_ok($$ delete from public.transfer_file_item $$, '23514', null, 'a file''s items are append-only');
select throws_ok($$ update public.bank_transfer set status = 'ordered', transfer_file_id = null
                   where transfer_file_id = (select v from t where k = 'f1') $$,
  '23514', null, 'a transfer leaves a live file only with the file');

-- A new generation replaces a file not downloaded yet (new MsgId); the sweep goes in its own PmtInf ------------------
select pg_temp.statement('03', private.paris_today() - 1, 724000);
insert into j select 'g2', pg_temp.gen('01', 'tf-gen-0002');
insert into t select 'f2', (v ->> 'file_id')::uuid from j where k = 'g2';
select results_eq($$ select f.status, f.superseded_by, f.closed_at is not null from public.transfer_file f
                     where f.id = (select v from t where k = 'f1') $$,
  $$ values ('superseded'::text, (select v from t where k = 'f2'), true) $$,
  'the file not downloaded is superseded by the next one');
select results_eq($$ select (v ->> 'nb_of_txs')::int, v ->> 'ctrl_sum_minor', v ->> 'sweep_minor',
                            jsonb_array_length(v -> 'superseded')
                     from j where k = 'g2' $$,
  $$ values (3, '595840', '12000', 1) $$,
  'the new file: the two payouts again and the sweep of the servicer''s 120,00 €');
select results_eq($$ select t.kind, i.pmt_inf_id, t.creditor_bank_account_id, t.payee_iban, left(t.end_to_end_id, 3)
                     from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
                     where i.file_id = (select v from t where k = 'f2') order by t.kind, t.amount_minor $$,
  $$ values ('payout'::text, (pg_temp.fl((select v from t where k = 'f2'))).number || '-1', null::uuid, 'FR7630004000031234567890143'::text, 'RMT'::text),
            ('payout', (pg_temp.fl((select v from t where k = 'f2'))).number || '-1', null, 'FR1420041010050500013M02606', 'RMT'),
            ('sweep', (pg_temp.fl((select v from t where k = 'f2'))).number || '-2', '80000000-0000-0000-0000-0000000000c0'::uuid,
             'FR7610107001011234567890129', 'SWP') $$,
  'payouts in PmtInf -1, the sweep to the own account in its own PmtInf -2 (design §11)');
select isnt((pg_temp.fl((select v from t where k = 'f2'))).msg_id, (pg_temp.fl((select v from t where k = 'f1'))).msg_id,
  'a regenerated file has a new MsgId');

-- Cancel a file before download: superseded, its transfers back to ordered, its sweep cancelled (recomputed) --------
select pg_temp.write((select v from t where k = 'f2'));
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.cancel_transfer_file('tf-cancel-0001', %L, %s, 'erreur', 'not_uploaded') $$,
  (select v from t where k = 'f2'), (pg_temp.fl((select v from t where k = 'f2'))).version),
  '23514', 'transfer file refused: not_downloaded', 'no attestation for a file never downloaded');
select is(public.cancel_transfer_file('tf-cancel-0002', (select v from t where k = 'f2'),
                                      (pg_temp.fl((select v from t where k = 'f2'))).version, 'à refaire') ->> 'status',
  'superseded', 'cancelled before download: superseded');
reset role;
select results_eq($$ select t.kind, t.status, t.transfer_file_id is null from public.transfer_file_item i
                     join public.bank_transfer t on t.id = i.transfer_id
                     where i.file_id = (select v from t where k = 'f2') order by i.seq $$,
  $$ values ('payout'::text, 'ordered'::text, true), ('payout', 'ordered', true), ('sweep', 'cancelled', false) $$,
  'its payouts back to ordered for the next file, its sweep cancelled (never re-issued: ledger critique #16)');

-- Holds: the payee check, the per-client cap, a late date -----------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'pc', public.record_payee_name_mismatch('tf-vop-0001', (pg_temp.tr((select v from t where k = 'r2'))).id,
  'close_match', 'LILAS FINANCES SA', 'La banque propose un autre nom');
reset role;
select is(private.remittance_payout_blockers('00000000-0000-0000-0000-0000000000a2', 'EUR', private.paris_today()),
  array['payee_name_mismatch'], 'a payee check not cleared blocks the client''s payouts (Reg. 260/2012 art. 5 quater)');
select is(private.transfer_hold_reason((pg_temp.tr((select v from t where k = 'r2'))).id, private.paris_today(),
                                       private.next_business_day(private.paris_today()), null),
  'payout_blocked:payee_name_mismatch', 'its transfer is held out of the next file');
update private.client_payable_balance set balance_minor = -100
where client_organization_id = '00000000-0000-0000-0000-0000000000a1';
select is(private.transfer_hold_reason((pg_temp.tr((select v from t where k = 'r1'))).id, private.paris_today(),
                                       private.next_business_day(private.paris_today()), null),
  'payout_not_covered', 'a payout beyond what the client is still owed is held (N + D ≤ −4670[c]: never another''s money)');
update private.client_payable_balance set balance_minor = -200000
where client_organization_id = '00000000-0000-0000-0000-0000000000a1';
update public.remittance_run set earliest_latest_execution_date = private.paris_today() - 1
where id = (select v from t where k = 'r1');
select is(private.transfer_hold_reason((pg_temp.tr((select v from t where k = 'r1'))).id, private.paris_today(),
                                       private.next_business_day(private.paris_today()), null),
  'late_reason_required', 'after the run''s latest execution date: only with a reason');
insert into j select 'g3', pg_temp.gen('01', 'tf-gen-0003');
insert into t select 'f3', (v ->> 'file_id')::uuid from j where k = 'g3';
select results_eq($$ select (v ->> 'nb_of_txs')::int, v ->> 'sweep_minor',
                            (select array_agg(h ->> 'reason' order by h ->> 'reason') from jsonb_array_elements(v -> 'held') h)
                     from j where k = 'g3' $$,
  $$ values (1, '12000'::text, array['late_reason_required', 'payout_blocked:payee_name_mismatch']) $$,
  'both held out with their reasons: the file carries only the sweep');
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok($$ select public.clear_payee_name_mismatch('tf-vop-0002', (select (v ->> 'check_id')::uuid from j where k = 'pc'),
                                                            'vérifié') $$,
  '23514', 'payee check refused: same_person', 'who recorded a payee check (here also the IBAN''s confirmer) cannot clear it');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok($$ select public.clear_payee_name_mismatch('tf-vop-0003', (select (v ->> 'check_id')::uuid from j where k = 'pc'),
                                                            'vérifié') $$,
  '23514', 'payee check refused: same_person', 'nor who proposed the flagged IBAN (review T5)');
reset role;
select pg_temp.as_user('09');
set local role authenticated;
select is(public.clear_payee_name_mismatch('tf-vop-0004', (select (v ->> 'check_id')::uuid from j where k = 'pc'),
                                           'RIB vérifié avec le client') ->> 'cleared', 'true', 'a third person clears it');
reset role;
insert into j select 'g4', pg_temp.gen('01', 'tf-gen-0004', 'Relevé importé tardivement');
insert into t select 'f4', (v ->> 'file_id')::uuid from j where k = 'g4';
select results_eq($$ select (v ->> 'nb_of_txs')::int, v ->> 'ctrl_sum_minor', jsonb_array_length(v -> 'held')
                     from j where k = 'g4' $$,
  $$ values (3, '595840'::text, 0) $$,
  'with a late reason and the check cleared, both payouts go in, and the sweep recomputed (the last one cancelled)');
select results_eq($$ select (pg_temp.fl((select v from t where k = 'f3'))).status, f.late_reason,
                            (select bool_or(i.late) from public.transfer_file_item i where i.file_id = f.id)
                     from public.transfer_file f where f.id = (select v from t where k = 'f4') $$,
  $$ values ('superseded'::text, 'Relevé importé tardivement'::text, true) $$,
  'the reason kept on the file, the late item marked; the earlier file not downloaded superseded');
update public.remittance_run set earliest_latest_execution_date = private.paris_today() + 24
where id = (select v from t where k = 'r1');

-- Download -----------------------------------------------------------------------------------------------------------
select throws_ok($$ select pg_temp.download('01', (select v from t where k = 'f4')) $$, '23514',
  'transfer file refused: not_ready', 'a file the job has not written yet cannot be downloaded');
select pg_temp.write((select v from t where k = 'f4'));
select throws_ok($$ select pg_temp.download('02', (select v from t where k = 'f4')) $$, '42501', 'not allowed',
  'a collector cannot download a file');
select throws_ok($$ select pg_temp.download('05', (select v from t where k = 'f4')) $$, '42501', 'not allowed',
  'nor another servicer''s staff');
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.transfer_file_download(%L, %L) $$, (select v from t where k = 'f4'),
                        repeat('b', 64)),
  '23514', 'transfer file refused: hash_mismatch', 'bytes that are not the recorded ones are never served');
reset role;
select is(pg_temp.download('01', (select v from t where k = 'f4')) ->> 'download', '1', 'downloaded once');
select results_eq($$ select f.status, f.download_count, f.first_downloaded_by,
                            (select array_agg(r.status order by r.number) from public.remittance_run r
                             where r.id in (select v from t where k in ('r1', 'r2')))
                     from public.transfer_file f where f.id = (select v from t where k = 'f4') $$,
  $$ values ('downloaded'::text, 1, '10000000-0000-0000-0000-000000000001'::uuid, array['sent', 'sent']) $$,
  'the file downloaded, by whom; its runs sent (§9.8)');
select throws_ok($$ select pg_temp.download('04', (select v from t where k = 'f4')) $$, '23514',
  'transfer file refused: already_downloaded', 'a second download needs the warning acknowledged (ops critique #33)');
select is(pg_temp.download('04', (select v from t where k = 'f4'), true) ->> 'download', '2',
  'with the warning acknowledged, downloaded again');
select results_eq($$ select n, downloaded_by, warning_acknowledged from public.transfer_file_download
                     where file_id = (select v from t where k = 'f4') order by n $$,
  $$ values (1, '10000000-0000-0000-0000-000000000001'::uuid, false), (2, '10000000-0000-0000-0000-000000000004'::uuid, true) $$,
  'every download recorded');
select results_eq($$ select x ->> 'in_flight_minor', (x ->> 'in_flight_count')::int, x ->> 'available_minor'
                     from (select private.transfer_cash_position('80000000-0000-0000-0000-0000000000cf') as x) y $$,
  $$ values ('595840'::text, 3, '128160'::text) $$,
  'a downloaded file is in flight: the cash check subtracts it until its debits are on a statement');
select throws_ok($$ select pg_temp.gen('01', 'tf-gen-0005') $$, '23514', 'transfer file refused: nothing_to_file',
  'everything is in a file: nothing to generate');

-- « Marquer comme transmis » -----------------------------------------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.mark_transfer_file_sent('tf-sent-0001', %L, 1) $$, (select v from t where k = 'f4')),
  '23514', 'transfer file refused: version_changed', 'compare and set on the file''s version');
select is(public.mark_transfer_file_sent('tf-sent-0002', (select v from t where k = 'f4'),
                                         (pg_temp.fl((select v from t where k = 'f4'))).version) ->> 'status', 'sent',
  'marked as sent');
select throws_ok(format($$ select public.mark_transfer_file_sent('tf-sent-0003', %L, %s) $$, (select v from t where k = 'f4'),
                        (pg_temp.fl((select v from t where k = 'f4'))).version),
  '23514', 'transfer file refused: already_sent', 'once');
reset role;
select ok((pg_temp.fl((select v from t where k = 'f4'))).sent_marked_by = '10000000-0000-0000-0000-000000000001',
  'who marked it');

-- Cancel a file after download (review T1, risk R4): asked by one person, confirmed by another, on the statements'
-- evidence (the execution date and the account's next business day imported, no debit of it), once those days are
-- over (review round 2, D1): time moves on — here the file is set back to a past business day E, its next N ---------
create or replace function pg_temp.e() returns date language sql as $$
  select c.day from public.business_calendar c
  where c.scope = 'FR-conservative' and not c.closed and c.day < private.paris_today()
    and c.day > private.paris_today() - 60
  order by c.day desc offset 9 limit 1 $$;
create or replace function pg_temp.n() returns date language sql as $$ select private.next_business_day(pg_temp.e()) $$;
create or replace function pg_temp.backdate(p_file uuid, p_day date) returns void language plpgsql as $$
begin
  set constraints public.transfer_file_superseded_by_fkey immediate;
  alter table public.transfer_file disable trigger transfer_file_guard;
  update public.transfer_file set first_execution_date = p_day, last_execution_date = p_day where id = p_file;
  alter table public.transfer_file enable always trigger transfer_file_guard;
  alter table public.transfer_file_item disable trigger transfer_file_item_append_only;
  update public.transfer_file_item set execution_date = p_day where file_id = p_file;
  alter table public.transfer_file_item enable always trigger transfer_file_item_append_only;
  set constraints public.transfer_file_superseded_by_fkey deferred;
end $$;
select pg_temp.backdate((select v from t where k = 'f4'), pg_temp.e());
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.cancel_transfer_file('tf-cancel-0003', %L, %s, 'rejet') $$,
                        (select v from t where k = 'f4'), (pg_temp.fl((select v from t where k = 'f4'))).version),
  '23514', 'transfer file refused: cancellation_request_required',
  'after download a file is never cancelled in one step (money#1: its transfers would be filed again)');
select throws_ok(format($$ select public.request_transfer_file_cancellation('tf-cancel-0004', %L, %s, 'rejet', null) $$,
                        (select v from t where k = 'f4'), (pg_temp.fl((select v from t where k = 'f4'))).version),
  '23514', 'transfer file refused: attestation_required', 'its cancellation is asked with an attestation');
select throws_ok(format($$ select public.request_transfer_file_cancellation('tf-cancel-0005', %L, %s, 'Fichier rejeté',
                                                                            'rejected_by_bank') $$,
                        (select v from t where k = 'f4'), (pg_temp.fl((select v from t where k = 'f4'))).version),
  '23514', 'transfer file refused: no_statement_evidence', '… and only once statements cover its execution date');
reset role;
select pg_temp.statement('05', pg_temp.e(), 724000);
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.request_transfer_file_cancellation('tf-cancel-0006', %L, %s, 'Fichier rejeté',
                                                                            'rejected_by_bank') $$,
                        (select v from t where k = 'f4'), (pg_temp.fl((select v from t where k = 'f4'))).version),
  '23514', 'transfer file refused: no_statement_evidence',
  'the execution day alone is not enough: the debit may be booked the next business day');
reset role;
select pg_temp.statement('06', pg_temp.n(), 724000);
select pg_temp.as_user('01');
set local role authenticated;
select is(public.request_transfer_file_cancellation('tf-cancel-0007', (select v from t where k = 'f4'),
                                                    (pg_temp.fl((select v from t where k = 'f4'))).version,
                                                    'Fichier rejeté par la banque (format)', 'rejected_by_bank') ->> 'status',
  'requested', 'with both days imported and no debit of it: asked');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok(format($$ select public.request_transfer_file_cancellation('tf-cancel-0008', %L, %s, 'rejet', 'not_uploaded') $$,
                        (select v from t where k = 'f4'), (pg_temp.fl((select v from t where k = 'f4'))).version),
  '23514', 'transfer file refused: already_requested', 'one request at a time');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.confirm_transfer_file_cancellation('tf-cancel-0009', %L, %s) $$,
                        (select v from t where k = 'f4'), (pg_temp.fl((select v from t where k = 'f4'))).version),
  '23514', 'transfer file refused: same_person', 'who asked cannot confirm (four eyes)');
reset role;
select is((select count(*)::int from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
           where i.file_id = (select v from t where k = 'f4') and t.status = 'in_file'), 3,
  'until confirmed nothing moves: its transfers stay in it');
select pg_temp.as_user('04');
set local role authenticated;
select is(public.confirm_transfer_file_cancellation('tf-cancel-0010', (select v from t where k = 'f4'),
                                                    (pg_temp.fl((select v from t where k = 'f4'))).version) ->> 'status',
  'rejected', 'another person confirms: « Rejeté par la banque »');
reset role;
select results_eq($$ select array_agg(r.status order by r.number), array_agg(t.status order by r.number)
                     from public.remittance_run r join public.bank_transfer t on t.id = r.transfer_id
                     where r.id in (select v from t where k in ('r1', 'r2')) $$,
  $$ values (array['approved', 'approved'], array['ordered', 'ordered']) $$,
  'its runs back to approved, their transfers ordered again');
insert into t select 'f5', (pg_temp.gen('01', 'tf-gen-0006') ->> 'file_id')::uuid;
select pg_temp.write((select v from t where k = 'f5'));
select pg_temp.download('01', (select v from t where k = 'f5'));
select ok(private.can_read_transfer_file_object((pg_temp.fl((select v from t where k = 'f5'))).storage_path),
  'the bucket: the bytes of a file its caller just downloaded (review T4)');
reset role;
select pg_temp.backdate((select v from t where k = 'f5'), pg_temp.e());
-- A run whose payout is in a downloaded file (money#2): it waits for its transfer's cancellation
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok(format($$ select public.cancel_remittance_run('tf-run-0001', %L, %s, 'IBAN refusé') $$,
                        (select v from t where k = 'r1'),
                        (select version from public.remittance_run where id = (select v from t where k = 'r1'))),
  '23514', 'remittance run refused: payout_in_downloaded_file',
  'a run whose payout is in a downloaded file is not cancelled while the file may be executed (money#2)');
reset role;
-- the statement of the next business day: Lilas's payout debited, Martin's not (the bank refused it)
select pg_temp.statement('04', pg_temp.n(), 724000 - 419840,
  jsonb_build_array(jsonb_build_object('e2e', (pg_temp.tr((select v from t where k = 'r2'))).end_to_end_id,
                                       'amount', 419840)));
select pg_temp.as_user('01');
set local role authenticated;
select is(public.request_transfer_cancellation('tf-tc-0001', (pg_temp.tr((select v from t where k = 'r1'))).id,
                                               'La banque a refusé le virement (nom du bénéficiaire)') ->> 'status',
  'requested', 'the refused transfer: its cancellation asked (statements without its debit, pain001#1)');
select throws_ok(format($$ select public.confirm_transfer_cancellation('tf-tc-0002', %L) $$,
                        (pg_temp.tr((select v from t where k = 'r1'))).id),
  '23514', 'transfer refused: same_person', 'confirmed by another person');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select is(public.confirm_transfer_cancellation('tf-tc-0003', (pg_temp.tr((select v from t where k = 'r1'))).id) ->> 'status',
  'cancelled', 'confirmed: the transfer is cancelled');
select is(public.cancel_remittance_run('tf-run-0003', (select v from t where k = 'r1'),
                                       (select version from public.remittance_run where id = (select v from t where k = 'r1')),
                                       'La banque a refusé le virement (nom du bénéficiaire)') ->> 'status',
  'cancelled', 'then its run is cancelled');
select throws_ok(format($$ select public.request_transfer_cancellation('tf-tc-0004', %L, 'x') $$,
                        (pg_temp.tr((select v from t where k = 'r2'))).id),
  '23514', 'transfer refused: debit_seen', 'never a transfer whose debit is on a statement');
reset role;
select results_eq($$ select (pg_temp.tr((select v from t where k = 'r1'))).status, (pg_temp.fl((select v from t where k = 'f5'))).status,
                            (select count(*)::int from public.commission_invoice
                             where run_id = (select v from t where k = 'r1') and kind = 'credit_note') $$,
  $$ values ('cancelled'::text, 'downloaded'::text, 1) $$,
  'its transfer cancelled (the file stays: the others were executed), its invoice credited');
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.request_transfer_file_cancellation('tf-cancel-0011', %L, %s, 'x', 'not_uploaded') $$,
                        (select v from t where k = 'f5'), (pg_temp.fl((select v from t where k = 'f5'))).version),
  '23514', 'transfer file refused: debit_seen', 'a file with a debit on a statement is never cancelled (risk R4)');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok(format($$ select public.transfer_file_download(%L, %L, true) $$, (select v from t where k = 'f5'),
                        pg_temp.sha((select v from t where k = 'f5'))),
  '23514', 'transfer file refused: holds_cancelled_transfer',
  'a file holding a transfer cancelled since is never served again (money#2)');
reset role;
select results_eq($$ select x ->> 'in_flight_minor', x ->> 'debits_since_minor'
                     from (select private.transfer_cash_position('80000000-0000-0000-0000-0000000000cf') as x) y $$,
  $$ values ('12000'::text, '0'::text) $$,
  'a transfer whose debit a statement shows is no longer in flight, nor one cancelled on its evidence (only the sweep is)');

-- Refunds in the file ------------------------------------------------------------------------------------------------
select pg_temp.collect('09', 5000, private.paris_today() - 1, false);
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'rf1', public.request_refund('tf-rfd-0001', pg_temp.pay('09'), '5000', null, null, 'other',
                                                  null, '5000', 'payeur inconnu');
reset role;
select results_eq($$ select q.execution_mode, t.kind, t.status, t.end_to_end_id = q.end_to_end_id, t.amount_minor
                     from public.refund_request q join public.bank_transfer t on t.id = q.transfer_id
                     where q.id = (select (v ->> 'refund_request_id')::uuid from j where k = 'rf1') $$,
  $$ values ('file'::text, 'refund'::text, 'ordered'::text, true, 5000::bigint) $$,
  'a refund goes in the next file by default (founder #15): its transfer, our RFD id');
insert into t select 'f6', (pg_temp.gen('01', 'tf-gen-0007') ->> 'file_id')::uuid;
select is((select count(*)::int from public.transfer_file_item i join public.bank_transfer t on t.id = i.transfer_id
           where i.file_id = (select v from t where k = 'f6') and t.kind = 'refund'), 1, 'it goes in the next file');
select pg_temp.as_user('01');
set local role authenticated;
select lives_ok($$ select public.cancel_refund('tf-rfd-0002', (select (v ->> 'refund_request_id')::uuid from j where k = 'rf1'),
                                               'IBAN à confirmer') $$, 'the refund cancelled while its file is pending');
reset role;
select results_eq($$ select (pg_temp.fl((select v from t where k = 'f6'))).status, t.status
                     from public.refund_request q join public.bank_transfer t on t.id = q.transfer_id
                     where q.id = (select (v ->> 'refund_request_id')::uuid from j where k = 'rf1') $$,
  $$ values ('superseded'::text, 'cancelled'::text) $$,
  'its file, not downloaded, superseded; its transfer cancelled with it');
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'rf2', public.request_refund('tf-rfd-0003', pg_temp.pay('09'), '5000', null, null, 'other',
                                                  null, '5000', 'payeur inconnu', 'manual');
reset role;
select is((select execution_mode || ':' || coalesce(transfer_id::text, '-') from public.refund_request
           where id = (select (v ->> 'refund_request_id')::uuid from j where k = 'rf2')), 'manual:-',
  'executed by hand when ops say so: no transfer');
select results_eq($$ select x ->> 'manual_refunds_minor'
                     from (select private.transfer_cash_position('80000000-0000-0000-0000-0000000000cf') as x) y $$,
  $$ values ('5000'::text) $$, 'a manual refund pending is subtracted from the cash');

-- Verification of payee commands, the pain version ----------------------------------------------------------------
select pg_temp.as_user('02');
set local role authenticated;
select throws_ok(format($$ select public.record_payee_name_mismatch('tf-vop-0010', %L, 'no_match', null, 'x') $$,
                        (pg_temp.tr((select v from t where k = 'r2'))).id),
  '42501', 'not allowed', 'a collector records no payee check');
reset role;
select pg_temp.as_user('01');
set local role authenticated;
select throws_ok(format($$ select public.record_payee_name_mismatch('tf-vop-0011', %L, 'maybe', null, 'x') $$,
                        (pg_temp.tr((select v from t where k = 'r2'))).id),
  '23514', 'payee check refused: result', 'a no-match or a close-match only');
select throws_ok($$ select public.set_bank_account_pain_version('tf-pain-0001', '80000000-0000-0000-0000-0000000000cf',
                                                                'pain.001.001.03') $$,
  '42501', 'not allowed', 'the pain version is an admin''s');
reset role;
select pg_temp.as_user('04');
set local role authenticated;
select throws_ok($$ select public.set_bank_account_pain_version('tf-pain-0002', '80000000-0000-0000-0000-0000000000cf',
                                                                'pain.001.001.12') $$,
  '23514', 'transfer file refused: unknown_pain_version', '.09 or .03 only');
select is(public.set_bank_account_pain_version('tf-pain-0003', '80000000-0000-0000-0000-0000000000cf',
                                               'pain.001.001.03') ->> 'pain_version', 'pain.001.001.03',
  'an admin sets .03 when the bank''s guide asks for it');
reset role;
select is((pg_temp.fl((select v from t where k = 'f5'))).pain_version, 'pain.001.001.09',
  'files already generated keep their version');

-- The job fails a file: its transfers wait for the next one ---------------------------------------------------------
select pg_temp.collect('10', 3000, private.paris_today() - 1, false);
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'rf3', public.request_refund('tf-rfd-0004', pg_temp.pay('10'), '3000', null, null, 'other',
                                                  null, '3000', 'payeur inconnu');
reset role;
insert into t select 'f7', (pg_temp.gen('01', 'tf-gen-0008') ->> 'file_id')::uuid;
select is((pg_temp.fl((select v from t where k = 'f7'))).pain_version, 'pain.001.001.03', 'the next file in .03');
select is(private.transfer_file_failed(f.id, f.job_token, 'Pain001Error: CdtrAcct invalid') ->> 'status', 'failed',
  'the job could not write it: failed')
from public.transfer_file f where f.id = (select v from t where k = 'f7');
select is((select string_agg(t.kind || ':' || t.status, ' ' order by t.kind) from public.transfer_file_item i
           join public.bank_transfer t on t.id = i.transfer_id where i.file_id = (select v from t where k = 'f7')),
  'refund:ordered', 'its refund ordered again, for the next file');

-- Read access --------------------------------------------------------------------------------------------------------
select pg_temp.as_user('01');
set local role authenticated;
select is((select count(*)::int from public.transfer_file), 7, 'money staff read their files');
select ok((select count(*) from public.transfer_file_item) > 0 and (select count(*) from public.transfer_file_download) = 3
          and (select count(*) from public.payee_name_check) = 1,
  'their items, downloads and payee checks');
select is((public.transfer_overview() #>> '{accounts,0,bank_account_id}'), '80000000-0000-0000-0000-0000000000cf',
  'the « Virements » overview lists the paying account');
select is((public.transfer_file_detail((select v from t where k = 'f5')) ->> 'download_count'), '1',
  'and a file''s detail');
select ok(not private.can_read_transfer_file_object((pg_temp.fl((select v from t where k = 'f1'))).storage_path)
          and not private.can_read_transfer_file_object('x/../' || (pg_temp.fl((select v from t where k = 'f5'))).storage_path)
          and not private.can_read_transfer_file_object('not a path'),
  'the bucket policy: never a superseded file (money#3), the file''s own path only');
reset role;
select pg_temp.as_user('09');
set local role authenticated;
select ok(not private.can_read_transfer_file_object((pg_temp.fl((select v from t where k = 'f5'))).storage_path),
  'nor a live file to money staff who did not just download it through the command (security#2)');
select throws_ok($$ insert into public.transfer_file_download (file_id, organization_id, n, downloaded_by,
                                                                warning_acknowledged, sha256)
                   values ((select v from t where k = 'f5'), '00000000-0000-0000-0000-0000000000aa', 9,
                           '10000000-0000-0000-0000-000000000001', true, repeat('a', 64)) $$,
  '42501', null, 'no direct write by an authenticated user');
reset role;
select pg_temp.as_user('01', 'aal1');
set local role authenticated;
select is((select count(*)::int from public.transfer_file), 0, 'not at aal1');
reset role;
select pg_temp.as_user('02');
set local role authenticated;
select is((select count(*)::int from public.transfer_file) + (select count(*)::int from public.payee_name_check), 0,
  'a collector reads no file and no payee check');
select throws_ok($$ select public.transfer_overview() $$, '42501', 'not allowed', 'nor the overview');
reset role;
select pg_temp.as_user('03');
set local role authenticated;
select is((select count(*)::int from public.transfer_file) + (select count(*)::int from public.transfer_file_item)
          + (select count(*)::int from public.bank_transfer), 0, 'Martin''s administrator reads none of it');
select ok(not private.can_read_transfer_file_object((pg_temp.fl((select v from t where k = 'f5'))).storage_path),
  'nor the file in the bucket');
reset role;
select pg_temp.as_user('07');
set local role authenticated;
select is((select count(*)::int from public.transfer_file) + (select count(*)::int from public.payee_name_check), 0,
  'nor a restricted client viewer');
reset role;
select pg_temp.as_user('08');
set local role authenticated;
select is((select count(*)::int from public.transfer_file), 0, 'nor Lilas''s administrator');
reset role;
select pg_temp.as_user('05');
set local role authenticated;
select is((select count(*)::int from public.transfer_file) + (select count(*)::int from public.transfer_file_download),
  0, 'another servicer''s staff read none of this servicer''s files');
select throws_ok(format($$ select public.transfer_file_detail(%L) $$, (select v from t where k = 'f5')),
  '42501', 'not allowed', 'nor a file''s detail');
reset role;

-- Nightly alerts (§15) -----------------------------------------------------------------------------------------------
create or replace function pg_temp.chk(p_today date) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.payment_check_run (organization_id) values ('00000000-0000-0000-0000-0000000000aa')
  returning id into v;
  perform private.run_remittance_checks(v, '00000000-0000-0000-0000-0000000000aa', p_today);
  update public.payment_check_run set finished_at = clock_timestamp() where id = v;
  return v;
end $$;
-- two weeks on: f5 downloaded, never marked sent, its sweep never debited; f7 failed, its refund still ordered
insert into t select 'c1', pg_temp.chk(private.paris_today() + 14);
select is((select string_agg(distinct r.code, ' ' order by r.code) from public.payment_check_result r
           where r.run_id = (select v from t where k = 'c1')
             and r.code in ('transfer_not_filed', 'file_not_downloaded', 'file_not_marked_sent', 'transfer_not_debited',
                            'transfer_file_failed', 'payee_name_mismatch')),
  'file_not_marked_sent transfer_file_failed transfer_not_debited transfer_not_filed',
  'two weeks on: a file downloaded not marked sent, a transfer in it never debited, a failed file, a refund not filed');
select is((select r.subject_id from public.payment_check_result r
           where r.run_id = (select v from t where k = 'c1') and r.code = 'file_not_marked_sent'),
  (select v from t where k = 'f5'), 'the alert names the file');
select is((select string_agg(r.code, ' ' order by r.code) from public.payment_check_result r
           where r.run_id = (select v from t where k = 'c1') and r.code like 'remittance_%'
             and r.subject_id = (select v from t where k = 'r2')),
  'remittance_payout_not_executed',
  'the runs'' checks still run first (private.run_remittance_runs_checks): Lilas''s run sent, its debit not booked');
select pg_temp.as_user('01');
set local role authenticated;
insert into j select 'pc2', public.record_payee_name_mismatch('tf-vop-0020', (pg_temp.tr((select v from t where k = 'r2'))).id,
  'no_match', null, 'Le nom ne correspond pas');
reset role;
insert into t select 'c2', pg_temp.chk(private.paris_today());
select is((select count(*)::int from public.payment_check_result r
           where r.run_id = (select v from t where k = 'c2') and r.code = 'payee_name_mismatch'), 1,
  'an open payee check is alerted every night until cleared');
select results_eq($$ select count(*) filter (where entry_type in ('remittance', 'servicer_sweep'))::int,
                            count(*) filter (where entry_type = 'client_settlement')::int
                     from public.ledger_entry where organization_id = '00000000-0000-0000-0000-0000000000aa' $$,
  $$ values (0, 1) $$,
  'no remittance nor sweep was booked by files, downloads or cancellations (the settlement is Cyprès''s, N = 0)');

select * from finish();
rollback;
