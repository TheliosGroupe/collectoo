-- M2c-7c-1 « client payments and refunds » (plan docs/design/m2c-7-plan.md §0 #5, §2.3, §5.0, §5.1, §5.2.1–§5.2.6, §5.2.8;
-- design docs/design/m2c-remittances.md §7.3, §12, §14.1, §16; ADR-0014 « M2c-7c-1 »). Forward-only.
--
-- What a client pays the servicer, and what the servicer pays it back:
--   * « Règlement du client » (public.record_client_payment): a client's transfer to the servicer's own account, on
--     proof, settles what the client designates ([critic] L16: with its evidence; C. civ. 1342-10 al. 1), else the
--     default order — invoices due, advances, the other invoices (our reading of 1342-10 al. 2; founder Q4, OQ-89) —,
--     each document within its open part, the VAT of each invoice part moved to due (44574 → 44571); what exceeds what
--     is open is a credit owed back to the client ([critic] M7-MONEY-10: never refused); a claim born before the
--     client's proceeding opened is never paid ([check 1] gap 11): skipped by the default order, held for the
--     procedure when the client names it ([critic] L21); a written-off advance it repays is a recovery (7714);
--   * « Règlement d'une facture ou d'une avance du cabinet » (public.book_client_payment_line): the same, received on
--     the dedicated account from the client's confirmed payout IBAN (design §12 client_transfer_in; 6b-2 S27): it
--     becomes the servicer's share (4679), swept with the next file; a label naming an invoice is the designation;
--   * « Enregistrer le remboursement » (public.record_client_refund): a credit note's refund still owed, or a credit
--     owed back, paid from the own account on proof (founder Q7);
--   * (review round 4) each dated on or after what it settles came into being: a payment settles only the invoices
--     issued, advances born and losses passed on or before its date (the default order skips what came later; one
--     the client names is refused bad_date); a refund is never dated before the credit's receipt or the credit note's
--     issue;
--   * « Ce que le client doit au cabinet » (public.client_open_documents), the payment's preview, a client's credit
--     line, the client space's credits; the nightly's client_credit_owed (alert; P0 for a sum held for a procedure),
--     client_credit_ledger and written_off_recovery_ledger (violations).
-- [check 1] gap 2: two books of the servicer's fund — 419 « Mandants — sommes à leur rembourser » (per client) and 7714
-- « Rentrées sur avances passées en perte » (pooled), Collectoo's labels the accountant maps (OQ-88, OQ-98) — and the
-- shapes that admit them (I3′): a payment wholly a credit or a recovery, the refund of a credit.
-- No R124-6 receipt: a client's payment to the servicer is not a debtor's payment (CPCE-07).
--
-- New: the tables public.client_credit and public.advance_write_off_recovery (RLS, change log, append-only, their
-- guards) and the settlements' guard of a credit's refunds; private.client_credit_open, private.written_off_available,
-- private.document_in_flight_run, private.client_opening_date ((review round 2) plan §6.2.2's, brought forward from
-- 7d-2), private.document_before_opening, private.document_client_payable,
-- private.client_proceeding_stands, private.vat_part, private.client_payment_order, private.client_payment_plan (the
-- plan's pure core; its twin remittance.client_payments.plan_client_payment), private.client_payment_considered,
-- private.client_payment_docs, private.client_payment_free, private.client_payment_recoveries,
-- private.client_settlement_plan, private.client_payment_named_refusal, private.client_line_facts,
-- private.client_payment_post, private.client_payment_rows; public.client_open_documents, public.client_payment_preview,
-- public.client_payment_line, public.client_space_credits, public.record_client_payment,
-- public.book_client_payment_line, public.record_client_refund.
-- Redefined, each copied whole from its latest definition across every migration file (indexed: the last
-- `create or replace function` of each name wins; the change only; settings, search_path '' and SECURITY DEFINER
-- where they were, grants restated): private.ledger_post_set (20261111090000:889), private.ledger_entry_verify
-- (20261111090000:295), public.ledger_balance (20261111090000:1416), public.accounting_export_entries
-- (20261116090000:4494), private.run_advance_checks (20261123090000:674, 7b's), public.register_client_document
-- (20261123090000:1701), private.can_read_client_document_object (20261123090000:1757), public.client_space_advances
-- (20261123090000:497: carried low 3, its client's advances fenced), private.advance_recovery_of (20261123090000:142:
-- (review round 3) an advance without a claw-back clause born before private.client_opening_date is barred_proceeding);
-- the constraint ledger_account_shape
-- (20261111090000:161), the policies ledger_account_read (20261111090000:1394) and document_client_money_scope
-- (20261123090000:1776), the check commission_settlement_document_kind_check (20261112090000:435); two books, the
-- allowed books of the three client-money types (20261111090000:75). Not redefined: private.bank_line_booking_guard —
-- its client_payment arm (20261121090000:784-787) already admits a client_payment_dedicated of a client_transfer_in
-- credit (045 d) —, private.transfer_line_check (its advance_settled rule: 7e-3 fences it in its redefinition, ADR).
-- The cancellation-after-download switch stays off: nothing here writes private.feature_switch.

------------------------------------------------------------------------------------------
-- The books and the types (plan §5.0 (1), (2))
------------------------------------------------------------------------------------------

-- [critic] M7-MONEY-10: client money owed back (PCG class 419 « Clients créditeurs » proposed, OQ-98) and the recovery
-- of an advance passed as a loss (PCG 7714 « Rentrées sur créances amorties » proposed, OQ-88): the numbers are
-- Collectoo's labels (`account_number` NOT NULL unique, as every book's), the accountant maps them
insert into public.ledger_book (code, account_number, label_fr, dimension, money_of, normal_side, client_visible) values
  ('client_credit_owed',    '419',  'Mandants — sommes à leur rembourser',   'client', 'servicer', -1, false),
  ('written_off_recovered', '7714', 'Rentrées sur avances passées en perte', 'pooled', 'servicer', -1, false);
comment on table public.ledger_book is
  'Chart of accounts (ARCHITECTURE §8). Two funds (M2c, ADR-0014): the dedicated-account fund (money_of client: 5120, '
  '4710, 4670, 4679) and the servicer''s fund (money_of servicer: 4689, 5122, 4111, 4112, 44571, 44574, 7060, 6270, 6780, '
  '419, 7714).';

-- the two client payments may post both (a surplus owed back, a recovery), the refund 419 (a credit paid back); no
-- other type touches either (their allowed books refuse them). advance_write_off's label is 7b's already (« Avance passée
-- en perte », LEX-28)
update public.ledger_entry_type set allowed_books = allowed_books || array['client_credit_owed', 'written_off_recovered']
where code in ('client_payment_own', 'client_payment_dedicated');
update public.ledger_entry_type set allowed_books = allowed_books || array['client_credit_owed']
where code = 'client_refund_own';

------------------------------------------------------------------------------------------
-- The ledger's write path and checks (plan §5.0 (3)–(5)): each copied whole, the two books added
------------------------------------------------------------------------------------------

-- the constraint ledger_account_shape, recreated from 20261111090000_remittance_funds.sql (line 161): 419 is per client
-- (the client set, nothing else), 7714 pooled. Nothing else changes.
alter table public.ledger_account drop constraint ledger_account_shape,
  add constraint ledger_account_shape check (case
    when book = 'debtor_receivable' then account_id is not null and claim_item_id is not null and component is not null
      and client_organization_id is not null and portfolio_id is not null and owner_organization_id is null
      and bank_account_id is null
    when book = 'owner_claim' then account_id is null and claim_item_id is null and component is not null
      and client_organization_id is not null and owner_organization_id is not null and portfolio_id is not null
      and bank_account_id is null
    when book in ('client_payable', 'servicer_revenue', 'commission_receivable', 'client_advance_receivable',
                  'client_credit_owed') then
      client_organization_id is not null and portfolio_id is null and account_id is null and claim_item_id is null
      and component is null and owner_organization_id is null and bank_account_id is null
    when book = 'unallocated_payment' then portfolio_id is null and account_id is null and claim_item_id is null
      and component is null and owner_organization_id is null and bank_account_id is null
    when book in ('client_money_cash', 'own_cash') then bank_account_id is not null and client_organization_id is null
      and owner_organization_id is null and portfolio_id is null and account_id is null and claim_item_id is null
      and component is null
    when book in ('due_to_servicer', 'due_from_client_funds', 'vat_collected', 'vat_pending', 'bank_fees',
                  'servicer_losses', 'written_off_recovered') then
      client_organization_id is null and owner_organization_id is null and portfolio_id is null and account_id is null
      and claim_item_id is null and component is null and bank_account_id is null
    else false end);

-- private.ledger_post_set, redefined from 20261111090000_remittance_funds.sql (line 889; same signature and settings,
-- its grants restated below). M2c-7c-1 (plan §5.0 (4)): 419 (client_credit_owed) joins the per-client book lists —
-- the line's client, the given-client rule, the client check — and both new books the servicer fund's closure list.
-- Deviation (ADR): a client's payment names its client whatever it settles (a recovery alone posts only 7714, a
-- pooled book). Nothing else changes.
create or replace function private.ledger_post_set()
returns table (entry_no integer, entry_id uuid, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_bad text;
begin
  -- Entries with their derived scope, in our own working table.
  drop table if exists pg_temp._lps_e;
  create temp table _lps_e on commit drop as
  select e.entry_no, e.organization_id, e.entry_type, e.effective_date, e.idempotency_key, e.account_id,
         e.client_organization_id as given_client, coalesce(a.client_organization_id, e.client_organization_id) as client_organization_id,
         e.payment_id, e.source_type, e.source_id, nullif(btrim(e.reason), '') as reason, e.engine_version, e.inputs_hash,
         a.organization_id as account_organization_id, a.status as account_status, a.portfolio_id,
         a.currency as account_currency, own.servicing_start, o.owner_organization_id,
         t.allowed_books, t.requires_reason, p.organization_id as payment_organization_id, p.currency as payment_currency,
         gen_random_uuid() as id
  from pg_temp._lps_entry e
  left join public.account a on a.id = e.account_id
  left join (select o.account_id, min(o.valid_from) as servicing_start from public.claim_ownership_period o
             where o.account_id in (select x.account_id from pg_temp._lps_entry x where x.account_id is not null)
             group by o.account_id) own on own.account_id = e.account_id
  left join public.claim_ownership_period o on o.account_id = e.account_id and o.valid_from <= e.effective_date
    and (o.valid_to is null or o.valid_to > e.effective_date)
  left join public.ledger_entry_type t on t.code = e.entry_type
  left join public.payment p on p.id = e.payment_id;
  analyze pg_temp._lps_e;

  drop table if exists pg_temp._lps_l;
  create temp table _lps_l on commit drop as
  select l.entry_no, l.line_no, l.book, l.amount_minor, l.currency, l.claim_item_id, l.component, l.bank_account_id,
         e.organization_id, e.entry_type,
         -- (M2c-7c-1) 419, the client's credits owed back, is the client's too
         case when l.book in ('debtor_receivable', 'owner_claim', 'client_payable', 'commission_receivable', 'client_advance_receivable', 'servicer_revenue',
                              'client_credit_owed')
              then e.client_organization_id end
           as client_organization_id,
         case when l.book = 'owner_claim' then e.owner_organization_id end as owner_organization_id,
         case when l.book in ('debtor_receivable', 'owner_claim') then e.portfolio_id end as portfolio_id,
         case when l.book = 'debtor_receivable' then e.account_id end as account_id
  from pg_temp._lps_line l join pg_temp._lps_e e on e.entry_no = l.entry_no;
  analyze pg_temp._lps_l;

  -- Request: types, dates, reasons, keys, lines (LG006).
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.entry_type not in ('cash_in', 'allocation', 'forward', 'cash_out', 'netting',
                             'commission_invoice', 'commission_credit_note', 'client_settlement', 'remittance', 'servicer_sweep',
                             'servicer_top_up', 'bank_fee', 'client_advance', 'servicer_loss', 'client_payment_own',
                             'client_payment_dedicated', 'client_refund_own', 'advance_write_off')
     or e.allowed_books is null;
  if v_bad is not null then
    raise exception 'ledger: entry % has a type that cannot be posted here', v_bad using errcode = 'LG006';
  end if;
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.effective_date is null or e.effective_date > private.paris_today()
     or (e.requires_reason and e.reason is null)
     or e.idempotency_key !~ '^[A-Za-z0-9:._#-]{8,200}$'
     or (e.entry_type in ('allocation', 'forward', 'cash_out')) <> (e.payment_id is not null)
     or (e.account_id is not null) <> (e.entry_type in ('allocation', 'netting'))
     -- the client is given for the entries without an account that concern one: a forward, and the M2c entries
     -- with a client line (4670, 4111, 4112, 7060, (M2c-7c-1) 419); never for the others — (M2c-7c-1) but a client's
     -- payment, which names its client whatever it settles (a recovery alone posts 7714, a pooled book)
     or (e.given_client is not null and e.account_id is null
         and e.entry_type not in ('client_payment_own', 'client_payment_dedicated')
         and not exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no
                           and l.book in ('client_payable', 'commission_receivable', 'client_advance_receivable', 'servicer_revenue',
                                          'client_credit_owed')))
     or (e.given_client is not null and e.entry_type in ('allocation', 'netting'));
  if v_bad is not null then
    raise exception 'ledger: entry % needs a past date, its reason, a valid key, and the account or payment its type requires',
      v_bad using errcode = 'LG006';
  end if;
  select min(k) into v_bad from (select e.organization_id::text || ' ' || e.idempotency_key as k from pg_temp._lps_e e
                                 group by e.organization_id, e.idempotency_key having count(*) > 1) d;
  if v_bad is not null then
    raise exception 'ledger: idempotency key % appears twice in one request', v_bad using errcode = 'LG006';
  end if;
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  left join (select l.entry_no, count(*) as n, min(l.line_no) as lo, max(l.line_no) as hi
             from pg_temp._lps_l l group by l.entry_no) c on c.entry_no = e.entry_no
  where c.n is null or c.n < 2 or c.n > 100000 or c.lo <> 1 or c.hi <> c.n;
  if v_bad is not null then
    raise exception 'ledger: entry % needs 2 to 100000 lines numbered from 1', v_bad using errcode = 'LG006';
  end if;
  select min(l.entry_no || ':' || l.line_no) into v_bad from pg_temp._lps_l l
  where l.amount_minor = 0 or abs(l.amount_minor) > 1000000000000000 or l.currency !~ '^[A-Z]{3}$'
     or (l.claim_item_id is not null) <> (l.book = 'debtor_receivable')
     or (l.component is not null) <> (l.book in ('debtor_receivable', 'owner_claim'))
     or (l.bank_account_id is not null) <> (l.book in ('client_money_cash', 'own_cash'));
  if v_bad is not null then
    raise exception 'ledger: line % needs a non-zero amount, a currency, and only the item, component or bank account of its book',
      v_bad using errcode = 'LG006';
  end if;

  -- Books allowed for the type (LG002).
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l join pg_temp._lps_e e on e.entry_no = l.entry_no
  where not (l.book = any (e.allowed_books));
  if v_bad is not null then
    raise exception 'ledger: line % uses a book not allowed for its entry type', v_bad using errcode = 'LG002';
  end if;

  -- Claims: a confirmed account of this servicer, servicing started, an owner on the date.
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.account_id is not null and (e.account_organization_id is distinct from e.organization_id
                                      or (e.given_client is not null and e.given_client <> e.client_organization_id));
  if v_bad is not null then
    raise exception 'ledger: entry % names an account outside this organization', v_bad using errcode = 'LG002';
  end if;
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where e.account_id is not null and (e.account_status = 'staged' or e.servicing_start is null
                                      or e.effective_date < e.servicing_start or e.owner_organization_id is null);
  if v_bad is not null then
    raise exception 'ledger: entry % is on an account not confirmed yet, before its servicing started, or without an owner',
      v_bad using errcode = 'LG006';
  end if;
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l join pg_temp._lps_e e on e.entry_no = l.entry_no
  left join public.claim_item i on i.id = l.claim_item_id
  where l.book in ('debtor_receivable', 'owner_claim')
    and (l.currency <> e.account_currency
         or (l.book = 'debtor_receivable' and i.account_id is distinct from e.account_id));
  if v_bad is not null then
    raise exception 'ledger: claim line % must name an item of its entry''s account, in the account''s currency', v_bad
      using errcode = 'LG002';
  end if;

  -- Clients, bank accounts and payments belong to the servicer (LG002).
  select min(e.entry_no::text) into v_bad from pg_temp._lps_e e
  where (e.client_organization_id is not null and not exists (
           select 1 from public.organization o
           where o.id = e.client_organization_id and o.servicer_organization_id = e.organization_id))
     or (exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no
                   and l.book in ('client_payable', 'commission_receivable', 'client_advance_receivable', 'servicer_revenue',
                                  'client_credit_owed'))
         and e.client_organization_id is null)
     or (e.payment_id is not null and e.payment_organization_id is distinct from e.organization_id);
  if v_bad is not null then
    raise exception 'ledger: entry % pays no client of this servicer, or names a payment of another one', v_bad
      using errcode = 'LG002';
  end if;
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l join pg_temp._lps_e e on e.entry_no = l.entry_no
  where e.payment_id is not null and l.currency <> e.payment_currency;
  if v_bad is not null then
    raise exception 'ledger: line % is not in the currency of its payment', v_bad using errcode = 'LG002';
  end if;
  -- Debtor cash only on an active account dedicated to client funds, own cash (5122) only on an active own account;
  -- a concurrent closure waits.
  perform 1 from public.bank_account b
  where b.id in (select l.bank_account_id from pg_temp._lps_l l where l.bank_account_id is not null)
  order by b.id for share;
  select min(l.entry_no || ':' || l.line_no) into v_bad
  from pg_temp._lps_l l left join public.bank_account b on b.id = l.bank_account_id
  where l.book in ('client_money_cash', 'own_cash')
    and (b.id is null or b.organization_id <> l.organization_id or b.currency <> l.currency
         or b.purpose <> case l.book when 'client_money_cash' then 'client_funds' else 'own' end
         or b.status <> 'active');
  if v_bad is not null then
    raise exception 'ledger: line % is not on an active bank account of its purpose of this servicer (R124-2)', v_bad
      using errcode = 'LG002';
  end if;

  -- Fail fast (the deferred check is the backstop): balanced, receivable mirror, each fund closed (I2′), the
  -- 4679 / 4689 mirror (I12) (LG001).
  select min(k) into v_bad from (
    select l.entry_no || ' ' || l.currency as k from pg_temp._lps_l l
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' ' || l.component || ' ' || l.currency from pg_temp._lps_l l
    where l.book in ('debtor_receivable', 'owner_claim')
    group by l.entry_no, l.component, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' client fund ' || l.currency from pg_temp._lps_l l
    where l.book in ('client_money_cash', 'unallocated_payment', 'client_payable', 'due_to_servicer')
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' servicer fund ' || l.currency from pg_temp._lps_l l
    where l.book in ('due_from_client_funds', 'own_cash', 'commission_receivable', 'client_advance_receivable',
                     'vat_collected', 'vat_pending', 'servicer_revenue', 'bank_fees', 'servicer_losses',
                     'client_credit_owed', 'written_off_recovered')
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0
    union all
    select l.entry_no || ' 4679/4689 ' || l.currency from pg_temp._lps_l l
    where l.book in ('due_to_servicer', 'due_from_client_funds')
    group by l.entry_no, l.currency having sum(l.amount_minor) <> 0) x;
  if v_bad is not null then
    raise exception 'ledger: entry % is not balanced, breaks a mirror, or leaves a fund open', v_bad
      using errcode = 'LG001';
  end if;

  -- Whatever lowers a payment's remainder or a receivable, and every entry that moves 4670 (decided by its lines, not
  -- its type: the pending queue is read under this lock, M2c §5.5), waits for the servicer's allocation lock; then
  -- every writer of 4679 takes the remit lock. Order: allocation lock, then remit lock (then the invoice counter).
  perform pg_advisory_xact_lock(hashtext('payments:' || x.org))
  from (select distinct e.organization_id::text as org from pg_temp._lps_e e
        where e.entry_type in ('allocation', 'forward', 'cash_out', 'netting')
           or exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no and l.book = 'client_payable')
        order by 1) x;
  perform pg_advisory_xact_lock(hashtext('remit:' || x.org))
  from (select distinct e.organization_id::text as org from pg_temp._lps_e e
        where exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no and l.book = 'due_to_servicer')
        order by 1) x;

  -- Get or create the ledger accounts.
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                     account_id, claim_item_id, component)
  select distinct l.organization_id, 'debtor_receivable', l.currency, l.client_organization_id, l.portfolio_id,
         l.account_id, l.claim_item_id, l.component
  from pg_temp._lps_l l where l.book = 'debtor_receivable'
  on conflict (claim_item_id, component) do nothing;
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, owner_organization_id,
                                     portfolio_id, component, bank_account_id)
  select distinct l.organization_id, l.book, l.currency, l.client_organization_id, l.owner_organization_id,
         l.portfolio_id, l.component, l.bank_account_id
  from pg_temp._lps_l l where l.book <> 'debtor_receivable'
  on conflict (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component,
               bank_account_id)
    where claim_item_id is null do nothing;

  -- Pooled ledger accounts: a few distinct dimensions, each found by the unique index prefix.
  drop table if exists pg_temp._lps_dim;
  create temp table _lps_dim on commit drop as
  select d.*, (select la.id from public.ledger_account la
               where la.organization_id = d.organization_id and la.book = d.book and la.currency = d.currency
                 and la.claim_item_id is null
                 and la.client_organization_id is not distinct from d.client_organization_id
                 and la.owner_organization_id is not distinct from d.owner_organization_id
                 and la.portfolio_id is not distinct from d.portfolio_id
                 and la.component is not distinct from d.component
                 and la.bank_account_id is not distinct from d.bank_account_id) as ledger_account_id
  from (select distinct l.organization_id, l.book, l.currency, l.client_organization_id, l.owner_organization_id,
               l.portfolio_id, l.component, l.bank_account_id
        from pg_temp._lps_l l where l.book <> 'debtor_receivable') d;

  drop table if exists pg_temp._lps_x;
  create temp table _lps_x on commit drop as
  select l.entry_no, l.line_no, l.amount_minor, l.currency, coalesce(r.id, d.ledger_account_id) as ledger_account_id
  from pg_temp._lps_l l
  left join public.ledger_account r on l.book = 'debtor_receivable' and r.claim_item_id = l.claim_item_id
    and r.component = l.component
  left join pg_temp._lps_dim d on l.book <> 'debtor_receivable' and d.organization_id = l.organization_id
    and d.book = l.book and d.currency = l.currency
    and d.client_organization_id is not distinct from l.client_organization_id
    and d.owner_organization_id is not distinct from l.owner_organization_id
    and d.portfolio_id is not distinct from l.portfolio_id
    and d.component is not distinct from l.component
    and d.bank_account_id is not distinct from l.bank_account_id;
  if exists (select 1 from pg_temp._lps_x where ledger_account_id is null)
     or (select count(*) from pg_temp._lps_x) <> (select count(*) from pg_temp._lps_l) then
    raise exception 'ledger: lines without their ledger accounts' using errcode = 'LG006';
  end if;
  analyze pg_temp._lps_x;

  -- Canonical request hash per entry: line order does not matter.
  drop table if exists pg_temp._lps_h;
  create temp table _lps_h on commit drop as
  select e.entry_no, c.line_count,
         encode(sha256(convert_to(jsonb_build_object(
           'type', e.entry_type,
           'effective_date', e.effective_date,
           'account_id', e.account_id,
           'client_organization_id', e.client_organization_id,
           'payment_id', e.payment_id,
           'source', jsonb_build_array(e.source_type, e.source_id),
           'reason', e.reason,
           'engine', jsonb_build_array(e.engine_version, e.inputs_hash),
           'lines', c.lines)::text, 'UTF8')), 'hex') as request_hash
  from pg_temp._lps_e e
  join (select x.entry_no, count(*)::integer as line_count,
               jsonb_agg(jsonb_build_array(x.ledger_account_id, x.currency, x.amount_minor)
                         order by x.ledger_account_id, x.amount_minor) as lines
        from pg_temp._lps_x x group by x.entry_no) c on c.entry_no = e.entry_no;

  drop table if exists pg_temp._lps_new;
  create temp table _lps_new (id uuid primary key) on commit drop;
  with ins as (
    insert into public.ledger_entry (id, organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                     effective_date, line_count, idempotency_key, request_hash, payment_id, source_type,
                                     source_id, reason, engine_version, inputs_hash)
    select e.id, e.organization_id, e.client_organization_id, e.portfolio_id, e.account_id, e.entry_type,
           e.effective_date, h.line_count, e.idempotency_key, h.request_hash, e.payment_id, e.source_type,
           e.source_id, e.reason, e.engine_version, e.inputs_hash
    from pg_temp._lps_e e join pg_temp._lps_h h on h.entry_no = e.entry_no
    order by e.entry_no
    on conflict (organization_id, idempotency_key) do nothing
    returning id
  )
  insert into pg_temp._lps_new select ins.id from ins;

  -- A key already used: the same request returns its entry, another request is refused.
  select min(e.idempotency_key) into v_bad
  from pg_temp._lps_e e
  join pg_temp._lps_h h on h.entry_no = e.entry_no
  join public.ledger_entry x on x.organization_id = e.organization_id and x.idempotency_key = e.idempotency_key
  where not exists (select 1 from pg_temp._lps_new n where n.id = e.id) and x.request_hash <> h.request_hash;
  if v_bad is not null then
    raise exception 'ledger: idempotency key % was used for a different request', v_bad using errcode = 'LG004';
  end if;

  insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
  select e.id, x.line_no, x.ledger_account_id, x.amount_minor, x.currency, e.effective_date
  from pg_temp._lps_e e
  join pg_temp._lps_new n on n.id = e.id
  join pg_temp._lps_x x on x.entry_no = e.entry_no;

  -- Every pending check now (balance, mirror, closure, shapes, payments, receivables): a refused
  -- request fails here, inside the caller's call, with its SQLSTATE.
  set constraints public.ledger_entry_balanced immediate;
  set constraints public.ledger_entry_balanced deferred;

  return query
  select e.entry_no, coalesce(n.id, x.id), n.id is not null
  from pg_temp._lps_e e
  left join pg_temp._lps_new n on n.id = e.id
  left join public.ledger_entry x on n.id is null and x.organization_id = e.organization_id
    and x.idempotency_key = e.idempotency_key
  order by e.entry_no;
end;
$$;

-- private.ledger_entry_verify, redefined from 20261111090000_remittance_funds.sql (line 295; same signature and
-- settings; a trigger's function, no grant). M2c-7c-1 (plan §5.0 (5), [check 1] gap 2): two counts, n_cco / d_cco
-- (419) and n_rec / d_rec (7714); client_payment_own and client_payment_dedicated admit at most one credit of each
-- (never a debit) besides 4111 and 4112, at least one of the four; client_refund_own pays back a credit note's refund
-- (+4111) or a credit owed back (+419), exactly one of them. I2′ reads money_of: no change. Nothing else changes.
create or replace function private.ledger_entry_verify()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_lines bigint;
  v_cur text;
  v_bad text;
  v_pay public.payment;
  v_ok boolean;
  v_shape record;
  f record;
begin
  select coalesce(sum(n), 0), min(currency) filter (where s <> 0) into v_lines, v_cur
  from (select currency, count(*) n, sum(amount_minor) s from public.ledger_posting
        where entry_id = new.id group by currency) x;
  if v_lines <> new.line_count then
    raise exception 'ledger: entry % has % of its % lines', new.id, v_lines, new.line_count using errcode = 'LG001';
  end if;
  if v_cur is not null then
    raise exception 'ledger: entry % is not balanced in %', new.id, v_cur using errcode = 'LG001';
  end if;
  -- Receivable and owner claim move by opposite amounts per (component, currency).
  -- One key lookup per line (a hash join would scan every ledger account for every entry).
  select min(y.k) into v_bad from (
    select x.component || ' ' || x.currency as k
    from (select p.currency, p.amount_minor,
                 (select la.component from public.ledger_account la
                  where la.id = p.ledger_account_id and la.book in ('debtor_receivable', 'owner_claim')) as component
          from public.ledger_posting p where p.entry_id = new.id) x
    where x.component is not null
    group by x.component, x.currency having sum(x.amount_minor) <> 0) y;
  if v_bad is not null then
    raise exception 'ledger: entry % breaks the receivable/owner-claim mirror (%)', new.id, v_bad using errcode = 'LG001';
  end if;
  -- A reversal negates the reversed entry line by line, on the same ledger accounts.
  if new.reverses_entry_id is not null and exists (
    select 1
    from (select line_no, ledger_account_id, amount_minor from public.ledger_posting where entry_id = new.id) r
    full join (select line_no, ledger_account_id, amount_minor from public.ledger_posting
               where entry_id = new.reverses_entry_id) o using (line_no)
    where r.ledger_account_id is distinct from o.ledger_account_id or r.amount_minor is distinct from -o.amount_minor
  ) then
    raise exception 'ledger: reversal % does not mirror entry %', new.id, new.reverses_entry_id using errcode = 'LG003';
  end if;
  if new.entry_type = 'opening' then
    return null;  -- claim books only, on new ledger accounts: nothing below applies
  end if;

  -- I2′: each fund is closed in every entry, per currency — the client fund (5120, 4710, 4670, 4679) and the servicer's
  -- fund (5122, 4111, 4112, 44571, 44574, 4689, 7060, 6270, 6780). I12: Σ4679 + Σ4689 = 0, per currency (the only way
  -- money crosses between the funds). One pass over the entry's postings, each account and book by its key.
  select min(case when y.money_of in ('client', 'servicer') and y.s <> 0 then y.money_of || ' fund in ' || y.currency
                  when y.mm <> 0 then '4679/4689 mirror in ' || y.currency end)
  into v_bad
  from (select g.money_of, g.s, sum(g.m) over (partition by g.currency) as mm, g.currency
        from (select p.currency, a.money_of, sum(p.amount_minor) as s,
                     coalesce(sum(p.amount_minor) filter (where a.book in ('due_to_servicer', 'due_from_client_funds')), 0)
                       as m
              from public.ledger_posting p
              cross join lateral (select la.book,
                                         (select b.money_of from public.ledger_book b where b.code = la.book) as money_of
                                  from public.ledger_account la where la.id = p.ledger_account_id offset 0) a
              where p.entry_id = new.id
              group by p.currency, a.money_of) g) y;
  if v_bad is not null then
    raise exception 'ledger: entry % leaves the % open (closure per fund, mirror 4679/4689)', new.id, v_bad
      using errcode = 'LG001';
  end if;

  -- I3: the shape of each payment entry type (4710 lines are on the pooled account).
  if new.entry_type in ('cash_in', 'allocation', 'forward', 'cash_out', 'netting') then
    select count(*) as n,
           count(*) filter (where x.book = 'client_money_cash' and x.amount_minor > 0) as cash_dr,
           count(*) filter (where x.book = 'client_money_cash' and x.amount_minor < 0) as cash_cr,
           count(*) filter (where x.book = 'unallocated_payment') as pool_n,
           count(*) filter (where x.book = 'unallocated_payment' and x.client_organization_id is null
                            and x.amount_minor > 0) as pool_dr,
           count(*) filter (where x.book = 'unallocated_payment' and x.client_organization_id is null
                            and x.amount_minor < 0) as pool_cr,
           count(*) filter (where x.book = 'client_payable') as pay_n,
           count(*) filter (where x.book = 'client_payable' and x.amount_minor < 0) as pay_cr,
           count(*) filter (where x.book = 'debtor_receivable' and x.amount_minor < 0) as rec_cr,
           count(*) filter (where x.book = 'debtor_receivable' and x.amount_minor > 0) as rec_dr,
           count(*) filter (where x.book = 'owner_claim' and x.amount_minor > 0) as own_dr,
           count(*) filter (where x.component is distinct from 'principal') as not_principal,
           coalesce(sum(x.amount_minor) filter (where x.book = 'unallocated_payment'), 0) as s_pool,
           coalesce(sum(x.amount_minor) filter (where x.book = 'debtor_receivable'), 0) as s_rec
    into v_shape
    from (select p.amount_minor, la.book, la.client_organization_id, la.component
          from public.ledger_posting p
          cross join lateral (select l.book, l.client_organization_id, l.component
                              from public.ledger_account l where l.id = p.ledger_account_id offset 0) la
          where p.entry_id = new.id) x;
    v_ok := case new.entry_type
      when 'cash_in' then v_shape.n = 2 and v_shape.cash_dr = 1 and v_shape.pool_cr = 1
      when 'cash_out' then v_shape.n = 2 and v_shape.pool_dr = 1 and v_shape.cash_cr = 1
      when 'forward' then v_shape.n = 2 and v_shape.pool_dr = 1 and v_shape.pay_cr = 1
      when 'allocation' then v_shape.pool_n = 1 and v_shape.pool_dr = 1 and v_shape.pay_n = 1 and v_shape.pay_cr = 1 and v_shape.rec_cr >= 1
        and v_shape.rec_dr = 0 and v_shape.n = 2 + v_shape.rec_cr + v_shape.own_dr
        -- the debt goes down by exactly the money allocated (no rounding gap, no free extinction)
        and v_shape.s_rec = -v_shape.s_pool
      when 'netting' then v_shape.not_principal = 0
    end;
    if not v_ok then
      raise exception 'ledger: entry % does not have the shape of a % entry', new.id, new.entry_type using errcode = 'LG001';
    end if;
  end if;

  -- I3′: the shapes of the M2c types (§5.2; + debit, − credit), in one currency. n_<book>: lines on the book, d_<book>:
  -- of which debits. With I2′ and I12 they fix every amount (e.g. a sweep's four lines are all S).
  if new.entry_type in ('commission_invoice', 'commission_credit_note', 'client_settlement', 'remittance', 'servicer_sweep',
                        'servicer_top_up', 'bank_fee', 'client_advance', 'servicer_loss', 'client_payment_own',
                        'client_payment_dedicated', 'client_refund_own', 'advance_write_off') then
    select count(*) as n, count(distinct x.currency) as ncur,
           count(*) filter (where x.book = 'client_money_cash') as n_cash,
           count(*) filter (where x.book = 'client_money_cash' and x.amount_minor > 0) as d_cash,
           count(*) filter (where x.book = 'client_payable') as n_pay,
           count(*) filter (where x.book = 'client_payable' and x.amount_minor > 0) as d_pay,
           count(*) filter (where x.book = 'due_to_servicer') as n_dts,
           count(*) filter (where x.book = 'due_to_servicer' and x.amount_minor > 0) as d_dts,
           count(*) filter (where x.book = 'due_from_client_funds') as n_dfc,
           count(*) filter (where x.book = 'due_from_client_funds' and x.amount_minor > 0) as d_dfc,
           count(*) filter (where x.book = 'own_cash') as n_own,
           count(*) filter (where x.book = 'own_cash' and x.amount_minor > 0) as d_own,
           count(*) filter (where x.book = 'commission_receivable') as n_com,
           count(*) filter (where x.book = 'commission_receivable' and x.amount_minor > 0) as d_com,
           count(*) filter (where x.book = 'client_advance_receivable') as n_adv,
           count(*) filter (where x.book = 'client_advance_receivable' and x.amount_minor > 0) as d_adv,
           count(*) filter (where x.book = 'servicer_revenue') as n_rev,
           count(*) filter (where x.book = 'servicer_revenue' and x.amount_minor > 0) as d_rev,
           count(*) filter (where x.book = 'vat_pending') as n_vatp,
           count(*) filter (where x.book = 'vat_pending' and x.amount_minor > 0) as d_vatp,
           count(*) filter (where x.book = 'vat_collected') as n_vatc,
           count(*) filter (where x.book = 'vat_collected' and x.amount_minor > 0) as d_vatc,
           count(*) filter (where x.book = 'bank_fees' and x.amount_minor > 0) as d_fee,
           count(*) filter (where x.book = 'servicer_losses' and x.amount_minor > 0) as d_loss,
           -- (M2c-7c-1) 419, the client's credits owed back, and 7714, the recovery of an advance passed as a loss
           count(*) filter (where x.book = 'client_credit_owed') as n_cco,
           count(*) filter (where x.book = 'client_credit_owed' and x.amount_minor > 0) as d_cco,
           count(*) filter (where x.book = 'written_off_recovered') as n_rec,
           count(*) filter (where x.book = 'written_off_recovered' and x.amount_minor > 0) as d_rec,
           coalesce(sum(x.amount_minor) filter (where x.book in ('vat_pending', 'vat_collected')), 0) as s_vat
    into f
    from (select p.amount_minor, p.currency, la.book
          from public.ledger_posting p
          cross join lateral (select l.book from public.ledger_account l where l.id = p.ledger_account_id offset 0) la
          where p.entry_id = new.id) x;
    v_ok := f.ncur = 1 and case new.entry_type
      -- +4111[c] TTC / −7060[c] HT / −44574 VAT (−44571 when the servicer opted for débits); no VAT line when it is 0
      when 'commission_invoice' then f.n_com = 1 and f.d_com = 1 and f.n_rev = 1 and f.d_rev = 0
        and f.n_vatp + f.n_vatc <= 1 and f.d_vatp = 0 and f.d_vatc = 0 and f.n = 2 + f.n_vatp + f.n_vatc
      -- −4111[c] TTC / +7060[c] HT / +44574 v₁ / +44571 v₂
      when 'commission_credit_note' then f.n_com = 1 and f.d_com = 0 and f.n_rev = 1 and f.d_rev = 1
        and f.n_vatp <= 1 and f.n_vatc <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = f.n_vatc
        and f.n = 2 + f.n_vatp + f.n_vatc
      -- +4670[c] D / −4679 D ‖ +4689 D / −4111[c] Dc / −4112[c] Da; one VAT pair +44574 v / −44571 v; D = Dc + Da
      when 'client_settlement' then f.n_pay = 1 and f.n_dts = 1 and f.n_dfc = 1
        and f.n_com <= 1 and f.n_adv <= 1 and f.n_com + f.n_adv >= 1 and f.d_adv = 0
        and f.n_vatp = f.n_vatc and f.n_vatp <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = 0 and f.s_vat = 0
        and f.n = 3 + f.n_com + f.n_adv + f.n_vatp + f.n_vatc
      -- +4670[c] N / −5120[b] N
      when 'remittance' then f.n = 2 and f.n_pay = 1 and f.d_pay = 1 and f.n_cash = 1 and f.d_cash = 0
      -- +4679 S / −5120[b] S ‖ +5122[own] S / −4689 S
      when 'servicer_sweep' then f.n = 4 and f.n_dts = 1 and f.d_dts = 1 and f.n_cash = 1 and f.d_cash = 0
        and f.n_own = 1 and f.d_own = 1 and f.n_dfc = 1 and f.d_dfc = 0
      -- +5120[b] T / −4679 T ‖ +4689 T / −5122[own] T
      when 'servicer_top_up' then f.n = 4 and f.n_cash = 1 and f.d_cash = 1 and f.n_dts = 1 and f.d_dts = 0
        and f.n_dfc = 1 and f.d_dfc = 1 and f.n_own = 1 and f.d_own = 0
      -- +4679 F / −5120[b] F ‖ +6270 F / −4689 F
      when 'bank_fee' then f.n = 4 and f.n_dts = 1 and f.d_dts = 1 and f.n_cash = 1 and f.d_cash = 0
        and f.d_fee = 1 and f.n_dfc = 1 and f.d_dfc = 0
      -- +4679 A / −4670[c] A ‖ +4112[c] A / −4689 A
      when 'client_advance' then f.n = 4 and f.n_dts = 1 and f.d_dts = 1 and f.n_pay = 1 and f.d_pay = 0
        and f.n_adv = 1 and f.d_adv = 1 and f.n_dfc = 1 and f.d_dfc = 0
      -- +4679 X / −5120[b] X ‖ +6780 X / −4689 X
      when 'servicer_loss' then f.n = 4 and f.n_dts = 1 and f.d_dts = 1 and f.n_cash = 1 and f.d_cash = 0
        and f.d_loss = 1 and f.n_dfc = 1 and f.d_dfc = 0
      -- +5122[own] P / −4111[c] / −4112[c] / (M2c-7c-1) −419[c] surplus / −7714 recovery; VAT pair
      when 'client_payment_own' then f.n_own = 1 and f.d_own = 1
        and f.n_com <= 1 and f.d_com = 0 and f.n_adv <= 1 and f.d_adv = 0
        and f.n_cco <= 1 and f.d_cco = 0 and f.n_rec <= 1 and f.d_rec = 0
        and f.n_com + f.n_adv + f.n_cco + f.n_rec >= 1
        and f.n_vatp = f.n_vatc and f.n_vatp <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = 0 and f.s_vat = 0
        and f.n = 1 + f.n_com + f.n_adv + f.n_cco + f.n_rec + f.n_vatp + f.n_vatc
      -- +5120[b] P / −4679 P ‖ +4689 P / −4111[c] / −4112[c] / (M2c-7c-1) −419[c] / −7714; VAT pair
      when 'client_payment_dedicated' then f.n_cash = 1 and f.d_cash = 1 and f.n_dts = 1 and f.d_dts = 0
        and f.n_dfc = 1 and f.d_dfc = 1
        and f.n_com <= 1 and f.d_com = 0 and f.n_adv <= 1 and f.d_adv = 0
        and f.n_cco <= 1 and f.d_cco = 0 and f.n_rec <= 1 and f.d_rec = 0
        and f.n_com + f.n_adv + f.n_cco + f.n_rec >= 1
        and f.n_vatp = f.n_vatc and f.n_vatp <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = 0 and f.s_vat = 0
        and f.n = 3 + f.n_com + f.n_adv + f.n_cco + f.n_rec + f.n_vatp + f.n_vatc
      -- +4111[c] R (a credit note's refund) or (M2c-7c-1) +419[c] R (a credit owed back) / −5122[own] R
      when 'client_refund_own' then f.n = 2 and f.n_own = 1 and f.d_own = 0
        and ((f.n_com = 1 and f.d_com = 1 and f.n_cco = 0) or (f.n_cco = 1 and f.d_cco = 1 and f.n_com = 0))
      -- +6780 W / −4112[c] W
      when 'advance_write_off' then f.n = 2 and f.d_loss = 1 and f.n_adv = 1 and f.d_adv = 0
    end;
    if not v_ok then
      raise exception 'ledger: entry % does not have the shape of a % entry', new.id, new.entry_type using errcode = 'LG001';
    end if;
  end if;

  -- I4: per payment, at every date, what is left of it is never negative; per (payment, account),
  -- the net amount allocated is never negative. A payment has a handful of entries.
  if new.payment_id is not null then
    select * into v_pay from public.payment where id = new.payment_id;
    select min(p.currency) into v_bad from public.ledger_posting p
    where p.entry_id = new.id and p.currency <> v_pay.currency;
    if v_bad is not null then
      raise exception 'ledger: entry % moves % for a payment in %', new.id, v_bad, v_pay.currency using errcode = 'LG002';
    end if;
    with t as (
      select e.effective_date as d, e.account_id,
             coalesce((select sum(x.amount_minor) from public.ledger_posting x
                       where x.entry_id = e.id
                         and (select la.book from public.ledger_account la where la.id = x.ledger_account_id)
                             = 'unallocated_payment'), 0) as pool
      from public.ledger_entry e where e.payment_id = new.payment_id
    ),
    per_day as (select d, sum(pool) as pool from t group by d),
    per_account as (select d, account_id, sum(pool) as pool from t group by d, account_id),
    left_over as (
      select d, case when d >= v_pay.booking_date then v_pay.amount_minor else 0 end
                - sum(pool) over (order by d) as u
      from per_day),
    net as (select d, sum(pool) over (partition by account_id order by d) as allocated from per_account)
    select min(z.d)::text into v_bad
    from (select d from left_over where u < 0 union all select d from net where allocated < 0) z;
    if v_bad is not null then
      raise exception 'ledger: payment % would be overdrawn on % (entry %)', new.payment_id, v_bad, new.id
        using errcode = 'LG007';
    end if;
  end if;

  -- I6: a receivable credited by an allocation or a netting dated D never goes below zero from D
  -- on; a credit item debited by a netting dated D never goes above zero from D on. Checked for
  -- every entry that moves such a receivable (corrections and reversals included), so it holds
  -- after any sequence of entries.
  if new.entry_type in ('allocation', 'netting', 'adjustment', 'reversal') then
    select min(x.ledger_account_id::text) into v_bad
    from (
      select a.ledger_account_id, a.has_cr, a.has_dr,
             (select min(q.effective_date) from public.ledger_posting q
              where q.ledger_account_id = a.ledger_account_id and q.amount_minor < 0
                and (select e.entry_type from public.ledger_entry e where e.id = q.entry_id)
                    in ('allocation', 'netting')) as d_cr,
             (select min(q.effective_date) from public.ledger_posting q
              where q.ledger_account_id = a.ledger_account_id and q.amount_minor > 0
                and (select e.entry_type from public.ledger_entry e where e.id = q.entry_id) = 'netting') as d_dr
      from (select p.ledger_account_id, bool_or(p.amount_minor < 0) as has_cr, bool_or(p.amount_minor > 0) as has_dr
            from public.ledger_posting p
            where p.entry_id = new.id
              and (select la.book from public.ledger_account la where la.id = p.ledger_account_id) = 'debtor_receivable'
            group by p.ledger_account_id) a
    ) x
    cross join lateral (
      select min(r.bal) filter (where r.d >= x.d_cr) as low, max(r.bal) filter (where r.d >= x.d_dr) as high
      from (select g.d, sum(g.s) over (order by g.d) as bal
            from (select q.effective_date as d, sum(q.amount_minor) as s from public.ledger_posting q
                  where q.ledger_account_id = x.ledger_account_id group by q.effective_date) g) r
    ) w
    where (x.has_cr and x.d_cr is not null and w.low < 0)
       or (x.has_dr and x.d_dr is not null and w.high > 0);
    if v_bad is not null then
      raise exception 'ledger: entry % would overdraw receivable %', new.id, v_bad using errcode = 'LG007';
    end if;
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- The reads of the ledger (plan §5.0 (6)): money staff read both books; the export lists them
------------------------------------------------------------------------------------------

-- the policy ledger_account_read, recreated from 20261111090000_remittance_funds.sql (line 1394): money staff read the
-- two books (a client reads its credits owed back as public.client_credit rows, never its 419 account). Nothing else
-- changes.
drop policy ledger_account_read on public.ledger_account;
create policy ledger_account_read on public.ledger_account for select to authenticated using (
  portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])
  or (portfolio_id is null
      and book in ('client_money_cash', 'unallocated_payment', 'client_payable', 'due_to_servicer',
                   'due_from_client_funds', 'own_cash', 'commission_receivable', 'client_advance_receivable',
                   'vat_collected', 'vat_pending', 'servicer_revenue', 'bank_fees', 'servicer_losses',
                   -- (M2c-7c-1) the client's credits owed back (419), the recoveries (7714): money staff only
                   'client_credit_owed', 'written_off_recovered')
      and organization_id = any ((select private.money_staff_org_ids())::uuid[]))
  or (portfolio_id is null and book = 'client_payable'
      and client_organization_id = any ((select private.client_whole_org_ids())::uuid[])));

-- public.ledger_balance, redefined from 20261111090000_remittance_funds.sql (line 1416; same signature and settings,
-- its grants restated below): the same rule for a balance asked by id. Nothing else changes.
create or replace function public.ledger_balance(p_ledger_account_id uuid, p_as_of date default null,
                                                 p_known_at timestamptz default null)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.ledger_account la
    where la.id = p_ledger_account_id
      and ((la.portfolio_id is not null and private.can_read_portfolio(la.portfolio_id))
           or (la.portfolio_id is null
               and la.book in ('client_money_cash', 'unallocated_payment', 'client_payable', 'due_to_servicer',
                               'due_from_client_funds', 'own_cash', 'commission_receivable', 'client_advance_receivable',
                               'vat_collected', 'vat_pending', 'servicer_revenue', 'bank_fees', 'servicer_losses',
                               'client_credit_owed', 'written_off_recovered')
               and la.organization_id = any (private.money_staff_org_ids()))
           or (la.portfolio_id is null and la.book = 'client_payable'
               and la.client_organization_id = any (private.client_whole_org_ids())))
  ) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return private.ledger_balance(p_ledger_account_id, coalesce(p_as_of, private.paris_today()), p_known_at);
end;
$$;

-- public.accounting_export_entries, redefined from 20261116090000_debit_bookings.sql (line 4494; same signature and
-- settings, its grants restated below). M2c-7c-1 (plan §5.0 (6)): the servicer fund's book list gains 419 and 7714, so
-- a client's payment with a surplus or a recovery, and a refund of a credit, balance in the export. Nothing else
-- changes.
create or replace function public.accounting_export_entries(p_from date, p_to date, p_after text default null,
                                                           p_limit integer default 1000)
returns table (effective_date date, entry_id uuid, entry_type text, source_type text, source_ref text,
               client_name text, account_number text, book text, debit_minor bigint, credit_minor bigint,
               currency char(3), posted_at timestamptz, page_key text)
language plpgsql
stable
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
set enable_seqscan = off
as $$
declare
  v_org uuid := (private.money_staff_org_ids())[1];
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 1000);
  v_date date;
  v_posted timestamptz;
  v_entry uuid;
  v_line integer;
begin
  if v_org is null then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'accounting export refused: period' using errcode = '22023';
  end if;
  if p_after is not null then
    begin
      v_date := split_part(p_after, '|', 1)::date;
      v_posted := (split_part(p_after, '|', 2) || '+00')::timestamptz;
      v_entry := split_part(p_after, '|', 3)::uuid;
      v_line := split_part(p_after, '|', 4)::integer;
    exception when others then
      raise exception 'accounting export refused: page' using errcode = '22023';
    end;
  end if;
  return query
  select p.effective_date, e.id, e.entry_type, e.source_type,
         coalesce(case e.source_type
                    when 'commission_invoice'
                      then (select i.number from public.commission_invoice i where i.id = e.source_id::uuid)
                    when 'remittance_run'
                      then (select x.number from public.remittance_run x where x.id = e.source_id::uuid)
                    -- M2c-6b-1 (plan §2.5 [critic], R123-174): our transfer by its end-to-end id, a bank line by its
                    -- bank reference, an advance by its cause
                    when 'bank_transfer'
                      then (select x.end_to_end_id from public.bank_transfer x where x.id = e.source_id::uuid)
                    when 'bank_transaction'
                      then (select coalesce(x.acct_svcr_ref, x.entry_ref, x.end_to_end_id, x.payment_info_id)
                            from public.bank_transaction x where x.id = e.source_id::uuid)
                    when 'client_advance'
                      then (select 'Avance ' || case x.cause when 'payout_overrun' then 'reversement au-delà du dû'
                                                             when 'double_payout' then 'reversement en double'
                                                             else 'retour après reversement' end
                            from public.client_advance x where x.id = e.source_id::uuid) end,
                  e.source_id),
         (select o.legal_name from public.organization o where o.id = la.client_organization_id),
         b.account_number, la.book,
         case when p.amount_minor > 0 then p.amount_minor else 0 end::bigint,
         case when p.amount_minor < 0 then -p.amount_minor else 0 end::bigint,
         p.currency, e.posted_at,
         to_char(p.effective_date, 'YYYY-MM-DD') || '|'
           || to_char(e.posted_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' || e.id::text || '|'
           || lpad(p.line_no::text, 6, '0')
  from public.ledger_account la
  cross join lateral (select q.account_number from public.ledger_book q where q.code = la.book offset 0) b
  cross join lateral (select q.* from public.ledger_posting q
                      where q.ledger_account_id = la.id
                        and q.effective_date between greatest(p_from, coalesce(v_date, p_from)) and p_to
                      offset 0) p
  cross join lateral (select q.* from public.ledger_entry q where q.id = p.entry_id offset 0) e
  where la.organization_id = v_org and la.claim_item_id is null
    and la.book in ('servicer_revenue', 'vat_collected', 'vat_pending', 'bank_fees', 'servicer_losses',
                    'commission_receivable', 'client_advance_receivable', 'own_cash',
                    -- (M2c-7c-1) the client's credits owed back (419) and the recoveries (7714): a client's payment
                    -- or refund balances in the export
                    'client_credit_owed', 'written_off_recovered')
    and (p_after is null or (p.effective_date, e.posted_at, e.id, p.line_no) > (v_date, v_posted, v_entry, v_line))
  order by p.effective_date, e.posted_at, e.id, p.line_no
  limit v_limit;
end;
$$;

------------------------------------------------------------------------------------------
-- What the servicer owes a client back, and what it recovers of an advance passed as a loss (plan §5.1)
------------------------------------------------------------------------------------------

-- A settlement may now be a client credit's refund (record_client_refund): its document kind
alter table public.commission_settlement drop constraint commission_settlement_document_kind_check,
  add constraint commission_settlement_document_kind_check
    check (document_kind in ('invoice', 'credit_note', 'advance', 'client_credit'));

-- [critic] M7-MONEY-10, L7, L21: client money the servicer owes back — what a client paid beyond what was open (a
-- document a run had already settled included: `overpayment`), or what a client in a collective proceeding paid for a
-- claim born before its opening, or beyond what it may pay while the proceeding stands, held for the procedure
-- (`procedure`: L622-7 I, III; OQ-98). [check 1] gap 8: at most one row per cause of a payment (entry_id, cause); the
-- payment's single −419 line is their sum (the guard below). Its open part = amount − Σ its refunds
-- (commission_settlement of document_kind client_credit, kind refund). `details` (cause procedure): the documents the
-- client named and the part it meant for each, amounts as text. Append-only.
create table public.client_credit (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  currency char(3) not null references public.currency (code),
  cause text not null check (cause in ('overpayment', 'procedure')),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  entry_id uuid not null references public.ledger_entry (id),      -- the client's payment that posted its −419 line
  details jsonb check (details is null or jsonb_typeof(details) = 'array'),
  created_at timestamptz not null default clock_timestamp(),
  constraint client_credit_entry_cause_uq unique (entry_id, cause)
);
create index client_credit_client_idx on public.client_credit (client_organization_id, currency, created_at);
create index client_credit_org_idx on public.client_credit (organization_id, created_at);
comment on table public.client_credit is
  'What the servicer owes a client back (419, Collectoo''s label; OQ-98): a payment beyond what was open (overpayment), '
  'or held for the client''s collective proceeding (procedure). Append-only; refunded by record_client_refund.';

-- Each payment's credits are its −419 line: for each entry of the statement, the entry is a client payment of the
-- rows' servicer, client and currency, and the sum of every credit row it holds is minus its 419 posting. One keyed
-- lookup per entry.
create or replace function private.client_credit_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_bad text;
begin
  select min(n.entry_id::text) into v_bad
  from (select distinct q.entry_id, q.organization_id, q.client_organization_id, q.currency from new_rows q) n
  left join lateral (select e.entry_type, e.organization_id, e.client_organization_id from public.ledger_entry e
                     where e.id = n.entry_id offset 0) e on true
  left join lateral (select coalesce(-sum(p.amount_minor), 0) as owed
                     from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                           where q.entry_id = n.entry_id offset 0) p
                     cross join lateral (select a.book, a.client_organization_id, a.currency from public.ledger_account a
                                         where a.id = p.ledger_account_id offset 0) a
                     where a.book = 'client_credit_owed' and a.client_organization_id = n.client_organization_id
                       and a.currency = n.currency) o on true
  left join lateral (select coalesce(sum(c.amount_minor), 0) as held from public.client_credit c
                     where c.entry_id = n.entry_id) c on true
  where e.entry_type is distinct from 'client_payment_own' and e.entry_type is distinct from 'client_payment_dedicated'
     or e.organization_id is distinct from n.organization_id
     or e.client_organization_id is distinct from n.client_organization_id
     or o.owed <> c.held;
  if v_bad is not null then
    raise exception 'client credit: not the 419 credit of its payment for its client'
      using errcode = 'check_violation', detail = 'entry ' || v_bad;
  end if;
  return null;
end;
$$;
create trigger client_credit_guard after insert on public.client_credit
  referencing new table as new_rows for each statement execute function private.client_credit_guard();
alter table public.client_credit enable always trigger client_credit_guard;
create trigger client_credit_append_only before update or delete or truncate on public.client_credit
  for each statement execute function private.refuse_change();
alter table public.client_credit enable always trigger client_credit_append_only;
create trigger client_credit_change_log after insert or update or delete on public.client_credit
  for each row execute function private.log_change();
alter table public.client_credit enable row level security;
revoke all on public.client_credit from public, anon, authenticated;
grant select on public.client_credit to authenticated, service_role;
-- money staff of the servicer; the client's members with access to the whole client (what the servicer owes them:
-- design §6.2's rule, OQ-48); never a member restricted to portfolios, a collector or another tenant
create policy client_credit_read on public.client_credit for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[])
  or client_organization_id = any ((select private.client_whole_org_ids())::uuid[]));

-- [critic] M7-MONEY-10: what a client's payment recovered of an advance passed as a loss (7714 « Rentrées sur avances
-- passées en perte », Collectoo's label; OQ-88): never more than what was passed as a loss (Σ its write_off settlements)
-- per advance; the payment's −7714 line is the sum of its rows. Deviation from the plan's `entry_id unique`: one
-- payment may recover several advances (primary key (entry_id, advance_id)). Append-only, money staff only.
create table public.advance_write_off_recovery (
  advance_id uuid not null references public.client_advance (id),
  entry_id uuid not null references public.ledger_entry (id),
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  currency char(3) not null references public.currency (code),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  created_at timestamptz not null default clock_timestamp(),
  primary key (entry_id, advance_id)
);
create index advance_write_off_recovery_advance_idx on public.advance_write_off_recovery (advance_id);
create index advance_write_off_recovery_org_idx on public.advance_write_off_recovery (organization_id, created_at);
comment on table public.advance_write_off_recovery is
  'A client''s repayment of an advance passed as a loss, booked as income (7714, OQ-88): capped at the loss. Append-only.';

-- For each advance of the statement: an advance of the rows' servicer, client and currency, recovered within what was
-- passed as a loss; for each entry: a client payment of that client, its −7714 line the sum of its rows
create or replace function private.advance_write_off_recovery_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_bad text;
begin
  select min(n.advance_id::text) into v_bad
  from (select distinct q.advance_id, q.organization_id, q.client_organization_id, q.currency from new_rows q) n
  left join lateral (select a.organization_id, a.client_organization_id, a.currency from public.client_advance a
                     where a.id = n.advance_id offset 0) a on true
  left join lateral (select coalesce(sum(s.amount_minor), 0) as lost from public.commission_settlement s
                     where s.document_id = n.advance_id and s.document_kind = 'advance' and s.kind = 'write_off') w on true
  left join lateral (select coalesce(sum(r.amount_minor), 0) as recovered from public.advance_write_off_recovery r
                     where r.advance_id = n.advance_id) r on true
  where (a.organization_id, a.client_organization_id, a.currency)
        is distinct from (n.organization_id, n.client_organization_id, n.currency)
     or r.recovered > w.lost;
  if v_bad is null then
    select min(n.entry_id::text) into v_bad
    from (select distinct q.entry_id, q.organization_id, q.client_organization_id from new_rows q) n
    left join lateral (select e.entry_type, e.organization_id, e.client_organization_id from public.ledger_entry e
                       where e.id = n.entry_id offset 0) e on true
    left join lateral (select coalesce(-sum(p.amount_minor), 0) as income
                       from (select q.amount_minor, q.ledger_account_id from public.ledger_posting q
                             where q.entry_id = n.entry_id offset 0) p
                       cross join lateral (select a.book from public.ledger_account a
                                           where a.id = p.ledger_account_id offset 0) a
                       where a.book = 'written_off_recovered') o on true
    left join lateral (select coalesce(sum(r.amount_minor), 0) as held from public.advance_write_off_recovery r
                       where r.entry_id = n.entry_id) r on true
    where e.entry_type is distinct from 'client_payment_own' and e.entry_type is distinct from 'client_payment_dedicated'
       or e.organization_id is distinct from n.organization_id
       or e.client_organization_id is distinct from n.client_organization_id
       or o.income <> r.held;
  end if;
  if v_bad is not null then
    raise exception 'advance write-off recovery: beyond the loss, or not the 7714 line of its client''s payment'
      using errcode = 'check_violation', detail = v_bad;
  end if;
  return null;
end;
$$;
create trigger advance_write_off_recovery_guard after insert on public.advance_write_off_recovery
  referencing new table as new_rows for each statement execute function private.advance_write_off_recovery_guard();
alter table public.advance_write_off_recovery enable always trigger advance_write_off_recovery_guard;
create trigger advance_write_off_recovery_append_only before update or delete or truncate
  on public.advance_write_off_recovery for each statement execute function private.refuse_change();
alter table public.advance_write_off_recovery enable always trigger advance_write_off_recovery_append_only;
create trigger advance_write_off_recovery_change_log after insert or update or delete on public.advance_write_off_recovery
  for each row execute function private.log_change('entry_id', 'advance_id');
alter table public.advance_write_off_recovery enable row level security;
revoke all on public.advance_write_off_recovery from public, anon, authenticated;
grant select on public.advance_write_off_recovery to authenticated, service_role;
create policy advance_write_off_recovery_read on public.advance_write_off_recovery for select to authenticated using (
  organization_id = any ((select private.money_staff_org_ids())::uuid[]));

-- A client credit's refunds: of a credit of the row's servicer and client, never beyond its amount (defence in depth
-- for record_client_refund, as 7b's guard for the advances). One keyed lookup per credit of the statement.
create or replace function private.commission_settlement_credit_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_bad text;
begin
  select min(n.document_id::text) into v_bad
  from (select distinct q.document_id, q.organization_id, q.client_organization_id from new_rows q
        where q.document_kind = 'client_credit') n
  left join lateral (select c.organization_id, c.client_organization_id, c.amount_minor from public.client_credit c
                     where c.id = n.document_id offset 0) c on true
  left join lateral (select coalesce(sum(s.amount_minor), 0) as refunded from public.commission_settlement s
                     where s.document_id = n.document_id and s.document_kind = 'client_credit') s on true
  where c.amount_minor is null or c.organization_id <> n.organization_id
     or c.client_organization_id <> n.client_organization_id or s.refunded > c.amount_minor;
  if v_bad is null then
    select min(q.document_id::text) into v_bad from new_rows q
    where q.document_kind = 'client_credit' and (q.kind <> 'refund' or q.vat_moved_minor <> 0);
  end if;
  if v_bad is not null then
    raise exception 'commission settlement: a client credit refunded beyond its amount, or not its client''s'
      using errcode = 'check_violation', detail = 'client credit ' || v_bad;
  end if;
  return null;
end;
$$;
create trigger commission_settlement_credit_guard after insert on public.commission_settlement
  referencing new table as new_rows for each statement execute function private.commission_settlement_credit_guard();
alter table public.commission_settlement enable always trigger commission_settlement_credit_guard;

------------------------------------------------------------------------------------------
-- What a client owes the servicer, and what its payment settles (plan §5.2.1–§5.2.3)
------------------------------------------------------------------------------------------

-- A client credit's open part: its amount less its refunds (record_client_refund). Null for an id that is none.
create or replace function private.client_credit_open(p_credit_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select c.amount_minor - coalesce((select sum(s.amount_minor) from public.commission_settlement s
                                    where s.document_id = c.id and s.document_kind = 'client_credit'), 0)::bigint
  from public.client_credit c where c.id = p_credit_id;
$$;

-- What is left to recover of an advance passed as a loss (in whole or in part): Σ its write_off settlements less Σ its
-- recoveries ([critic] M7-MONEY-10). Null for an id that is no advance.
create or replace function private.written_off_available(p_advance_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce((select sum(s.amount_minor) from public.commission_settlement s
                   where s.document_id = a.id and s.document_kind = 'advance' and s.kind = 'write_off'), 0)::bigint
         - coalesce((select sum(r.amount_minor) from public.advance_write_off_recovery r where r.advance_id = a.id),
                    0)::bigint
  from public.client_advance a where a.id = p_advance_id;
$$;

-- The approved or sent run whose plan settles a document of a client (an invoice set off, a credit note's refund, an
-- advance taken back): private.advance_in_flight_run's twin for every document. The client's runs by
-- (client, currency) and status (a handful), their plans' settles read in memory.
create or replace function private.document_in_flight_run(p_document_id uuid, p_client_organization_id uuid,
                                                          p_currency char(3))
returns table (run_id uuid, run_number text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select r.id, r.number
  from (select q.id, q.number, q.settlement_plan from public.remittance_run q
        where q.client_organization_id = p_client_organization_id and q.currency = p_currency
          and q.status in ('approved', 'sent') offset 0) r
  where jsonb_typeof(r.settlement_plan) = 'object'
    and exists (select 1 from jsonb_array_elements(coalesce(r.settlement_plan -> 'settles', '[]')) s
                where s ->> 'document_id' = p_document_id::text)
  order by r.number;
$$;

-- (review round 2) Plan §6.2.2, brought forward from 7d-2: the opening of the client's collective proceeding as of p_on
-- — the earliest proceeding_opened **or** liquidation event in effect that day (client_status_event_client_idx: the
-- client and the day in the index, the kind outside), null without one. A liquidation judgment recorded alone (a
-- liquidation opened at once) opens it: C. com. L641-3 al. 1 (read 2026-11-24, in force since 2019-05-24) gives that
-- judgment the effects of L622-7 I al. 1 — no claim born before it is paid (COMPLIANCE HOLD-02). 7c-1 reads it for
-- what the client may pay (private.document_before_opening, private.client_payment_docs) and, (review round 3), for an
-- advance without a claw-back clause, whether it is barred (private.advance_recovery_of); 7b's
-- private.client_opening_on (proceeding_opened only: the claw-back's rule) and the prepare are untouched until 7d-2
-- moves them to it.
create or replace function private.client_opening_date(p_client uuid, p_on date)
returns date
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select min(e.effective_date) from public.client_status_event e
  where e.client_organization_id = p_client and e.effective_date <= p_on
    and e.kind in ('proceeding_opened', 'liquidation');
$$;

-- 5.2.2: whether a document of the servicer's claim on its client was born before the client's collective proceeding
-- opened (as of p_on): an invoice issued, or an advance born (private.advance_born_on), before the earliest
-- proceeding_opened or liquidation in effect that day ((review round 2) private.client_opening_date). 7c's criterion is
-- today's; 7d-2 redefines it (private.document_born_on). Null for an id that is neither.
create or replace function private.document_before_opening(p_document_id uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(d.born < private.client_opening_date(d.client, p_on), false)
  from (select i.client_organization_id as client, i.issue_date as born from public.commission_invoice i
        where i.id = p_document_id
        union all
        select a.client_organization_id, private.advance_born_on(a.id) from public.client_advance a
        where a.id = p_document_id) d
  limit 1;
$$;

-- [check 1] gap 11: whether the client may pay this document to the servicer on p_on — 7c-1: not a claim born before
-- its proceeding opened (L622-7 I al. 1, first sentence; for a liquidation, through L641-3 al. 1). 7d-2 redefines it
-- (an advance while a proceeding stands). It is not document_nettable: a mandate end or a seizure bars the servicer's
-- set-off, never the client's own payment.
create or replace function private.document_client_payable(p_document_id uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select not coalesce(private.document_before_opening(p_document_id, p_on), false);
$$;

-- private.advance_recovery_of, redefined from 20261123090000_advance_recovery.sql (line 142; same signature and settings,
-- its grants restated below). M2c-7c-1 (review round 3): an advance without a claw-back clause (« request », or
-- « request_no_mandate ») is never taken by a run; it is recovered only if the client pays it, and the client may not pay
-- a claim born before its proceeding opened — a proceeding_opened or a liquidation recorded alone (C. com. L641-3 al. 1 →
-- L622-7 I al. 1: the creditor declares it to the liquidator, L641-3 al. 4) — so it is « barred_proceeding » when born
-- before private.client_opening_date, the opening 7c-1's payments read; no page says a request will come for a claim the
-- client may not pay (7c-2's request refuses it too). A claw-back keeps 7b's rule — barred when born before the
-- proceeding_opened the prepare reads (private.client_opening_on) — until 7d-2 moves the prepare and this rule to
-- client_opening_date (plan §6.2.2): every page states what the runs do. One keyed read of the opening either way.
create or replace function private.advance_recovery_of(p_mandate_id uuid, p_client_organization_id uuid, p_born_on date,
                                                       p_on date)
returns table (recovery text, clause_ref text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select case when b.barred then 'barred_proceeding' else m.recovery end,
         case when b.barred then null else m.clause_ref end
  from private.mandate_recovery(p_mandate_id, p_on) m
  cross join lateral (select coalesce(p_born_on < case when m.recovery = 'clawback'
                                                       then private.client_opening_on(p_client_organization_id, p_on)
                                                       else private.client_opening_date(p_client_organization_id, p_on)
                                                  end, false) as barred) b;
$$;

-- Whether a collective proceeding of the client stands on p_on (a proceeding_opened or a liquidation in effect): a
-- surplus is then held for the procedure (cause procedure), never refunded to the client as an overpayment
create or replace function private.client_proceeding_stands(p_client_organization_id uuid, p_on date)
returns boolean
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select exists (select 1 from public.client_status_event e
                 where e.client_organization_id = p_client_organization_id
                   and e.kind in ('proceeding_opened', 'liquidation') and e.effective_date <= p_on);
$$;

-- The VAT a settled part of an invoice moves to due: R(pending × part / open), half up; all of it when the part closes
-- the invoice (settlement.vat_part, the run plan's rule)
create or replace function private.vat_part(p_pending bigint, p_open bigint, p_take bigint)
returns bigint
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case when p_take >= p_open then p_pending
              when p_open <= 0 then 0::bigint
              else (2 * p_pending * p_take + p_open) / (2 * p_open) end;
$$;

-- The default order (5.2.3; our reading of C. civ. 1342-10 al. 2 — founder Q4, OQ-89): invoices due on or before p_on
-- by (due date, year, number); advances by (birth, recording, id); the other invoices by (due date, nulls last, year,
-- number). p_docs: [{kind, id, open, pending_vat, payable, due_date, year, seq, born_on, created_at}], the client's
-- open documents (the twin: remittance.client_payments.default_order). What the client may not pay is the caller's to
-- leave out.
create or replace function private.client_payment_order(p_docs jsonb, p_on date)
returns table (n bigint, kind text, id uuid, open_minor bigint, pending_vat_minor bigint, payable boolean)
language sql
immutable
set search_path = ''
as $$
  select row_number() over (order by d.grp, d.day nulls last, d.year, d.seq, d.created_at nulls first, d.id),
         d.kind, d.id, d.open, d.pending, d.payable
  from (select x ->> 'kind' as kind, (x ->> 'id')::uuid as id, (x ->> 'open')::bigint as open,
               coalesce((x ->> 'pending_vat')::bigint, 0) as pending, coalesce((x ->> 'payable')::boolean, true) as payable,
               case when x ->> 'kind' = 'invoice' and (x ->> 'due_date')::date <= p_on then 0
                    when x ->> 'kind' = 'advance' then 1 else 2 end as grp,
               case when x ->> 'kind' = 'advance' then (x ->> 'born_on')::date else (x ->> 'due_date')::date end as day,
               coalesce((x ->> 'year')::integer, 0) as year, coalesce((x ->> 'seq')::integer, 0) as seq,
               (x ->> 'created_at')::timestamptz as created_at
        from jsonb_array_elements(coalesce(p_docs, '[]')) x) d
  order by 1;
$$;

-- 5.2.3, the plan's pure core (the twin: remittance.client_payments.plan_client_payment; parity by Hypothesis): what a
-- payment of p_amount settles of the client's open documents not in flight (p_docs, as above). With the client's
-- designation (p_named, its order; and p_recover [{id, available, payable}], the written-off advances it repays): each
-- named document up to its open part — one it may not pay (`payable` false: before its proceeding) held for the
-- procedure, a client_credit part of cause procedure naming it —, then each recovery up to what is left to recover —
-- (review round 1, MONEY-1) one it may not repay held for the procedure the same way, never income —; the rest a
-- credit. Without: the default order over what the client may pay. The rest is a credit owed back ([critic]
-- M7-MONEY-10: never refused) of cause procedure while a proceeding stands (p_procedure), else overpayment. VAT moved:
-- private.vat_part. A named document p_docs does not hold is a data error (the commands refuse not_open first).
create or replace function private.client_payment_plan(p_docs jsonb, p_amount bigint, p_named uuid[], p_recover jsonb,
                                                       p_procedure boolean, p_on date)
returns table (ord integer, document_kind text, document_id uuid, amount_minor bigint, vat_moved_minor bigint,
               cause text)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_rest bigint := p_amount;
  v_ord integer := 0;
  v_part bigint;
  d record;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'client payment plan: a payment is > 0' using errcode = '22023';
  end if;
  if coalesce(cardinality(p_named), 0) > 0 or coalesce(jsonb_array_length(p_recover), 0) > 0 then
    for d in
      select n.k, x.kind, x.id, x.open_minor, x.pending_vat_minor, x.payable
      from unnest(coalesce(p_named, '{}')) with ordinality n (id, k)
      left join lateral (select o.kind, o.id, o.open_minor, o.pending_vat_minor, o.payable
                         from private.client_payment_order(p_docs, p_on) o where o.id = n.id) x on true
      order by n.k
    loop
      if d.id is null then
        raise exception 'client payment plan: a named document is not an open document of the client'
          using errcode = '22023';
      end if;
      continue when v_rest = 0;
      v_part := least(v_rest, d.open_minor);
      v_ord := v_ord + 1;
      if d.payable then
        return query select v_ord, d.kind, d.id, v_part,
                            case when d.kind = 'invoice' then private.vat_part(d.pending_vat_minor, d.open_minor, v_part)
                                 else 0::bigint end,
                            null::text;
      else
        return query select v_ord, 'client_credit'::text, d.id, v_part, 0::bigint, 'procedure'::text;
      end if;
      v_rest := v_rest - v_part;
    end loop;
    for d in
      select (x ->> 'id')::uuid as id, (x ->> 'available')::bigint as available,
             coalesce((x ->> 'payable')::boolean, true) as payable
      from jsonb_array_elements(coalesce(p_recover, '[]')) with ordinality r (x, k) order by r.k
    loop
      exit when v_rest = 0;
      v_part := least(v_rest, d.available);
      v_ord := v_ord + 1;
      if d.payable then
        return query select v_ord, 'written_off'::text, d.id, v_part, 0::bigint, null::text;
      else
        -- (review round 1, MONEY-1) a loss the client may not repay (born before its proceeding opened): held for the
        -- procedure, naming the advance, as a named document it may not pay — never income on 7714
        return query select v_ord, 'client_credit'::text, d.id, v_part, 0::bigint, 'procedure'::text;
      end if;
      v_rest := v_rest - v_part;
    end loop;
  else
    for d in select o.kind, o.id, o.open_minor, o.pending_vat_minor from private.client_payment_order(p_docs, p_on) o
             where o.payable order by o.n
    loop
      exit when v_rest = 0;
      v_part := least(v_rest, d.open_minor);
      v_ord := v_ord + 1;
      return query select v_ord, d.kind, d.id, v_part,
                          case when d.kind = 'invoice' then private.vat_part(d.pending_vat_minor, d.open_minor, v_part)
                               else 0::bigint end,
                          null::text;
      v_rest := v_rest - v_part;
    end loop;
  end if;
  if v_rest > 0 then
    v_ord := v_ord + 1;
    return query select v_ord, 'client_credit'::text, null::uuid, v_rest, 0::bigint,
                        case when p_procedure then 'procedure' else 'overpayment' end;
  end if;
end;
$$;

-- What a payment may settle, as the page shows it (the commands' compare and set; the twin's considered_open): the named
-- documents and recoveries with a designation, else every open document the client may pay
create or replace function private.client_payment_considered(p_docs jsonb, p_named uuid[], p_recover jsonb)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select case when coalesce(cardinality(p_named), 0) > 0 or coalesce(jsonb_array_length(p_recover), 0) > 0
              then coalesce((select sum((x ->> 'open')::bigint) from jsonb_array_elements(coalesce(p_docs, '[]')) x
                             where (x ->> 'id')::uuid = any (coalesce(p_named, '{}'))), 0)
                   + coalesce((select sum((x ->> 'available')::bigint)
                               from jsonb_array_elements(coalesce(p_recover, '[]')) x), 0)
              else coalesce((select sum((x ->> 'open')::bigint) from jsonb_array_elements(coalesce(p_docs, '[]')) x
                             where coalesce((x ->> 'payable')::boolean, true)), 0) end::bigint;
$$;

-- A client's open documents in a currency, as the plan and the page read them: its invoices with an open part
-- (commission_invoice_client_idx, the kind and currency outside the fence) and its open advances
-- (private.client_open_advances), each with its pending VAT, whether the client may pay it on p_on, its in-flight run
-- and the facts the default order and the page read. (review round 4) `since`: the day it came into being (an
-- invoice's issue, an advance's birth: its entry's date); `open_on`: whether it existed on p_on — a payment of an
-- earlier date never settles it (private.client_payment_free leaves it out; named, it is refused bad_date). An open
-- part only falls after that day (settlements are never undone), so a document existing on p_on with an open part now
-- was open on every day since by at least as much. Every amount as text. One keyed lookup per document.
create or replace function private.client_payment_docs(p_client_organization_id uuid, p_currency char(3), p_on date)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(jsonb_agg(x.doc order by x.kind, x.at, x.id), '[]')
  from (select 'invoice' as kind, i.issue_date::timestamptz as at, i.id,
               jsonb_build_object(
                 'kind', 'invoice', 'id', i.id, 'number', i.number, 'issue_date', i.issue_date, 'due_date', i.due_date,
                 'settlement', i.settlement, 'ttc_minor', i.ttc_minor::text, 'open', o.open::text,
                 'pending_vat', private.document_pending_vat(i.id)::text, 'payable', not b.before,
                 'before_opening', b.before, 'year', i.year, 'seq', i.seq, 'since', i.issue_date,
                 'open_on', i.issue_date <= p_on,
                 'in_flight_run', (select jsonb_build_object('run_id', f.run_id, 'number', f.run_number)
                                   from private.document_in_flight_run(i.id, i.client_organization_id, i.currency) f
                                   limit 1)) as doc
        from (select q.id, q.number, q.kind, q.currency, q.issue_date, q.due_date, q.settlement, q.ttc_minor, q.year,
                     q.seq, q.client_organization_id
              from public.commission_invoice q where q.client_organization_id = p_client_organization_id offset 0) i
        cross join lateral (select private.document_open(i.id) as open) o
        cross join lateral (select coalesce(private.document_before_opening(i.id, p_on), false) as before) b
        where i.kind = 'invoice' and i.currency = p_currency and o.open > 0
        union all
        select 'advance', a.created_at, a.advance_id,
               jsonb_build_object(
                 'kind', 'advance', 'id', a.advance_id, 'cause', a.cause, 'born_on', a.born_on,
                 'created_at', a.created_at, 'created_on', (a.created_at at time zone 'Europe/Paris')::date,
                 'amount_minor', (select q.amount_minor from public.client_advance q where q.id = a.advance_id)::text,
                 'open', a.open_minor::text, 'pending_vat', '0', 'mandate_id', a.mandate_id,
                 'payable', not b.before, 'before_opening', b.before, 'year', 0, 'seq', 0, 'since', a.born_on,
                 'open_on', coalesce(a.born_on <= p_on, false),
                 'in_flight_run', (select jsonb_build_object('run_id', f.run_id, 'number', f.run_number)
                                   from private.advance_in_flight_run(a.advance_id) f order by f.run_number limit 1))
        from private.client_open_advances(p_client_organization_id, p_currency) a
        cross join lateral (select coalesce(a.born_on < private.client_opening_date(p_client_organization_id, p_on),
                                            false) as before) b) x;
$$;

-- The documents of p_docs no approved or sent run settles (the plan's: a document in flight is never settled twice) and,
-- (review round 4), that existed on the payment's date (open_on: one issued or born later is not the payment's to
-- settle — the money is then a credit owed back, as it was that day)
create or replace function private.client_payment_free(p_docs jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(coalesce(p_docs, '[]')) x
  where jsonb_typeof(x -> 'in_flight_run') is distinct from 'object' and (x ->> 'open_on')::boolean is not false;
$$;

-- The written-off advances named, as the plan takes them: [{id, available, payable, written_off_on, open_on}] in the
-- client's order (those with nothing left to recover, or of another client or currency, left out: the commands refuse
-- them not_open). (review round 1, MONEY-1) `payable`: whether the client may repay it on p_on
-- (private.document_client_payable: not an advance born before its proceeding opened, L622-7 I al. 1; 7d-2's
-- redefinition applies here too) — the plan holds what it may not repay for the procedure, never income on 7714.
-- (review round 4) `written_off_on`: its last write-off's day (its settlements by commission_settlement_document_idx);
-- `open_on`: on or before p_on — a payment of an earlier day repaid an advance still open, never a loss (refused
-- bad_date: private.client_payment_named_refusal).
create or replace function private.client_payment_recoveries(p_client_organization_id uuid, p_currency char(3),
                                                             p_recover uuid[], p_on date)
returns jsonb
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'available', w.available::text,
                                               'payable', private.document_client_payable(a.id, p_on),
                                               'written_off_on', l.on_date, 'open_on', coalesce(l.on_date <= p_on, false))
                            order by r.k), '[]')
  from unnest(coalesce(p_recover, '{}')) with ordinality r (id, k)
  cross join lateral (select q.id from public.client_advance q
                      where q.id = r.id and q.client_organization_id = p_client_organization_id
                        and q.currency = p_currency) a
  cross join lateral (select private.written_off_available(a.id) as available) w
  cross join lateral (select max(s.settled_on) as on_date
                      from (select q.settled_on, q.kind from public.commission_settlement q
                            where q.document_id = a.id offset 0) s
                      where s.kind = 'write_off') l
  where w.available > 0;
$$;

-- 5.2.3: what a payment of p_amount of the client in p_currency on p_on settles (its documents named, else the
-- default order; the written-off advances it repays) — the plan's core over the client's open documents not in flight
create or replace function private.client_settlement_plan(p_client uuid, p_currency char(3), p_amount bigint,
                                                          p_documents uuid[], p_recover uuid[], p_on date)
returns table (ord integer, document_kind text, document_id uuid, amount_minor bigint, vat_moved_minor bigint,
               cause text)
language sql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
  select p.ord, p.document_kind, p.document_id, p.amount_minor, p.vat_moved_minor, p.cause
  from private.client_payment_plan(private.client_payment_free(private.client_payment_docs(p_client, p_currency, p_on)),
                                   p_amount, p_documents,
                                   private.client_payment_recoveries(p_client, p_currency, p_recover, p_on),
                                   private.client_proceeding_stands(p_client, p_on), p_on) p;
$$;

-- The refusal of a designation (5.2.4): a named document with nothing open, of another client or currency
-- (not_open), (review round 4) issued or born after the payment's date (bad_date, its day: open_on false), or settled
-- by a run in flight (in_flight, its run's number); a named recovery with nothing left to recover (not_open), or of a
-- loss passed after the payment's date (bad_date, the write-off's day). Null when every one may be settled.
create or replace function private.client_payment_named_refusal(p_docs jsonb, p_named uuid[], p_recover uuid[],
                                                                p_recoveries jsonb)
returns table (code text, detail text)
language sql
immutable
set search_path = ''
as $$
  select r.code, r.detail
  from (select case when x.doc is null then 'not_open'
                    when (x.doc ->> 'open_on')::boolean is false then 'bad_date'
                    when jsonb_typeof(x.doc -> 'in_flight_run') = 'object' then 'in_flight' end as code,
               case when (x.doc ->> 'open_on')::boolean is false then x.doc ->> 'since'
                    else x.doc #>> '{in_flight_run,number}' end as detail, n.k
        from unnest(coalesce(p_named, '{}')) with ordinality n (id, k)
        left join lateral (select d as doc from jsonb_array_elements(coalesce(p_docs, '[]')) d
                           where (d ->> 'id')::uuid = n.id limit 1) x on true
        union all
        select case when w.rec is null then 'not_open' when (w.rec ->> 'open_on')::boolean is false then 'bad_date' end,
               w.rec ->> 'written_off_on', 1000000 + n.k
        from unnest(coalesce(p_recover, '{}')) with ordinality n (id, k)
        left join lateral (select q as rec from jsonb_array_elements(coalesce(p_recoveries, '[]')) q
                           where (q ->> 'id')::uuid = n.id limit 1) w on true) r
  where r.code is not null
  order by r.k
  limit 1;
$$;

------------------------------------------------------------------------------------------
-- The reads: « Ce que le client doit au cabinet », the payment's preview, a client's line, the client space
------------------------------------------------------------------------------------------

-- 5.2.1 « Ce que le client doit au cabinet » (the client's « Reversement » page): money staff of the servicer (aal2).
-- Its open invoices (number, dates, settlement, TTC, open, pending VAT), open advances (cause, dates, open, mandate, how
-- it is recovered), written-off advances with something left to recover (review round 1, MONEY-1: and whether the
-- client may repay them), refunds owed (credit notes whose refund is still owed) and credits owed back to it (cause,
-- open, (review round 3) the day the money was received) — each with its in-flight run and, for a claim on the client,
-- whether it was born before its proceeding opened (not payable then) —, the default order, what a payment with no
-- designation may settle, whether a proceeding stands and whether the own account is set. Amounts as text.
create or replace function public.client_open_documents(p_client_organization_id uuid, p_currency char(3))
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid;
  v_today date := private.paris_today();
  v_docs jsonb;
begin
  select c.servicer_organization_id into v_org from public.organization c
  where c.id = p_client_organization_id and c.kind <> 'servicer';
  if v_org is null or not private.has_role(v_org, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_docs := private.client_payment_docs(p_client_organization_id, p_currency, v_today);
  return jsonb_build_object(
    'client_id', p_client_organization_id, 'currency', p_currency, 'today', v_today,
    'procedure', private.client_proceeding_stands(p_client_organization_id, v_today),
    'own_account', exists (select 1 from public.servicer_billing_settings s
                           join public.bank_account b on b.id = s.own_bank_account_id
                           where s.organization_id = v_org and b.purpose = 'own' and b.status = 'active'
                             and b.currency = p_currency),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', x ->> 'id', 'number', x ->> 'number', 'issue_date', x ->> 'issue_date',
                   'due_date', x ->> 'due_date', 'settlement', x ->> 'settlement', 'ttc_minor', x ->> 'ttc_minor',
                   'open_minor', x ->> 'open', 'pending_vat_minor', x ->> 'pending_vat',
                   'before_opening', x -> 'before_opening', 'payable', x -> 'payable',
                   'in_flight_run', x -> 'in_flight_run') order by x ->> 'issue_date', x ->> 'number'), '[]')
                 from jsonb_array_elements(v_docs) x where x ->> 'kind' = 'invoice'),
    'advances', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', x ->> 'id', 'cause', x ->> 'cause', 'created_on', x ->> 'created_on', 'born_on', x ->> 'born_on',
                   'amount_minor', x ->> 'amount_minor', 'open_minor', x ->> 'open',
                   'mandate_reference', (select m.reference from public.mandate m where m.id = (x ->> 'mandate_id')::uuid),
                   'recovery', r.recovery, 'clause_ref', r.clause_ref, 'before_opening', x -> 'before_opening',
                   'payable', x -> 'payable', 'in_flight_run', x -> 'in_flight_run')
                   order by x ->> 'born_on', x ->> 'created_at'), '[]')
                 from jsonb_array_elements(v_docs) x
                 cross join lateral private.advance_recovery_of((x ->> 'mandate_id')::uuid, p_client_organization_id,
                                                                (x ->> 'born_on')::date, v_today) r
                 where x ->> 'kind' = 'advance'),
    'written_off', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', a.id, 'cause', a.cause, 'born_on', private.advance_born_on(a.id),
                      'written_off_on', w.on_date, 'written_off_minor', w.lost::text,
                      'recovered_minor', (w.lost - v.available)::text, 'available_minor', v.available::text,
                      -- (review round 1, MONEY-1) born before the client's proceeding opened: what it pays for it is
                      -- held for the procedure, never income
                      'before_opening', coalesce(private.document_before_opening(a.id, v_today), false),
                      'payable', private.document_client_payable(a.id, v_today))
                      order by a.created_at, a.id), '[]')
                    from (select q.id, q.cause, q.created_at, q.currency from public.client_advance q
                          where q.client_organization_id = p_client_organization_id offset 0) a
                    cross join lateral (select coalesce(sum(s.amount_minor), 0)::bigint as lost, max(s.settled_on) as on_date
                                        from public.commission_settlement s
                                        where s.document_id = a.id and s.document_kind = 'advance'
                                          and s.kind = 'write_off') w
                    cross join lateral (select private.written_off_available(a.id) as available) v
                    where a.currency = p_currency and w.lost > 0 and v.available > 0),
    'refunds_owed', (select coalesce(jsonb_agg(jsonb_build_object(
                       'id', i.id, 'number', i.number, 'issue_date', i.issue_date, 'owed_minor', o.owed::text,
                       'in_flight_run', (select jsonb_build_object('run_id', f.run_id, 'number', f.run_number)
                                         from private.document_in_flight_run(i.id, p_client_organization_id, p_currency) f
                                         limit 1)) order by i.issue_date, i.number), '[]')
                     from (select q.id, q.number, q.kind, q.currency, q.issue_date from public.commission_invoice q
                           where q.client_organization_id = p_client_organization_id offset 0) i
                     cross join lateral (select private.document_open(i.id) as owed) o
                     where i.kind = 'credit_note' and i.currency = p_currency and o.owed > 0),
    -- (review round 3) each credit's receipt, received_on: its payment's entry's date (the value date on the own
    -- account, the line's booking date on the dedicated one), by the entry's primary key — the page's « Trop-perçu
    -- du … », « Somme reçue le … »; created_on is its recording (the nightly's 15-day alert reads created_at)
    'credits', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', c.id, 'cause', c.cause, 'created_on', (c.created_at at time zone 'Europe/Paris')::date,
                  'received_on', (select e.effective_date from public.ledger_entry e where e.id = c.entry_id),
                  'amount_minor', c.amount_minor::text, 'open_minor', o.open::text) order by c.created_at, c.id), '[]')
                from (select q.id, q.cause, q.created_at, q.amount_minor, q.currency, q.entry_id from public.client_credit q
                      where q.client_organization_id = p_client_organization_id offset 0) c
                cross join lateral (select private.client_credit_open(c.id) as open) o
                where c.currency = p_currency and o.open > 0),
    'default_order', (select coalesce(jsonb_agg(jsonb_build_object('document_kind', o.kind, 'document_id', o.id)
                                                order by o.n), '[]')
                      from private.client_payment_order(private.client_payment_free(v_docs), v_today) o
                      where o.payable),
    'default_open_minor', private.client_payment_considered(private.client_payment_free(v_docs), null, null)::text);
end;
$$;

-- The preview of a payment (the sheet's live effect): what record_client_payment would settle of p_amount_text on
-- p_on (today by default) — its parts (each document's number), the credit owed back, what it may settle (the open
-- part the command compares) — or why it is refused (bad_amount, not_open, in_flight with its run, (review round 4)
-- bad_date with the day a named document or loss came into being). Money staff.
create or replace function public.client_payment_preview(p_client_organization_id uuid, p_currency char(3),
                                                         p_amount_text text, p_documents uuid[], p_recover_written_off uuid[],
                                                         p_on date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid;
  v_on date := coalesce(p_on, private.paris_today());
  v_amount bigint := private.euros_to_minor(p_amount_text);
  v_docs jsonb;
  v_free jsonb;
  v_rec jsonb;
  v_why record;
  v_rows jsonb := '[]';
begin
  select c.servicer_organization_id into v_org from public.organization c
  where c.id = p_client_organization_id and c.kind <> 'servicer';
  if v_org is null or not private.has_role(v_org, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_docs := private.client_payment_docs(p_client_organization_id, p_currency, v_on);
  v_free := private.client_payment_free(v_docs);
  v_rec := private.client_payment_recoveries(p_client_organization_id, p_currency, p_recover_written_off, v_on);
  select * into v_why from private.client_payment_named_refusal(v_docs, p_documents, p_recover_written_off, v_rec);
  if v_why.code is null and (v_amount is null or v_amount <= 0) then
    select 'bad_amount'::text as code, null::text as detail into v_why;
  end if;
  if v_why.code is null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'ord', p.ord, 'document_kind', p.document_kind, 'document_id', p.document_id,
             'number', (select x ->> 'number' from jsonb_array_elements(v_docs) x where (x ->> 'id')::uuid = p.document_id),
             'amount_minor', p.amount_minor::text, 'vat_moved_minor', p.vat_moved_minor::text, 'cause', p.cause)
             order by p.ord), '[]')
    into v_rows
    from private.client_payment_plan(v_free, v_amount, p_documents, v_rec,
                                     private.client_proceeding_stands(p_client_organization_id, v_on), v_on) p;
  end if;
  return jsonb_build_object(
    'amount_minor', case when v_amount > 0 then v_amount::text end,
    'open_minor', private.client_payment_considered(v_free, p_documents, v_rec)::text,
    'credit_minor', coalesce((select sum((x ->> 'amount_minor')::bigint) from jsonb_array_elements(v_rows) x
                              where x ->> 'document_kind' = 'client_credit'), 0)::text,
    'rows', v_rows, 'refusal', v_why.code, 'refusal_detail', v_why.detail);
end;
$$;

-- What decides a credit line of the dedicated account as a client's payment (5.2.5), read under the command's locks or
-- by the page: its refusal — not_a_client_credit (not a credit of kind client_transfer_in on an active client_funds
-- account, a duplicate still held, or from no client's confirmed payout IBAN), our_reference (one of our transfers,
-- lots or top-ups, or our RMT/SWP/TOP id in its label), line_booked (linked, booked, released or a payment),
-- ambiguous_client — and its client: the servicer's client whose confirmed payout account ([critic] M7-MONEY-12:
-- confirmed_at set — active, returned or retired —, as private.registered_client_ibans; never a proposed or rejected
-- one) carries its counterparty IBAN (client_payout_account_iban_idx).
create or replace function private.client_line_facts(p_bank_transaction_id uuid)
returns table (refusal text, client_id uuid)
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  v_kind text;
  v_held boolean;
  v_clients uuid[];
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  select coalesce(r.released_kind, t.kind), (t.kind = 'suspected_duplicate' and r.decision is distinct from 'released')
  into v_kind, v_held
  from (select 1) d
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id;
  if t.id is null or t.direction <> 'credit' or v_kind is distinct from 'client_transfer_in' or v_held
     or not exists (select 1 from public.bank_account b where b.id = t.bank_account_id and b.purpose = 'client_funds'
                      and b.status = 'active') then
    return query select 'not_a_client_credit'::text, null::uuid;
    return;
  end if;
  if private.names_our_transfer(t.end_to_end_id, t.original_end_to_end_id, t.payment_info_id)
     or private.names_our_lot(t.bank_account_id, t.payment_info_id) or coalesce(t.unsplit_ours, 0) > 0
     or coalesce(t.end_to_end_id ~ '^TOP[0-9A-F]{12}$', false)
     or coalesce(upper(t.remittance_text) ~ '(RMT|SWP|TOP)[0-9A-F]{12}', false) then
    return query select 'our_reference'::text, null::uuid;
    return;
  end if;
  if exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
     or exists (select 1 from public.payment p where p.bank_transaction_id = t.id) then
    return query select 'line_booked'::text, null::uuid;
    return;
  end if;
  select array_agg(distinct a.client_organization_id) into v_clients
  from (select q.client_organization_id, q.confirmed_at from public.client_payout_account q
        where q.organization_id = t.organization_id and q.iban = t.counterparty_iban offset 0) a
  where a.confirmed_at is not null;
  if coalesce(cardinality(v_clients), 0) = 0 then
    return query select 'not_a_client_credit'::text, null::uuid;
  elsif cardinality(v_clients) > 1 then
    return query select 'ambiguous_client'::text, null::uuid;
  else
    return query select null::text, v_clients[1];
  end if;
end;
$$;

-- The dedicated account's line as « Règlement d'une facture ou d'une avance du cabinet » shows it: its client, amount,
-- date and label, the client's open invoices its label names (its designation, [critic] L16), why it cannot be booked,
-- and the preview of the payment with p_documents named (or none: the default order). Money staff.
create or replace function public.client_payment_line(p_bank_transaction_id uuid, p_documents uuid[] default null,
                                                      p_recover_written_off uuid[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  f record;
  v_name text;
  v_named jsonb;
  v_preview jsonb;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  select * into f from private.client_line_facts(t.id);
  if f.client_id is not null then
    select o.legal_name into v_name from public.organization o where o.id = f.client_id;
    -- (review round 4) only an invoice issued on or before the line's day: the client cannot have designated one that
    -- did not exist (a later one is not the line's to settle: the default order skips it too)
    select coalesce(jsonb_agg(x ->> 'id' order by x ->> 'number'), '[]') into v_named
    from jsonb_array_elements(private.client_payment_docs(f.client_id, t.currency, t.booking_date)) x
    where x ->> 'kind' = 'invoice' and (x ->> 'open_on')::boolean
      and position(upper(x ->> 'number') in upper(coalesce(t.remittance_text, ''))) > 0;
    v_preview := public.client_payment_preview(f.client_id, t.currency,
                                               (t.amount_minor / 100)::text || ',' || lpad((t.amount_minor % 100)::text, 2, '0'),
                                               p_documents, p_recover_written_off, t.booking_date);
  end if;
  return jsonb_build_object(
    'bank_transaction_id', t.id, 'client_id', f.client_id, 'client_name', v_name, 'currency', t.currency,
    'amount_minor', t.amount_minor::text, 'booking_date', t.booking_date, 'label', t.remittance_text,
    'named_documents', coalesce(v_named, '[]'), 'refusal', f.refusal, 'preview', v_preview);
end;
$$;

-- The client space (« Reversements »): what the servicer owes the client back — its credits with an open part, oldest
-- first (client_credit_client_idx, the servicer outside the fence), each its cause, the day the money was received
-- ((review round 3) received_on: its payment's entry's date) and its recording date, and the total per currency. The
-- client's whole-client members, or money staff of its servicer.
create or replace function public.client_space_credits(p_client_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid;
begin
  select c.servicer_organization_id into v_org from public.organization c
  where c.id = p_client_organization_id and c.kind <> 'servicer';
  if v_org is null
     or not (p_client_organization_id = any (private.client_whole_org_ids())
             or private.has_role(v_org, array['admin', 'ops_manager'])) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return (
    with o as materialized (
      select c.id, c.currency, c.cause, c.created_at, c.entry_id, private.client_credit_open(c.id) as open_minor
      from (select q.id, q.currency, q.cause, q.created_at, q.organization_id, q.entry_id from public.client_credit q
            where q.client_organization_id = p_client_organization_id offset 0) c
      where c.organization_id = v_org)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                                 'credit_id', o.id, 'currency', o.currency, 'cause', o.cause,
                                 'created_on', (o.created_at at time zone 'Europe/Paris')::date,
                                 -- (review round 3) the day the money was received: its payment's entry's date, by
                                 -- the entry's primary key
                                 'received_on', (select e.effective_date from public.ledger_entry e
                                                 where e.id = o.entry_id),
                                 'open_minor', o.open_minor::text) order by o.created_at, o.id)
                        from o where o.open_minor > 0), '[]'),
      'total', coalesce((select jsonb_agg(jsonb_build_object('currency', t.currency, 'open_minor', t.s::text)
                                          order by t.currency)
                         from (select o.currency, sum(o.open_minor) as s from o where o.open_minor > 0
                               group by o.currency) t), '[]')));
end;
$$;

------------------------------------------------------------------------------------------
-- The commands (plan §5.2.4–§5.2.6)
------------------------------------------------------------------------------------------

-- A client's payment posted (both commands, after their checks and under their locks): the entry of p_type
-- (client_payment_own: +5122[own] P; client_payment_dedicated: +5120[b] P / −4679 P ‖ +4689 P) with −4111[c] Σ invoice
-- parts / −4112[c] Σ advance parts / −419[c] Σ credit parts / −7714 Σ recoveries / +44574 v / −44571 v (VAT lines only
-- when v > 0), dated p_on; one commission_settlement per document part (kind payment_own or payment_dedicated, its VAT
-- moved, settled on p_on); one client_credit per cause (their sum the −419 line; cause procedure naming the documents
-- the client meant — (review round 1, MONEY-1) an advance passed as a loss it may not repay among them, read as an
-- advance when no longer open); one advance_write_off_recovery per recovery. The result {entry_id, settled,
-- credit_minor, credits: [{cause, amount_minor}]} — (review round 1, TUI-2) what the page states once it is posted.
create or replace function private.client_payment_post(p_type text, p_org uuid, p_client uuid, p_currency char(3),
                                                       p_amount bigint, p_on date, p_rows jsonb, p_docs jsonb,
                                                       p_key text, p_source_type text, p_source_id text,
                                                       p_reason text, p_bank_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_inv bigint;
  v_adv bigint;
  v_cco bigint;
  v_rec bigint;
  v_vat bigint;
  v_entry uuid;
  v_kind text := case p_type when 'client_payment_own' then 'payment_own' else 'payment_dedicated' end;
begin
  select coalesce(sum((x ->> 'amount_minor')::bigint) filter (where x ->> 'document_kind' = 'invoice'), 0),
         coalesce(sum((x ->> 'amount_minor')::bigint) filter (where x ->> 'document_kind' = 'advance'), 0),
         coalesce(sum((x ->> 'amount_minor')::bigint) filter (where x ->> 'document_kind' = 'client_credit'), 0),
         coalesce(sum((x ->> 'amount_minor')::bigint) filter (where x ->> 'document_kind' = 'written_off'), 0),
         coalesce(sum((x ->> 'vat_moved_minor')::bigint), 0)
  into v_inv, v_adv, v_cco, v_rec, v_vat
  from jsonb_array_elements(p_rows) x;
  if v_inv + v_adv + v_cco + v_rec <> p_amount then
    raise exception 'client payment: its parts are not its amount' using errcode = 'LG006';
  end if;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason)
  values (1, p_org, p_type, p_on, p_key, p_client, p_source_type, p_source_id, p_reason);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select 1, row_number() over (order by l.n), l.book, l.amount, p_currency, l.bank
  from (values (1, case p_type when 'client_payment_own' then 'own_cash' else 'client_money_cash' end, p_amount,
                p_bank_account_id),
               (2, case when p_type = 'client_payment_dedicated' then 'due_to_servicer' end, -p_amount, null::uuid),
               (3, case when p_type = 'client_payment_dedicated' then 'due_from_client_funds' end, p_amount, null),
               (4, 'commission_receivable', -v_inv, null), (5, 'client_advance_receivable', -v_adv, null),
               (6, 'client_credit_owed', -v_cco, null), (7, 'written_off_recovered', -v_rec, null),
               (8, 'vat_pending', v_vat, null), (9, 'vat_collected', -v_vat, null)) l (n, book, amount, bank)
  where l.book is not null and l.amount <> 0;
  select x.entry_id into v_entry from private.ledger_post_set() x;
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id,
                                            entry_id, kind, amount_minor, vat_moved_minor, settled_on)
  select p_org, p_client, x ->> 'document_kind', (x ->> 'document_id')::uuid, v_entry, v_kind,
         (x ->> 'amount_minor')::bigint, (x ->> 'vat_moved_minor')::bigint, p_on
  from jsonb_array_elements(p_rows) with ordinality r (x, k)
  where x ->> 'document_kind' in ('invoice', 'advance')
  order by r.k;
  insert into public.client_credit (organization_id, client_organization_id, currency, cause, amount_minor, entry_id,
                                    details)
  select p_org, p_client, p_currency, x ->> 'cause', sum((x ->> 'amount_minor')::bigint), v_entry,
         nullif(jsonb_agg(jsonb_build_object(
                  'document_kind', coalesce((select d ->> 'kind' from jsonb_array_elements(p_docs) d
                                             where d ->> 'id' = x ->> 'document_id'), 'advance'),
                  'document_id', x ->> 'document_id',
                  'number', (select d ->> 'number' from jsonb_array_elements(p_docs) d
                             where d ->> 'id' = x ->> 'document_id'),
                  'amount_minor', x ->> 'amount_minor') order by (x ->> 'ord')::integer)
                  filter (where x ->> 'document_id' is not null), '[]'::jsonb)
  from jsonb_array_elements(p_rows) x
  where x ->> 'document_kind' = 'client_credit'
  group by x ->> 'cause';
  insert into public.advance_write_off_recovery (advance_id, entry_id, organization_id, client_organization_id, currency,
                                                 amount_minor)
  select (x ->> 'document_id')::uuid, v_entry, p_org, p_client, p_currency, (x ->> 'amount_minor')::bigint
  from jsonb_array_elements(p_rows) x
  where x ->> 'document_kind' = 'written_off';
  return jsonb_build_object(
    'entry_id', v_entry,
    'settled', (select coalesce(jsonb_agg(jsonb_build_object(
                  'document_kind', x ->> 'document_kind', 'document_id', x ->> 'document_id',
                  'number', (select d ->> 'number' from jsonb_array_elements(p_docs) d
                             where d ->> 'id' = x ->> 'document_id' and x ->> 'document_kind' = 'invoice'),
                  'amount_minor', x ->> 'amount_minor', 'vat_moved_minor', x ->> 'vat_moved_minor')
                  order by (x ->> 'ord')::integer), '[]')
                from jsonb_array_elements(p_rows) x
                where x ->> 'document_kind' in ('invoice', 'advance', 'written_off')),
    'credit_minor', v_cco::text,
    'credits', (select coalesce(jsonb_agg(jsonb_build_object('cause', c.cause, 'amount_minor', c.amount::text)
                                          order by c.cause), '[]')
                from (select x ->> 'cause' as cause, sum((x ->> 'amount_minor')::bigint) as amount
                      from jsonb_array_elements(p_rows) x where x ->> 'document_kind' = 'client_credit'
                      group by x ->> 'cause') c));
end;
$$;

-- The plan's rows of a payment as the post takes them (jsonb, amounts as numbers inside: never leaves the function)
create or replace function private.client_payment_rows(p_free jsonb, p_amount bigint, p_named uuid[], p_recoveries jsonb,
                                                       p_procedure boolean, p_on date)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('ord', p.ord, 'document_kind', p.document_kind,
                                               'document_id', p.document_id, 'amount_minor', p.amount_minor,
                                               'vat_moved_minor', p.vat_moved_minor, 'cause', p.cause) order by p.ord),
                  '[]')
  from private.client_payment_plan(p_free, p_amount, p_named, p_recoveries, p_procedure, p_on) p;
$$;

-- 5.2.4 « Règlement du client » received on the own account (design §7.3, §16): admins and ops managers at aal2; replay
-- and request hash. The amount in euros (private.euros_to_minor), its value date (not in the future: OQ-37, OQ-90), the
-- evidence of the transfer (a client_payment_evidence of that client), the own account (servicer_billing_settings: active,
-- purpose own, the currency); [critic] L16 the documents the client designates (p_documents, its order) and the
-- written-off advances it repays (p_recover_written_off) only with its designation's evidence
-- (payment_designation_evidence of that client: ops never choose which debt a payment settles, C. civ. 1342-10 al. 1);
-- under the allocation and remit locks (private.remittance_command_locks: the plans of approved runs are read under the
-- locks approvals take) — a named document with nothing open, of another client or currency (not_open), or settled by
-- an approved or sent run (in_flight, its run in the detail); with no designation, documents in flight are skipped by
-- the default order; (review round 4) only what existed on the value date is settled — a document issued or born, or
-- a loss passed, after it is skipped by the default order, and refused bad_date when named (its day in the detail);
-- what it may settle is what the page showed (open_changed). Never refused for exceeding what is
-- open ([critic] M7-MONEY-10): the surplus is a credit owed back; a pre-opening document the client names is not
-- refused ([critic] L21): its part is held for the procedure. Posts client_payment_own (private.client_payment_post;
-- source the evidence, key cpay:<md5 of the idempotency key>, dated the value date, reason « Règlement du client par
-- virement sur le compte du cabinet (valeur JJ/MM/AAAA) »; ops' motif in the command record, staff only). Refusals
-- « client payment refused: <code> » (check_violation). Returns {entry_id, settled, credit_minor, credits}.
create or replace function public.record_client_payment(p_idempotency_key text, p_client_organization_id uuid,
                                                        p_currency char(3), p_amount_text text, p_value_date date,
                                                        p_evidence_document_id uuid, p_documents uuid[],
                                                        p_designation_document_id uuid, p_recover_written_off uuid[],
                                                        p_expected_open_text text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  c public.organization;
  v_request jsonb;
  v_result jsonb;
  v_amount bigint := private.euros_to_minor(p_amount_text);
  v_own uuid;
  v_docs jsonb;
  v_free jsonb;
  v_rec jsonb;
  v_why record;
  v_rows jsonb;
begin
  select * into c from public.organization where id = p_client_organization_id and kind <> 'servicer';
  if not found or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('client_organization_id', p_client_organization_id, 'currency', p_currency,
                                  'amount', p_amount_text, 'value_date', p_value_date,
                                  'evidence_document_id', p_evidence_document_id, 'documents', p_documents,
                                  'designation_document_id', p_designation_document_id,
                                  'recover_written_off', p_recover_written_off, 'expected_open', p_expected_open_text,
                                  'reason', p_reason);
  v_result := private.command_replay('record_client_payment', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'client payment refused: bad_amount' using errcode = 'check_violation';
  end if;
  if p_value_date is null or p_value_date > private.paris_today() then
    raise exception 'client payment refused: bad_date' using errcode = 'check_violation';
  end if;
  if p_expected_open_text is null or p_expected_open_text !~ '^[0-9]{1,16}$' or p_currency is null
     or array_position(p_documents, null) is not null or array_position(p_recover_written_off, null) is not null
     or coalesce(cardinality(p_documents), 0) <> (select count(distinct x) from unnest(p_documents) x)
     or coalesce(cardinality(p_recover_written_off), 0) <> (select count(distinct x) from unnest(p_recover_written_off) x)
     or length(p_reason) > 2000 then
    raise exception 'client payment refused: bad_request' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, c.id, 'client_payment_evidence') then
    raise exception 'client payment refused: evidence_required' using errcode = 'check_violation';
  end if;
  select b.id into v_own from public.servicer_billing_settings s
  join public.bank_account b on b.id = s.own_bank_account_id
  where s.organization_id = c.servicer_organization_id and b.purpose = 'own' and b.status = 'active'
    and b.currency = p_currency;
  if v_own is null then
    raise exception 'client payment refused: no_own_account' using errcode = 'check_violation';
  end if;
  if (coalesce(cardinality(p_documents), 0) > 0 or coalesce(cardinality(p_recover_written_off), 0) > 0)
     and (p_designation_document_id is null
          or not private.client_document_of(p_designation_document_id, c.id, 'payment_designation_evidence')) then
    raise exception 'client payment refused: designation_evidence_required' using errcode = 'check_violation';
  end if;
  -- the locks of an approval (the plans of approved runs, the documents' open parts): allocation, then remit
  perform private.remittance_command_locks(c.servicer_organization_id, true);
  v_docs := private.client_payment_docs(c.id, p_currency, p_value_date);
  v_free := private.client_payment_free(v_docs);
  v_rec := private.client_payment_recoveries(c.id, p_currency, p_recover_written_off, p_value_date);
  select * into v_why from private.client_payment_named_refusal(v_docs, p_documents, p_recover_written_off, v_rec);
  if v_why.code is not null then
    raise exception 'client payment refused: %', v_why.code using errcode = 'check_violation',
      detail = coalesce(v_why.detail, '');
  end if;
  if private.client_payment_considered(v_free, p_documents, v_rec) <> p_expected_open_text::bigint then
    raise exception 'client payment refused: open_changed' using errcode = 'check_violation';
  end if;
  v_rows := private.client_payment_rows(v_free, v_amount, p_documents, v_rec,
                                        private.client_proceeding_stands(c.id, p_value_date), p_value_date);
  v_result := private.client_payment_post(
    'client_payment_own', c.servicer_organization_id, c.id, p_currency, v_amount, p_value_date, v_rows, v_docs,
    'cpay:' || md5(p_idempotency_key), 'document', p_evidence_document_id::text,
    'Règlement du client par virement sur le compte du cabinet (valeur ' || to_char(p_value_date, 'DD/MM/YYYY') || ')',
    v_own);
  perform private.ledger_check_now();
  perform private.command_record('record_client_payment', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- 5.2.5 « Règlement d'une facture ou d'une avance du cabinet »: a client's credit on the dedicated account that pays
-- the servicer (design §12 client_transfer_in → client_payment_dedicated; 6b-2 S27). Admins and ops managers at aal2;
-- replay and request hash; a motif (1–2,000 characters, staff only). [critic] F7 the funds pass's lock order: the
-- allocation lock, then the line FOR NO KEY UPDATE, then the remit lock; the line's facts read under them
-- (private.client_line_facts: not_a_client_credit, our_reference, line_booked, ambiguous_client). The whole line is the
-- amount; the client's designation as 5.2.4 — or ([critic] L16) its label naming each designated invoice's number;
-- (review round 4) what it settles existed on the line's booking date, as 5.2.4 (an invoice issued later is no
-- designation of its label: public.client_payment_line leaves it out). Posts
-- client_payment_dedicated (private.client_payment_post; source the line, key cpayd:<line>, dated the line's booking
-- date, reason « Règlement du client reçu sur le compte dédié (le JJ/MM/AAAA) »), its bank_line_booking (kind
-- client_payment, method ops, the motif; the booking guard's client_payment arm), the line's review gone, the commit
-- checks now. The servicer's share on 4679 grows by it: the next file's sweep takes it. Returns as 5.2.4.
create or replace function public.book_client_payment_line(p_idempotency_key text, p_bank_transaction_id uuid,
                                                           p_documents uuid[], p_designation_document_id uuid,
                                                           p_recover_written_off uuid[], p_expected_open_text text,
                                                           p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  f record;
  v_docs jsonb;
  v_free jsonb;
  v_rec jsonb;
  v_why record;
  v_rows jsonb;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'documents', p_documents,
                                  'designation_document_id', p_designation_document_id,
                                  'recover_written_off', p_recover_written_off, 'expected_open', p_expected_open_text,
                                  'reason', v_reason);
  v_result := private.command_replay('book_client_payment_line', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'client payment refused: reason_required' using errcode = 'check_violation';
  end if;
  if p_expected_open_text is null or p_expected_open_text !~ '^[0-9]{1,16}$'
     or array_position(p_documents, null) is not null or array_position(p_recover_written_off, null) is not null
     or coalesce(cardinality(p_documents), 0) <> (select count(distinct x) from unnest(p_documents) x)
     or coalesce(cardinality(p_recover_written_off), 0) <> (select count(distinct x) from unnest(p_recover_written_off) x)
  then
    raise exception 'client payment refused: bad_request' using errcode = 'check_violation';
  end if;
  -- [critic] F7: the funds pass's order — the allocation lock, the line, then the remit lock; the facts re-read
  perform private.remittance_command_locks(t.organization_id, false);
  perform 1 from public.bank_transaction x where x.id = t.id for no key update;
  perform private.remittance_command_locks(t.organization_id, true);
  select * into f from private.client_line_facts(t.id);
  if f.refusal is not null then
    raise exception 'client payment refused: %', f.refusal using errcode = 'check_violation';
  end if;
  v_docs := private.client_payment_docs(f.client_id, t.currency, t.booking_date);
  if coalesce(cardinality(p_recover_written_off), 0) > 0
     and (p_designation_document_id is null
          or not private.client_document_of(p_designation_document_id, f.client_id, 'payment_designation_evidence'))
     or coalesce(cardinality(p_documents), 0) > 0
        and (p_designation_document_id is null
             or not private.client_document_of(p_designation_document_id, f.client_id, 'payment_designation_evidence'))
        -- [critic] L16: a label naming each designated invoice by its number is the client's designation
        and exists (select 1 from unnest(p_documents) n (id)
                    where not exists (select 1 from jsonb_array_elements(v_docs) x
                                      where (x ->> 'id')::uuid = n.id and x ->> 'kind' = 'invoice'
                                        and position(upper(x ->> 'number') in upper(coalesce(t.remittance_text, ''))) > 0))
  then
    raise exception 'client payment refused: designation_evidence_required' using errcode = 'check_violation';
  end if;
  v_free := private.client_payment_free(v_docs);
  v_rec := private.client_payment_recoveries(f.client_id, t.currency, p_recover_written_off, t.booking_date);
  select * into v_why from private.client_payment_named_refusal(v_docs, p_documents, p_recover_written_off, v_rec);
  if v_why.code is not null then
    raise exception 'client payment refused: %', v_why.code using errcode = 'check_violation',
      detail = coalesce(v_why.detail, '');
  end if;
  if private.client_payment_considered(v_free, p_documents, v_rec) <> p_expected_open_text::bigint then
    raise exception 'client payment refused: open_changed' using errcode = 'check_violation';
  end if;
  v_rows := private.client_payment_rows(v_free, t.amount_minor, p_documents, v_rec,
                                        private.client_proceeding_stands(f.client_id, t.booking_date), t.booking_date);
  v_result := private.client_payment_post(
    'client_payment_dedicated', t.organization_id, f.client_id, t.currency, t.amount_minor, t.booking_date, v_rows,
    v_docs, 'cpayd:' || t.id, 'bank_transaction', t.id::text,
    'Règlement du client reçu sur le compte dédié (le ' || to_char(t.booking_date, 'DD/MM/YYYY') || ')',
    t.bank_account_id);
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, entry_id,
                                        amount_minor, method, reason, decided_by)
  values (t.id, 1, t.organization_id, t.bank_account_id, 'client_payment', (v_result ->> 'entry_id')::uuid,
          t.amount_minor, 'ops', v_reason, auth.uid());
  delete from public.bank_debit_review v where v.bank_transaction_id = t.id;
  perform private.ledger_check_now();
  set constraints public.bank_line_booking_complete immediate;
  set constraints public.bank_line_booking_complete deferred;
  perform private.command_record('book_client_payment_line', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- 5.2.6 « Enregistrer le remboursement »: what the servicer owes back, paid by its own transfer — a credit note's
-- refund still owed (design §14.1, §16; credit_refund_owed) or [critic] a client credit (cause procedure: to the
-- administrator, mandataire or liquidator the evidence names). Admins and ops managers at aal2; replay and request hash.
-- Owed = private.document_open (a credit note) or the credit's open part; recorded after the fact on proof (founder Q7;
-- own-account statements are not imported, design R12). Refusals (« client refund refused: <code> »): bad_amount,
-- bad_date (not in the future; (review round 4) under the locks, nor before what it pays back existed — a client
-- credit's receipt, its payment's entry's date read by the entry's primary key, or a credit note's issue date: that
-- day, the earliest allowed, in the detail), bad_request, evidence_required (a client_refund_evidence of that client),
-- no_own_account, nothing_owed, in_flight (an approved or sent run's plan pays the credit note as a refund: its run in
-- the detail), owed_changed (the owed the page showed), amount_exceeds_owed. Locks as 5.2.4. Posts client_refund_own
-- (+4111[c] R for a credit note, +419[c] R for a client credit / −5122[own] R; source the evidence, key crfd:<md5 of the
-- idempotency key>, dated p_paid_on, reason « Remboursement au client par virement depuis le compte du cabinet (le
-- JJ/MM/AAAA) ») and its commission_settlement (document_kind credit_note or client_credit, kind refund, no VAT):
-- private.document_open counts it, so credit_refund_owed stops. Returns {entry_id, owed_after_minor}.
create or replace function public.record_client_refund(p_idempotency_key text, p_document_id uuid, p_amount_text text,
                                                       p_paid_on date, p_evidence_document_id uuid,
                                                       p_expected_owed_text text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
set enable_seqscan = off
as $$
declare
  v_kind text;
  v_org uuid;
  v_client uuid;
  v_currency char(3);
  v_request jsonb;
  v_result jsonb;
  v_amount bigint := private.euros_to_minor(p_amount_text);
  v_own uuid;
  v_owed bigint;
  v_run text;
  v_entry uuid;
  v_since date;
begin
  select case i.kind when 'credit_note' then 'credit_note' else 'invoice' end, i.organization_id,
         i.client_organization_id, i.currency
  into v_kind, v_org, v_client, v_currency
  from public.commission_invoice i where i.id = p_document_id;
  if v_kind is null then
    select 'client_credit', c.organization_id, c.client_organization_id, c.currency
    into v_kind, v_org, v_client, v_currency
    from public.client_credit c where c.id = p_document_id;
  end if;
  if v_kind is null or not private.has_role(v_org, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('document_id', p_document_id, 'amount', p_amount_text, 'paid_on', p_paid_on,
                                  'evidence_document_id', p_evidence_document_id, 'expected_owed', p_expected_owed_text,
                                  'reason', p_reason);
  v_result := private.command_replay('record_client_refund', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_amount is null or v_amount <= 0 then
    raise exception 'client refund refused: bad_amount' using errcode = 'check_violation';
  end if;
  if p_paid_on is null or p_paid_on > private.paris_today() then
    raise exception 'client refund refused: bad_date' using errcode = 'check_violation';
  end if;
  if p_expected_owed_text is null or p_expected_owed_text !~ '^[0-9]{1,16}$' or length(p_reason) > 2000 then
    raise exception 'client refund refused: bad_request' using errcode = 'check_violation';
  end if;
  if p_evidence_document_id is null
     or not private.client_document_of(p_evidence_document_id, v_client, 'client_refund_evidence') then
    raise exception 'client refund refused: evidence_required' using errcode = 'check_violation';
  end if;
  select b.id into v_own from public.servicer_billing_settings s
  join public.bank_account b on b.id = s.own_bank_account_id
  where s.organization_id = v_org and b.purpose = 'own' and b.status = 'active' and b.currency = v_currency;
  if v_own is null then
    raise exception 'client refund refused: no_own_account' using errcode = 'check_violation';
  end if;
  perform private.remittance_command_locks(v_org, true);
  v_owed := case v_kind when 'credit_note' then private.document_open(p_document_id)
                        when 'client_credit' then private.client_credit_open(p_document_id) else 0 end;
  if coalesce(v_owed, 0) <= 0 then
    raise exception 'client refund refused: nothing_owed' using errcode = 'check_violation';
  end if;
  -- (review round 4) never before what it pays back existed: the credit's receipt (its payment's entry, by its primary
  -- key) or the credit note's issue — the append-only ledger would carry a refund of nothing on the days between
  v_since := case v_kind
               when 'credit_note' then (select i.issue_date from public.commission_invoice i where i.id = p_document_id)
               else (select e.effective_date
                     from (select c.entry_id from public.client_credit c where c.id = p_document_id offset 0) c
                     cross join lateral (select q.effective_date from public.ledger_entry q
                                         where q.id = c.entry_id offset 0) e) end;
  if v_since is null or p_paid_on < v_since then
    raise exception 'client refund refused: bad_date' using errcode = 'check_violation',
      detail = coalesce(to_char(v_since, 'YYYY-MM-DD'), '');
  end if;
  if v_kind = 'credit_note' then
    select f.run_number into v_run from private.document_in_flight_run(p_document_id, v_client, v_currency) f limit 1;
    if v_run is not null then
      raise exception 'client refund refused: in_flight' using errcode = 'check_violation', detail = v_run;
    end if;
  end if;
  if v_owed <> p_expected_owed_text::bigint then
    raise exception 'client refund refused: owed_changed' using errcode = 'check_violation';
  end if;
  if v_amount > v_owed then
    raise exception 'client refund refused: amount_exceeds_owed' using errcode = 'check_violation',
      detail = v_owed::text;
  end if;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                                  client_organization_id, source_type, source_id, reason)
  values (1, v_org, 'client_refund_own', p_paid_on, 'crfd:' || md5(p_idempotency_key), v_client, 'document',
          p_evidence_document_id::text,
          'Remboursement au client par virement depuis le compte du cabinet (le ' || to_char(p_paid_on, 'DD/MM/YYYY')
          || ')');
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, case v_kind when 'credit_note' then 'commission_receivable' else 'client_credit_owed' end, v_amount,
     v_currency, null),
    (1, 2, 'own_cash', -v_amount, v_currency, v_own);
  select x.entry_id into v_entry from private.ledger_post_set() x;
  insert into public.commission_settlement (organization_id, client_organization_id, document_kind, document_id,
                                            entry_id, kind, amount_minor, vat_moved_minor, settled_on)
  values (v_org, v_client, v_kind, p_document_id, v_entry, 'refund', v_amount, 0, p_paid_on);
  perform private.ledger_check_now();
  v_result := jsonb_build_object('entry_id', v_entry, 'owed_after_minor', (v_owed - v_amount)::text);
  perform private.command_record('record_client_refund', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- The nightly (plan §5.2.8), the evidence kinds (§5.1), the client space (carried low 3)
------------------------------------------------------------------------------------------

-- private.run_advance_checks, redefined from 20261123090000_advance_recovery.sql (line 674, 7b's: the CI round's
-- body and 7b's recovery; same signature and settings, its grants restated below). M2c-7c-1 (plan §5.2.8, §5.0 (7)):
-- three checks after advance_open — client_credit_owed (alert; P0 at once for cause procedure), client_credit_ledger
-- and written_off_recovery_ledger (violations). Its other statements are unchanged.
create or replace function private.run_advance_checks(p_check_run_id uuid, p_organization_id uuid,
                                                      p_today date default null, p_full boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_today date := coalesce(p_today, private.paris_today());
  v_prev uuid;
  v_since timestamptz;
  v_since_date date;
  v_full boolean := coalesce(p_full, false);
  v_from_ts timestamptz;
  v_from_date date;
begin
  select r.id, r.started_at - interval '1 day' into v_prev, v_since
  from public.payment_check_run r
  where r.organization_id = p_organization_id and r.finished_at is not null and r.id <> p_check_run_id
  order by r.started_at desc limit 1;
  if v_prev is null then
    v_full := true;
  end if;
  v_since_date := (v_since at time zone 'Europe/Paris')::date;
  -- (review round 1, CC-2) the window's lower bounds, -infinity for the full pass: a key range in every plan — a
  -- « v_full or … » predicate is a filter under the generic plan PL/pgSQL caches after five calls in one backend, and
  -- the delta pass would then read every booked run, attribution and cover of the servicer
  v_from_ts := case when v_full then '-infinity'::timestamptz else v_since end;
  v_from_date := case when v_full then '-infinity'::date else v_since_date end;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with day_rev as materialized (     -- the reversals posted since (ledger_entry_reversal_posted_idx)
    select x.id, x.reverses_entry_id from public.ledger_entry x
    where not v_full and x.organization_id = p_organization_id and x.entry_type = 'reversal' and x.posted_at >= v_since),
  booked as materialized (           -- the runs booked since (remittance_run_booked_idx), every one in the full pass
    select q.id from public.remittance_run q
    where q.organization_id = p_organization_id and q.status = 'booked' and q.booked_on >= v_from_date
    union
    -- (review round 1, CC-1) and the runs whose payout booking was recorded since, whatever their booked_on (the
    -- debit's date: a statement imported late, a late predecessor): bank_line_booking_org_idx, each transfer's run by key
    select t.run_id
    from (select b.transfer_id from public.bank_line_booking b
          where not v_full and b.organization_id = p_organization_id and b.decided_at >= v_from_ts
            and b.kind = 'payout' offset 0) b
    cross join lateral (select t.run_id from public.bank_transfer t
                        where t.id = b.transfer_id and t.run_id is not null offset 0) t),
  cand as materialized (
    select d.id as reversal_id from day_rev d
    union
    select a.cause_entry_id from day_rev d
    cross join lateral (select q.cause_entry_id from public.client_advance q
                        where q.entry_id = d.reverses_entry_id and q.cause = 'remitted_reversal' offset 0) a
    union
    select z.id from day_rev d
    cross join lateral (select u.ledger_entry_id from private.unplanned_paid_item u
                        where u.booking_entry_id = d.reverses_entry_id offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select z.id
    from booked r
    -- (CI round, main) each run's lines by the run's key alone, their conditions outside the fence
    cross join lateral (select l.ledger_entry_id, l.released, l.kind from public.remittance_line l
                        where l.run_id = r.id offset 0) l
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = l.ledger_entry_id offset 0) z
    where not l.released and l.kind in ('allocation', 'forward')
    union
    select z.id
    from (select u.ledger_entry_id from private.unplanned_paid_item u
          where u.organization_id = p_organization_id and u.created_at >= v_from_ts offset 0) u
    cross join lateral (select z.id from public.ledger_entry z where z.reverses_entry_id = u.ledger_entry_id offset 0) z
    union
    select a.cause_entry_id from public.client_advance a
    where a.organization_id = p_organization_id and a.cause = 'remitted_reversal' and a.created_at >= v_from_ts
    union
    select c.subject_id from public.payment_check_result c
    where c.run_id = v_prev and c.code = 'remitted_reversal_uncovered' and c.subject_id is not null)
  select p_check_run_id, p_organization_id, 'remitted_reversal_uncovered', 'violation', 'ledger_entry', c.reversal_id,
         f.currency, f.target - f.held, 1, v_today - (e.posted_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', f.client_organization_id, 'reversed_entry_id', e.reverses_entry_id,
                            'run_id', f.run_id, 'target', f.target::text, 'held', f.held::text,
                            'recorded_on', (e.posted_at at time zone 'Europe/Paris')::date)
  from cand c
  cross join lateral private.remitted_cover_fact(c.reversal_id) f
  cross join lateral (select q.posted_at, q.reverses_entry_id from public.ledger_entry q
                      where q.id = c.reversal_id offset 0) e
  where f.target <> f.held;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with adv as materialized (
    select a.client_organization_id, a.currency, sum(a.amount_minor - coalesce(s.settled, 0))::bigint as open_minor
    from (select q.id, q.client_organization_id, q.currency, q.amount_minor, q.entry_id from public.client_advance q
          where q.organization_id = p_organization_id offset 0) a
    left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                       where c.document_kind = 'advance' and c.document_id = a.id) s on true
    where not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id)
    group by a.client_organization_id, a.currency),
  led as materialized (
    select la.client_organization_id, la.currency, coalesce(sum(p.s), 0)::bigint as balance_minor
    from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'client_advance_receivable' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.client_organization_id, la.currency)
  select p_check_run_id, p_organization_id, 'advance_ledger', 'violation', 'client',
         coalesce(a.client_organization_id, l.client_organization_id), coalesce(a.currency, l.currency),
         coalesce(l.balance_minor, 0) - coalesce(a.open_minor, 0), 1, null,
         jsonb_build_object('client_id', coalesce(a.client_organization_id, l.client_organization_id),
                            'advances_open', coalesce(a.open_minor, 0)::text,
                            'receivable', coalesce(l.balance_minor, 0)::text)
  from adv a
  full join led l on l.client_organization_id = a.client_organization_id and l.currency = a.currency
  where coalesce(a.open_minor, 0) <> coalesce(l.balance_minor, 0);

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'advance_open', 'alert', 'client_advance', a.id, a.currency,
         a.amount_minor - coalesce(s.settled, 0), 1, v_today - (a.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', a.client_organization_id, 'cause', a.cause, 'mandate_id', a.mandate_id,
                            'created_on', (a.created_at at time zone 'Europe/Paris')::date,
                            -- (M2c-7b) how it is recovered (review round 1: barred_proceeding when it was born before
                            -- the client's proceeding opened)
                            'recovery', (select r.recovery
                                         from private.advance_recovery_of(a.mandate_id, a.client_organization_id,
                                                                          private.advance_born_on(a.id), v_today) r))
         || case when a.cause = 'remitted_reversal'
                      and exists (select 1
                                  from (select z.reverses_entry_id from public.ledger_entry z
                                        where z.id = a.cause_entry_id offset 0) z
                                  cross join lateral (select l.run_id from public.remittance_line l
                                                      where l.ledger_entry_id = z.reverses_entry_id and not l.released
                                                      offset 0) l
                                  cross join lateral private.item_settled_at(z.reverses_entry_id, l.run_id, 0) t
                                  where t.too_deep)
                 then jsonb_build_object('settled_on_depth', true) else '{}'::jsonb end
  from (select q.id, q.client_organization_id, q.currency, q.amount_minor, q.cause, q.mandate_id, q.created_at,
               q.entry_id, q.cause_entry_id
        from public.client_advance q
        where q.organization_id = p_organization_id
          and q.created_at < ((v_today - 30)::timestamp at time zone 'Europe/Paris') offset 0) a
  left join lateral (select sum(c.amount_minor) as settled from public.commission_settlement c
                     where c.document_kind = 'advance' and c.document_id = a.id) s on true
  where a.amount_minor > coalesce(s.settled, 0)
    and not exists (select 1 from public.ledger_entry z where z.reverses_entry_id = a.entry_id);

  -- (M2c-7c-1, plan §5.2.8) [critic] client_credit_owed (alert): what the servicer owes a client back, still open more
  -- than 15 days after it was recorded — at once (P0, `p0` in its details) for a sum held for the client's collective
  -- proceeding (cause procedure: ops and counsel decide, OQ-98). The servicer's credits by client_credit_org_idx, each
  -- one's refunds by commission_settlement_document_idx.
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select p_check_run_id, p_organization_id, 'client_credit_owed', 'alert', 'client_credit', c.id, c.currency, o.open_minor,
         1, v_today - (c.created_at at time zone 'Europe/Paris')::date,
         jsonb_build_object('client_id', c.client_organization_id, 'cause', c.cause,
                            'created_on', (c.created_at at time zone 'Europe/Paris')::date, 'p0', c.cause = 'procedure')
  from (select q.id, q.client_organization_id, q.currency, q.cause, q.created_at from public.client_credit q
        where q.organization_id = p_organization_id offset 0) c
  cross join lateral (select private.client_credit_open(c.id) as open_minor) o
  where o.open_minor > 0
    and (c.cause = 'procedure' or c.created_at < ((v_today - 15)::timestamp at time zone 'Europe/Paris'));

  -- (M2c-7c-1, plan §5.0 (7)) [check 1] client_credit_ledger (violation, per client): Σ the open parts of its credits
  -- owed back = −Σ its 419 postings
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with cc as materialized (
    select c.client_organization_id, c.currency, sum(c.amount_minor - coalesce(r.refunded, 0))::bigint as open_minor
    from (select q.id, q.client_organization_id, q.currency, q.amount_minor from public.client_credit q
          where q.organization_id = p_organization_id offset 0) c
    left join lateral (select sum(s.amount_minor) as refunded from public.commission_settlement s
                       where s.document_id = c.id and s.document_kind = 'client_credit') r on true
    group by c.client_organization_id, c.currency),
  led as materialized (
    select la.client_organization_id, la.currency, coalesce(-sum(p.s), 0)::bigint as owed_minor
    from (select l.id, l.client_organization_id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'client_credit_owed' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.client_organization_id, la.currency)
  select p_check_run_id, p_organization_id, 'client_credit_ledger', 'violation', 'client',
         coalesce(c.client_organization_id, l.client_organization_id), coalesce(c.currency, l.currency),
         coalesce(l.owed_minor, 0) - coalesce(c.open_minor, 0), 1, null,
         jsonb_build_object('client_id', coalesce(c.client_organization_id, l.client_organization_id),
                            'credits_open', coalesce(c.open_minor, 0)::text, 'ledger', coalesce(l.owed_minor, 0)::text)
  from cc c
  full join led l on l.client_organization_id = c.client_organization_id and l.currency = c.currency
  where coalesce(c.open_minor, 0) <> coalesce(l.owed_minor, 0);

  -- (M2c-7c-1, plan §5.0 (7)) [check 1] written_off_recovery_ledger (violation, the servicer): Σ the recoveries of its
  -- advances passed as a loss = −Σ its 7714 postings, per currency
  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  with rec as materialized (
    select r.currency, sum(r.amount_minor)::bigint as recovered_minor
    from (select q.currency, q.amount_minor from public.advance_write_off_recovery q
          where q.organization_id = p_organization_id offset 0) r
    group by r.currency),
  led as materialized (
    select la.currency, coalesce(-sum(p.s), 0)::bigint as income_minor
    from (select l.id, l.currency from public.ledger_account l
          where l.organization_id = p_organization_id and l.book = 'written_off_recovered' offset 0) la
    cross join lateral (select sum(q.amount_minor) as s from public.ledger_posting q
                        where q.ledger_account_id = la.id) p
    group by la.currency)
  select p_check_run_id, p_organization_id, 'written_off_recovery_ledger', 'violation', 'servicer', null,
         coalesce(r.currency, l.currency), coalesce(l.income_minor, 0) - coalesce(r.recovered_minor, 0), 1, null,
         jsonb_build_object('recovered', coalesce(r.recovered_minor, 0)::text, 'ledger', coalesce(l.income_minor, 0)::text)
  from rec r
  full join led l on l.currency = r.currency
  where coalesce(r.recovered_minor, 0) <> coalesce(l.income_minor, 0);
end;
$$;

-- public.register_client_document (« Joindre un document »), redefined from 20261123090000_advance_recovery.sql
-- (line 1701, 7b's; same signature and settings, its grants restated below). M2c-7c-1 (plan §5.1, [critic] F11, L16):
-- it also takes the kinds client_payment_evidence (a client's transfer to the servicer), client_refund_evidence (the
-- servicer's transfer back) and payment_designation_evidence (the client's letter or transfer naming what it pays),
-- read by money staff only. Nothing else changes.
create or replace function public.register_client_document(p_idempotency_key text, p_client_organization_id uuid,
                                                           p_kind text, p_storage_path text, p_file_name text,
                                                           p_sha256 text, p_mime_type text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c public.organization;
  v_request jsonb := jsonb_build_object('client_organization_id', p_client_organization_id, 'kind', p_kind,
                                        'storage_path', p_storage_path, 'file_name', p_file_name,
                                        'sha256', lower(p_sha256), 'mime_type', p_mime_type);
  v_result jsonb;
  v_id uuid;
begin
  select * into c from public.organization where id = p_client_organization_id;
  if c.id is null or c.servicer_organization_id is null
     or not private.has_role(c.servicer_organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('register_client_document', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if p_kind is null or p_kind not in ('payout_rib', 'mandate_document', 'client_status_evidence',
                                     'advance_write_off_evidence', 'client_payment_evidence',
                                     'client_refund_evidence', 'payment_designation_evidence') then
    raise exception 'document: invalid kind' using errcode = 'check_violation';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-fA-F]{64}$' or p_file_name is null
     or length(p_file_name) not between 1 and 255 or p_file_name ~ '[/\\[:cntrl:]]'
     or p_mime_type is null or p_mime_type not in ('application/pdf', 'image/png', 'image/jpeg') then
    raise exception 'document: invalid file' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from private.client_document_key(p_storage_path) k
                 where k.servicer_id = c.servicer_organization_id and k.client_id = c.id) then
    raise exception 'document: the file is not at a key of this client' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'documents' and o.name = p_storage_path) then
    raise exception 'document: the file is not uploaded yet' using errcode = 'check_violation';
  end if;
  insert into public.document (organization_id, client_organization_id, kind, storage_bucket, storage_path, sha256,
                               mime_type, file_name)
  values (c.servicer_organization_id, c.id, p_kind, 'documents', p_storage_path, lower(p_sha256), p_mime_type,
          p_file_name)
  returning id into v_id;
  v_result := jsonb_build_object('document_id', v_id);
  perform private.command_record('register_client_document', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- private.can_read_client_document_object (the storage policy's), redefined from 20261123090000_advance_recovery.sql
-- (line 1757, 7b's; same signature and settings, its grants restated below): the files of the three new kinds too,
-- for whom private.can_read_client_document allows (money staff only). Nothing else changes.
create or replace function private.can_read_client_document_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.document d
                 where d.storage_bucket = 'documents' and d.storage_path = p_name
                   and d.kind in ('payout_rib', 'mandate_document', 'client_status_evidence',
                                  'advance_write_off_evidence', 'client_payment_evidence', 'client_refund_evidence',
                                  'payment_designation_evidence')
                   and private.can_read_client_document(d.organization_id, d.client_organization_id, d.kind));
$$;

-- the policy document_client_money_scope, recreated from 20261123090000_advance_recovery.sql (line 1776) with the
-- three new kinds (money staff only; private.can_read_client_document, unchanged, gives every kind but the RIB and the
-- mandate to money staff only)
drop policy document_client_money_scope on public.document;
create policy document_client_money_scope on public.document as restrictive for select to authenticated
  using (kind not in ('payout_rib', 'mandate_document', 'client_status_evidence', 'advance_write_off_evidence',
                      'client_payment_evidence', 'client_refund_evidence', 'payment_designation_evidence')
         or private.can_read_client_document(organization_id, client_organization_id, kind));

-- public.client_space_advances (the client space), redefined from 20261123090000_advance_recovery.sql (line 497; same
-- signature and settings, its grants restated below). M2c-7c-1 (carried low 3, ADR-0014 7b round 2 « Left open »): its
-- client's advances are read on client_advance_client_idx alone, the servicer checked outside the fence, as
-- private.client_open_advances — unfenced, the client and the servicer together, one client's space read every one of
-- the servicer's advances under stale statistics (10,005 rows in test_advance_reads_integration.py). Nothing else
-- changes.
create or replace function public.client_space_advances(p_client_organization_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_org uuid;
begin
  select c.servicer_organization_id into v_org from public.organization c
  where c.id = p_client_organization_id and c.kind <> 'servicer';
  if v_org is null
     or not (p_client_organization_id = any (private.client_whole_org_ids())
             or private.has_role(v_org, array['admin', 'ops_manager'])) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return (
    with o as materialized (
      select a.id, a.currency, a.cause, a.created_at, a.mandate_id, private.advance_open(a.id) as open_minor,
             private.advance_born_on(a.id) as born_on
      -- (M2c-7c-1) the client's advances by client_advance_client_idx alone, the servicer checked outside the fence
      from (select q.id, q.currency, q.cause, q.created_at, q.mandate_id, q.organization_id from public.client_advance q
            where q.client_organization_id = p_client_organization_id offset 0) a
      where a.organization_id = v_org)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                                 'advance_id', o.id, 'currency', o.currency, 'cause', o.cause,
                                 'created_on', (o.created_at at time zone 'Europe/Paris')::date, 'born_on', o.born_on,
                                 'open_minor', o.open_minor::text, 'recovery', r.recovery, 'clause_ref', r.clause_ref)
                               order by o.created_at, o.id)
                        from o cross join lateral private.advance_recovery_of(o.mandate_id, p_client_organization_id,
                                                                              o.born_on, private.paris_today()) r
                        where o.open_minor > 0), '[]'),
      'total', coalesce((select jsonb_agg(jsonb_build_object('currency', t.currency, 'open_minor', t.s::text)
                                          order by t.currency)
                         from (select o.currency, sum(o.open_minor) as s from o where o.open_minor > 0
                               group by o.currency) t), '[]')));
end;
$$;

------------------------------------------------------------------------------------------
-- Privileges (the new internals revoked; every redefined function's grants restated)
------------------------------------------------------------------------------------------

-- the new internals (PostgreSQL grants EXECUTE to PUBLIC by default): the commands, the reads and the checks use them
revoke execute on function private.client_credit_open(uuid), private.written_off_available(uuid),
  private.document_in_flight_run(uuid, uuid, char), private.client_opening_date(uuid, date),
  private.document_before_opening(uuid, date),
  private.document_client_payable(uuid, date), private.client_proceeding_stands(uuid, date),
  private.vat_part(bigint, bigint, bigint), private.client_payment_order(jsonb, date),
  private.client_payment_plan(jsonb, bigint, uuid[], jsonb, boolean, date),
  private.client_payment_considered(jsonb, uuid[], jsonb), private.client_payment_docs(uuid, char, date),
  private.client_payment_free(jsonb), private.client_payment_recoveries(uuid, char, uuid[], date),
  private.client_settlement_plan(uuid, char, bigint, uuid[], uuid[], date),
  private.client_payment_named_refusal(jsonb, uuid[], uuid[], jsonb), private.client_line_facts(uuid),
  private.client_payment_post(text, uuid, uuid, char, bigint, date, jsonb, jsonb, text, text, text, text, uuid),
  private.client_payment_rows(jsonb, bigint, uuid[], jsonb, boolean, date)
  from public, anon, authenticated, service_role;
-- the tables' guards: triggers'
revoke execute on function private.client_credit_guard(), private.advance_write_off_recovery_guard(),
  private.commission_settlement_credit_guard()
  from public, anon, authenticated;
-- the commands and the reads: authenticated (each checks the caller inside); never anon
revoke execute on function public.client_open_documents(uuid, char),
  public.client_payment_preview(uuid, char, text, uuid[], uuid[], date), public.client_payment_line(uuid, uuid[], uuid[]),
  public.client_space_credits(uuid),
  public.record_client_payment(text, uuid, char, text, date, uuid, uuid[], uuid, uuid[], text, text),
  public.book_client_payment_line(text, uuid, uuid[], uuid, uuid[], text, text),
  public.record_client_refund(text, uuid, text, date, uuid, text, text)
  from public, anon;
grant execute on function public.client_open_documents(uuid, char),
  public.client_payment_preview(uuid, char, text, uuid[], uuid[], date), public.client_payment_line(uuid, uuid[], uuid[]),
  public.client_space_credits(uuid),
  public.record_client_payment(text, uuid, char, text, date, uuid, uuid[], uuid, uuid[], text, text),
  public.book_client_payment_line(text, uuid, uuid[], uuid, uuid[], text, text),
  public.record_client_refund(text, uuid, text, date, uuid, text, text)
  to authenticated;

-- the redefined, as their latest migrations left them
-- (20261109090000) the ledger's posting set: internal
revoke execute on function private.ledger_post_set() from public, anon, authenticated, service_role;
-- (20261108170000) a balance asked by id: authenticated (its rule inside)
revoke execute on function public.ledger_balance(uuid, date, timestamptz) from public, anon;
grant execute on function public.ledger_balance(uuid, date, timestamptz) to authenticated;
-- (20261113090000) the accounting export: authenticated (money staff, checked inside)
revoke execute on function public.accounting_export_entries(date, date, text, integer) from public, anon;
grant execute on function public.accounting_export_entries(date, date, text, integer) to authenticated;
-- (20261122090000) the advance checks: internal
revoke execute on function private.run_advance_checks(uuid, uuid, date, boolean)
  from public, anon, authenticated, service_role;
-- (20261111120000) « Joindre un document » and the storage policy's helper
revoke execute on function public.register_client_document(text, uuid, text, text, text, text, text) from public, anon;
grant execute on function public.register_client_document(text, uuid, text, text, text, text, text) to authenticated;
revoke execute on function private.can_read_client_document_object(text) from public, anon, authenticated;
grant execute on function private.can_read_client_document_object(text) to authenticated;
-- (20261123090000) the client space's advances
revoke execute on function public.client_space_advances(uuid) from public, anon;
grant execute on function public.client_space_advances(uuid) to authenticated;
-- (20261123090000, review round 3) how an advance is recovered: internal
revoke execute on function private.advance_recovery_of(uuid, uuid, date, date)
  from public, anon, authenticated, service_role;
