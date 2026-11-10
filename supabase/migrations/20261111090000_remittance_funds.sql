-- M2c-1 (M2-12): the funds ledger. The ledger gets a second fund: the dedicated-account fund (5120, 4710, 4670 and the
-- new 4679 « Sommes revenant au cabinet sur le compte dédié ») and the servicer's fund (5122 own cash, 4111, 4112, 44571,
-- 44574, 4689, 7060, 6270, 6780). Every entry is closed inside each fund, and money crosses between them only through
-- 4679 / 4689, which mirror each other in every entry (as 1100 / 3100 do). No client-money exemption at all.
-- Design: docs/design/m2c-remittances.md §0, §1, §5, §6, §7, §12, §13, §15 (founder decisions §24, accepted 2026-11-09);
-- decisions: docs/adr/0014-remittances-commission-invoices-own-cash.md.
-- Forward-only: nothing of 20261110130000 or earlier is edited; the functions below are redefined with their SET
-- clauses, SECURITY DEFINER and grants restated.
--
-- What changes for money:
--   * nine books (4679, 4689, 5122, 4111, 4112, 44571, 44574, 6270, 6780); 7060 is no longer client-visible;
--   * the thirteen M2c entry types with their books and shapes (ledger_entry_verify, LG001), posted only by
--     private.ledger_post_set (never by ledger_post); each names its document (source_type / source_id, R123-174);
--     commission documents, settlements and write-offs are never reversed (LG003);
--   * per entry, at commit: each fund closed per currency (I2′), the 4679 / 4689 mirror (I12), the shapes (I3′);
--   * the allocation lock is taken for every entry that moves 4670 (by its lines, not its type), the remit lock
--     `remit:<org>` by every writer of 4679; order: allocation lock → remit lock (→ invoice counter, M2c-4);
--   * a per-client running balance of 4670 (private.client_payable_balance, kept by an ALWAYS statement trigger on the
--     postings) with a deferred commit guard: a client's 4670 never in debit (I13, new SQLSTATE LG008); the same
--     trigger feeds the pending queue of remittance items (private.remittance_pending, back-filled here);
--   * bank accounts: purpose 'own' (the servicer's own account, 5122); one active client_funds account per currency;
--     statements are imported only for client_funds accounts;
--   * statement lines: our own transfers out (`transfer_out`: RMT/SWP ids or a debit to our own IBAN), credits from our
--     own account (`own_transfer_in`: our TOP id or a registered own IBAN — never taken for a debtor payment by itself)
--     and from a client's payout IBAN (`client_transfer_in`, registered from M2c-2); camt.053 PmtInfId kept
--     (`payment_info_id`);
--   * a bank line can be booked by entries of the funds (`bank_line_booking`): bank fees (`bank_fee`, the servicer's
--     cost: automatically for camt.053 charges CHRG/FEES, otherwise by ops, M2b fee lines included), top-ups from the own
--     account (`servicer_top_up`: ordered by ops with our TOP id, booked when the credit shows), and the excess of a
--     return over what is left of its payment (`servicer_loss`, OQ-34: the M2b return of what is left + the loss);
--   * a credit from our own account that is a debtor's payment the servicer relayed becomes a payment of the dedicated
--     account by ops' decision (public.release_own_credit, bank_own_credit_release), booked as a released duplicate
--     credit is;
--   * every decision on a bank line (an M2b link, a booking in the funds, an own credit released) takes the line's
--     row lock (FOR NO KEY UPDATE), so a line is never both linked and booked;
--   * read access per book: money staff read both funds; a client reads its own 4670 and its own entries that move it,
--     and only a member with access to the whole client (OQ-48 default: never a member restricted to portfolios);
--   * nightly checks: I8′ (client money with 4679), I12 (mirror), the servicer fund closed, I13 (running balance =
--     postings, never in debit), I19 (each dedicated account's cash = payments in − returns and refunds ± what its
--     booked lines moved); the alert servicer_shortfall (4679 in debit beyond the top-ups ordered).
--
-- Redefined: private.ledger_account_guard, private.ledger_entry_guard, private.ledger_entry_verify, private.ledger_post,
-- private.ledger_reverse, private.ledger_post_set, public.register_bank_account (one parameter added: dropped and
-- created), public.close_bank_account, public.ledger_balance, the ledger_account / ledger_entry read policies,
-- private.ingest_statement, private.bank_transaction_held_kind, private.held_line_kind, private.bank_unposted,
-- private.debit_link_begin, private.post_debit_links, public.link_debit, public.debit_queue, private.run_payment_checks,
-- public.resolve_duplicate, private.payment_insert_guard, private.bank_debit_link_guard, private.debit_candidates,
-- private.apply_debit_decisions.

------------------------------------------------------------------------------------------
-- Books (§5.1). The numbers are our labels; the accountant maps them. 5122 records only the movements the dedicated
-- account shows and client payments ops prove: it is not the own account's bank balance (risk R12).
------------------------------------------------------------------------------------------

insert into public.ledger_book (code, account_number, label_fr, dimension, money_of, normal_side, client_visible) values
  ('due_to_servicer',           '4679',  'Sommes revenant au cabinet sur le compte dédié',    'pooled', 'client',   -1, false),
  ('due_from_client_funds',     '4689',  'Créance du cabinet sur le compte dédié',            'pooled', 'servicer',  1, false),
  ('own_cash',                  '5122',  'Compte propre du cabinet — mouvements enregistrés', 'bank',   'servicer',  1, false),
  ('commission_receivable',     '4111',  'Mandants — factures et avoirs de commission',       'client', 'servicer',  1, false),
  ('client_advance_receivable', '4112',  'Mandants — avances à récupérer',                    'client', 'servicer',  1, false),
  ('vat_collected',             '44571', 'TVA collectée exigible',                            'pooled', 'servicer', -1, false),
  ('vat_pending',               '44574', 'TVA collectée sur commissions non réglées',         'pooled', 'servicer', -1, false),
  ('bank_fees',                 '6270',  'Frais bancaires du compte dédié',                   'pooled', 'servicer',  1, false),
  ('servicer_losses',           '6780',  'Pertes à la charge du cabinet',                     'pooled', 'servicer',  1, false);
update public.ledger_book set client_visible = false where code = 'servicer_revenue';
comment on table public.ledger_book is
  'Chart of accounts (ARCHITECTURE §8). Two funds (M2c, ADR-0014): the dedicated-account fund (money_of client: 5120, '
  '4710, 4670, 4679) and the servicer''s fund (money_of servicer: 4689, 5122, 4111, 4112, 44571, 44574, 7060, 6270, 6780).';

------------------------------------------------------------------------------------------
-- Entry types (§5.2): the books each may touch. No M2c type touches 1100, 3100 or 4710 (L111-8; unallocated money is
-- never remitted); 7060 only through the two commission types; no M2b type reaches a servicer-fund book or 4679 (I10′).
------------------------------------------------------------------------------------------

insert into public.ledger_entry_type (code, label_fr, allowed_books, requires_reason) values
  ('commission_invoice',       'Facture de commission',
   array['commission_receivable', 'servicer_revenue', 'vat_pending', 'vat_collected'], false),
  ('commission_credit_note',   'Avoir sur commission',
   array['commission_receivable', 'servicer_revenue', 'vat_pending', 'vat_collected'], false),
  ('client_settlement',        'Compensation avec le reversement',
   array['client_payable', 'due_to_servicer', 'due_from_client_funds', 'commission_receivable',
         'client_advance_receivable', 'vat_pending', 'vat_collected'], false),
  ('remittance',               'Reversement au mandant',
   array['client_payable', 'client_money_cash'], false),
  ('servicer_sweep',           'Virement au compte propre',
   array['due_to_servicer', 'client_money_cash', 'own_cash', 'due_from_client_funds'], false),
  ('servicer_top_up',          'Approvisionnement par le compte propre',
   array['client_money_cash', 'due_to_servicer', 'due_from_client_funds', 'own_cash'], false),
  ('bank_fee',                 'Frais bancaires sur le compte dédié',
   array['due_to_servicer', 'client_money_cash', 'bank_fees', 'due_from_client_funds'], false),
  ('client_advance',           'Avance au mandant',
   array['due_to_servicer', 'client_payable', 'client_advance_receivable', 'due_from_client_funds'], false),
  ('servicer_loss',            'Perte à la charge du cabinet',
   array['due_to_servicer', 'client_money_cash', 'servicer_losses', 'due_from_client_funds'], true),
  ('client_payment_own',       'Règlement du mandant sur le compte propre',
   array['own_cash', 'commission_receivable', 'client_advance_receivable', 'vat_pending', 'vat_collected'], true),
  ('client_payment_dedicated', 'Règlement du mandant reçu sur le compte dédié',
   array['client_money_cash', 'due_to_servicer', 'due_from_client_funds', 'commission_receivable',
         'client_advance_receivable', 'vat_pending', 'vat_collected'], true),
  ('client_refund_own',        'Remboursement au mandant depuis le compte propre',
   array['commission_receivable', 'own_cash'], true),
  ('advance_write_off',        'Abandon d''avance',
   array['servicer_losses', 'client_advance_receivable'], true);
comment on table public.ledger_entry_type is
  'Entry types and the books each may touch (servicer_revenue only through the M2c commission types, CPCE-02).';

-- Every M2c entry names its document (C. com. R123-174: « les références de la pièce justificative »).
alter table public.ledger_entry add constraint ledger_entry_fund_source check (
  entry_type not in ('commission_invoice', 'commission_credit_note', 'client_settlement', 'remittance', 'servicer_sweep',
                     'servicer_top_up', 'bank_fee', 'client_advance', 'servicer_loss', 'client_payment_own',
                     'client_payment_dedicated', 'client_refund_own', 'advance_write_off')
  or (source_id is not null and source_type = any (case entry_type
        when 'commission_invoice' then array['commission_invoice']
        when 'commission_credit_note' then array['commission_invoice']
        when 'client_settlement' then array['remittance_run']
        when 'remittance' then array['bank_transfer', 'bank_transaction']
        when 'servicer_sweep' then array['bank_transfer', 'bank_transaction']
        when 'servicer_top_up' then array['bank_transfer', 'bank_transaction']
        when 'bank_fee' then array['bank_transaction']
        when 'client_advance' then array['client_advance']
        when 'servicer_loss' then array['bank_transaction']
        when 'client_payment_dedicated' then array['bank_transaction']
        else array['document'] end)));

------------------------------------------------------------------------------------------
-- Bank accounts: the servicer's own account (purpose 'own', book 5122); one active client_funds account per currency
-- (founder #14, enforced by register_bank_account below: a servicer that already had two keeps them). An own account
-- has no statement feed: its statements are not imported (§1 non-scope).
------------------------------------------------------------------------------------------

alter table public.bank_account drop constraint bank_account_purpose_check,
  add constraint bank_account_purpose_check check (purpose in ('client_funds', 'own'));
alter table public.bank_account alter column feed drop not null,
  add constraint bank_account_feed_purpose check ((feed is not null) = (purpose = 'client_funds'));
comment on table public.bank_account is
  'Bank accounts of the servicer. client_funds = the account dedicated to funds collected for creditors (R124-2); own = '
  'the servicer''s own account (commission swept to it, top-ups from it; its statements are not imported).';

-- A statement is the statement of a client_funds account (an own account's statements are not imported in M2c).
create or replace function private.bank_statement_purpose_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.bank_account b where b.id = new.bank_account_id and b.purpose = 'client_funds') then
    raise exception 'statements are imported for client_funds bank accounts only' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger bank_statement_purpose_guard before insert on public.bank_statement
  for each row execute function private.bank_statement_purpose_guard();
alter table public.bank_statement enable always trigger bank_statement_purpose_guard;

------------------------------------------------------------------------------------------
-- Ledger accounts (§5.3): 5122 like 5120 (its bank account only); 4111 / 4112 like 4670 (the client only); 4679, 4689,
-- 44571, 44574, 6270, 6780 pooled (no dimension). Books not listed are still refused (else false).
------------------------------------------------------------------------------------------

alter table public.ledger_account drop constraint ledger_account_shape,
  add constraint ledger_account_shape check (case
    when book = 'debtor_receivable' then account_id is not null and claim_item_id is not null and component is not null
      and client_organization_id is not null and portfolio_id is not null and owner_organization_id is null
      and bank_account_id is null
    when book = 'owner_claim' then account_id is null and claim_item_id is null and component is not null
      and client_organization_id is not null and owner_organization_id is not null and portfolio_id is not null
      and bank_account_id is null
    when book in ('client_payable', 'servicer_revenue', 'commission_receivable', 'client_advance_receivable') then
      client_organization_id is not null and portfolio_id is null and account_id is null and claim_item_id is null
      and component is null and owner_organization_id is null and bank_account_id is null
    when book = 'unallocated_payment' then portfolio_id is null and account_id is null and claim_item_id is null
      and component is null and owner_organization_id is null and bank_account_id is null
    when book in ('client_money_cash', 'own_cash') then bank_account_id is not null and client_organization_id is null
      and owner_organization_id is null and portfolio_id is null and account_id is null and claim_item_id is null
      and component is null
    when book in ('due_to_servicer', 'due_from_client_funds', 'vat_collected', 'vat_pending', 'bank_fees',
                  'servicer_losses') then
      client_organization_id is null and owner_organization_id is null and portfolio_id is null and account_id is null
      and claim_item_id is null and component is null and bank_account_id is null
    else false end);

-- The running balance's trigger reads the few 4670 accounts through this index (never the whole table).
create index ledger_account_client_payable_idx on public.ledger_account (id)
  include (organization_id, client_organization_id, currency) where book = 'client_payable';

-- Redefined from 20261109090000: a bank account's ledger account follows its purpose (5120 on an active client_funds
-- account, 5122 on an active own account, LG002); the rest is unchanged.
create or replace function private.ledger_account_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(coalesce(n.id::text, '?')) into v_bad from new_rows n
  where not exists (select 1 from public.ledger_book b where b.code = n.book)
     or not exists (select 1 from public.currency c where c.code = n.currency)
     or (n.component is not null and not exists (select 1 from public.ledger_component c where c.code = n.component))
     -- the servicer is a servicer; clients, owners and portfolios belong to it
     or not exists (select 1 from public.organization o where o.id = n.organization_id and o.kind = 'servicer')
     or (n.client_organization_id is not null and not exists (
           select 1 from public.organization o
           where o.id = n.client_organization_id and o.servicer_organization_id = n.organization_id))
     or (n.owner_organization_id is not null and not exists (
           select 1 from public.organization o where o.id = n.owner_organization_id))
     or (n.portfolio_id is not null and not exists (
           select 1 from public.portfolio p
           where p.id = n.portfolio_id and p.organization_id = n.organization_id
             and p.client_organization_id = n.client_organization_id))
     or (n.claim_item_id is not null and not exists (
           select 1 from public.claim_item i where i.id = n.claim_item_id and i.currency = n.currency))
     -- debtor cash lands only on an active account dedicated to client funds (R124-2, CPCE-02); own cash (5122) only
     -- on an active own account
     or (n.bank_account_id is not null and not exists (
           select 1 from public.bank_account b
           where b.id = n.bank_account_id and b.organization_id = n.organization_id and b.currency = n.currency
             and b.status = 'active'
             and b.purpose = case n.book when 'client_money_cash' then 'client_funds' when 'own_cash' then 'own' end));
  if v_bad is not null then
    raise exception 'ledger: ledger account % is not coherent (book, currency, component, tenant, item or bank account)', v_bad
      using errcode = 'LG002';
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- Entries: commission documents are corrected by a credit note, a settlement survives a returned payout, a write-off
-- is final (§5.2 « Reversal »): never reversed (LG003). Redefined from 20261109090000; one check added.
------------------------------------------------------------------------------------------

create or replace function private.ledger_entry_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad from new_rows n
  where not exists (select 1 from public.organization o where o.id = n.organization_id and o.kind = 'servicer')
     or (n.client_organization_id is not null and not exists (
           select 1 from public.organization o
           where o.id = n.client_organization_id and o.servicer_organization_id = n.organization_id))
     or (n.portfolio_id is not null and not exists (
           select 1 from public.portfolio p
           where p.id = n.portfolio_id and p.organization_id = n.organization_id
             and p.client_organization_id = n.client_organization_id))
     or (n.account_id is not null and not exists (
           select 1 from public.account a
           where a.id = n.account_id and a.portfolio_id = n.portfolio_id and a.organization_id = n.organization_id))
     or (n.payment_id is not null and not exists (
           select 1 from public.payment p where p.id = n.payment_id and p.organization_id = n.organization_id));
  if v_bad is not null then
    raise exception 'ledger: entry % is outside its tenant (organization, client, portfolio, account, payment)', v_bad
      using errcode = 'LG002';
  end if;
  -- One keyed lookup per reversal (the reversed entry's type).
  select min(n.id::text) into v_bad from new_rows n
  where n.reverses_entry_id is not null
    and (select t.entry_type from public.ledger_entry t where t.id = n.reverses_entry_id)
        in ('commission_invoice', 'commission_credit_note', 'client_settlement', 'advance_write_off');
  if v_bad is not null then
    raise exception 'ledger: entry % reverses a commission document, a settlement or a write-off (never reversed: issue a credit note)',
      v_bad using errcode = 'LG003';
  end if;
  -- A reversal keeps the reversed entry's scope and payment; a cash_in is never reversed (a wrong
  -- statement line is corrected by a payment-tagged cash_out).
  select min(n.id::text) into v_bad from new_rows n
  left join public.ledger_entry t on t.id = n.reverses_entry_id
  where n.reverses_entry_id is not null
    and (t.id is null or t.reverses_entry_id is not null
         or t.entry_type = 'cash_in'
         or t.organization_id <> n.organization_id
         or t.client_organization_id is distinct from n.client_organization_id
         or t.portfolio_id is distinct from n.portfolio_id
         or t.account_id is distinct from n.account_id
         or t.payment_id is distinct from n.payment_id
         or t.line_count <> n.line_count
         or n.effective_date < t.effective_date);
  if v_bad is not null then
    raise exception 'ledger: reversal % does not match the entry it reverses', v_bad using errcode = 'LG003';
  end if;
  return null;
end;
$$;

------------------------------------------------------------------------------------------
-- Commit-time check per entry (redefined from 20261109090000): the M2a and M2b checks, with I2 replaced by I2′ (each
-- fund closed per currency) and I12 (the 4679 / 4689 mirror), and the shapes of the thirteen M2c types (I3′). Runs once
-- per entry at commit, often right after a bulk insert no ANALYZE has seen: key lookups only (the postings of the entry
-- by its key, each posting's account by its key, kept lateral), whatever the statistics say.
------------------------------------------------------------------------------------------

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
      -- +5122[own] P / −4111[c] / −4112[c]; VAT pair
      when 'client_payment_own' then f.n_own = 1 and f.d_own = 1
        and f.n_com <= 1 and f.d_com = 0 and f.n_adv <= 1 and f.d_adv = 0 and f.n_com + f.n_adv >= 1
        and f.n_vatp = f.n_vatc and f.n_vatp <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = 0 and f.s_vat = 0
        and f.n = 1 + f.n_com + f.n_adv + f.n_vatp + f.n_vatc
      -- +5120[b] P / −4679 P ‖ +4689 P / −4111[c] / −4112[c]; VAT pair
      when 'client_payment_dedicated' then f.n_cash = 1 and f.d_cash = 1 and f.n_dts = 1 and f.d_dts = 0
        and f.n_dfc = 1 and f.d_dfc = 1
        and f.n_com <= 1 and f.d_com = 0 and f.n_adv <= 1 and f.d_adv = 0 and f.n_com + f.n_adv >= 1
        and f.n_vatp = f.n_vatc and f.n_vatp <= 1 and f.d_vatp = f.n_vatp and f.d_vatc = 0 and f.s_vat = 0
        and f.n = 3 + f.n_com + f.n_adv + f.n_vatp + f.n_vatc
      -- +4111[c] R / −5122[own] R
      when 'client_refund_own' then f.n = 2 and f.n_com = 1 and f.d_com = 1 and f.n_own = 1 and f.d_own = 0
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
-- Write path (redefined from 20261109090000).
--   * ledger_post posts corrections of claims only: every payment and fund entry goes through ledger_post_set;
--   * ledger_reverse takes the remit lock after the allocation lock when the entry moves 4679;
--   * ledger_post_set accepts the thirteen M2c types (scope from the lines: the client of a client book, the bank
--     account of 5120 and 5122 lines, each on an active account of its purpose), fails fast on I2′ and I12, and takes
--     the allocation lock for every entry with a 4670 line, then the remit lock for every entry with a 4679 line.
------------------------------------------------------------------------------------------

create or replace function private.ledger_post(
  p_organization_id uuid,
  p_entry_type text,
  p_effective_date date,
  p_idempotency_key text,
  p_lines jsonb,
  p_meta jsonb default '{}'
)
returns table (entry_id uuid, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_type public.ledger_entry_type;
  v_account public.account;
  v_account_id uuid := nullif(p_meta ->> 'account_id', '')::uuid;
  v_reason text := nullif(btrim(p_meta ->> 'reason'), '');
  v_client uuid;
  v_owner uuid;
  v_n integer;
  v_has_claim boolean;
  v_bad text;
  v_hash text;
  v_id uuid;
  v_existing_hash text;
begin
  select * into v_type from public.ledger_entry_type where code = p_entry_type;
  -- Only corrections of claims (adjustment): payment and fund entries go through private.ledger_post_set (M2b, M2c).
  if not found or p_entry_type <> 'adjustment' then
    raise exception 'ledger: entry type % cannot be posted here', p_entry_type using errcode = 'LG006';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception 'ledger: lines must be an array' using errcode = 'LG006';
  end if;
  v_n := jsonb_array_length(p_lines);
  if v_n < 2 or v_n > 100000 then
    raise exception 'ledger: an entry has 2 to 100000 lines (got %)', v_n using errcode = 'LG006';
  end if;
  if p_effective_date is null or p_effective_date > private.paris_today() then
    raise exception 'ledger: effective date % is missing or in the future', p_effective_date using errcode = 'LG006';
  end if;
  if v_type.requires_reason and v_reason is null then
    raise exception 'ledger: a % needs a reason', p_entry_type using errcode = 'LG006';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_lines) l
    where jsonb_typeof(l) <> 'object'
       or jsonb_typeof(l -> 'amount_minor') is distinct from 'number'
       or (l ->> 'amount_minor') !~ '^-?[0-9]{1,16}$'
       or (l ->> 'amount_minor')::bigint = 0
       or coalesce(l ->> 'currency', '') !~ '^[A-Z]{3}$'
       or (l ->> 'book') is null
  ) then
    raise exception 'ledger: every line needs a book, a non-zero integer amount_minor and a currency'
      using errcode = 'LG006';
  end if;

  -- Lines, parsed once. Never reuse a relation the caller created under this name (it could carry
  -- triggers that would run with the definer's rights): drop it and create our own.
  drop table if exists pg_temp._ledger_lines;
  create temp table _ledger_lines (
    line_no integer, book text, amount_minor bigint, currency char(3), claim_item_id uuid,
    component text, client_organization_id uuid, owner_organization_id uuid, portfolio_id uuid,
    ledger_account_id uuid) on commit drop;
  insert into pg_temp._ledger_lines (line_no, book, amount_minor, currency, claim_item_id, component, client_organization_id)
  select ord::integer, l ->> 'book', (l ->> 'amount_minor')::bigint, l ->> 'currency',
         nullif(l ->> 'claim_item_id', '')::uuid, nullif(l ->> 'component', ''),
         nullif(l ->> 'client_organization_id', '')::uuid
  from jsonb_array_elements(p_lines) with ordinality as t (l, ord);

  if exists (select 1 from pg_temp._ledger_lines l where not exists (select 1 from public.ledger_book b where b.code = l.book)
                                                 or not (l.book = any (v_type.allowed_books))) then
    raise exception 'ledger: a line uses a book not allowed for a % entry', p_entry_type using errcode = 'LG002';
  end if;

  v_has_claim := exists (select 1 from pg_temp._ledger_lines where book in ('debtor_receivable', 'owner_claim'));
  if v_has_claim then
    if v_account_id is null then
      raise exception 'ledger: claim lines need meta.account_id' using errcode = 'LG006';
    end if;
    select * into v_account from public.account where id = v_account_id;
    if not found or v_account.organization_id <> p_organization_id then
      raise exception 'ledger: account % is not in this organization', v_account_id using errcode = 'LG002';
    end if;
    if v_account.status = 'staged' then
      raise exception 'ledger: account % is not confirmed yet (staged)', v_account_id using errcode = 'LG006';
    end if;
    if p_effective_date < (select min(valid_from) from public.claim_ownership_period where account_id = v_account_id) then
      raise exception 'ledger: % is before the servicing of account % started', p_effective_date, v_account_id
        using errcode = 'LG006';
    end if;
    select o.owner_organization_id into v_owner from public.claim_ownership_period o
    where o.account_id = v_account_id and o.valid_from <= p_effective_date
      and (o.valid_to is null or o.valid_to > p_effective_date);
    if v_owner is null then
      raise exception 'ledger: no owner of account % on %', v_account_id, p_effective_date using errcode = 'LG006';
    end if;
    v_client := v_account.client_organization_id;
    if exists (
      select 1 from pg_temp._ledger_lines l
      where (l.book = 'debtor_receivable' and (l.claim_item_id is null or l.component is null
              or l.currency <> v_account.currency
              or not exists (select 1 from public.claim_item i where i.id = l.claim_item_id and i.account_id = v_account_id)))
         or (l.book = 'owner_claim' and (l.component is null or l.claim_item_id is not null or l.currency <> v_account.currency))
    ) then
      raise exception 'ledger: claim lines must name an item of account %, a component and its currency', v_account_id
        using errcode = 'LG002';
    end if;
  elsif v_account_id is not null then
    raise exception 'ledger: meta.account_id given without claim lines' using errcode = 'LG006';
  end if;

  -- Client lines: the client must be a client of this servicer; one client per entry.
  if exists (
    select 1 from pg_temp._ledger_lines l
    where l.book not in ('debtor_receivable', 'owner_claim')
      and (l.claim_item_id is not null or l.component is not null
           or (l.client_organization_id is null and l.book <> 'unallocated_payment')
           or (l.client_organization_id is not null and not exists (
                 select 1 from public.organization o
                 where o.id = l.client_organization_id and o.servicer_organization_id = p_organization_id)))
  ) then
    raise exception 'ledger: client lines must name a client of this servicer' using errcode = 'LG002';
  end if;
  if (select count(distinct x) from (
        select v_client as x where v_client is not null
        union all select client_organization_id from pg_temp._ledger_lines where client_organization_id is not null) c) > 1 then
    raise exception 'ledger: an entry concerns one client at most' using errcode = 'LG002';
  end if;
  v_client := coalesce(v_client, (select min(client_organization_id::text)::uuid from pg_temp._ledger_lines));

  -- Fail fast (the deferred check is the backstop).
  select currency into v_bad from pg_temp._ledger_lines group by currency having sum(amount_minor) <> 0 limit 1;
  if found then
    raise exception 'ledger: entry is not balanced in %', v_bad using errcode = 'LG001';
  end if;
  select component || ' ' || currency into v_bad from pg_temp._ledger_lines
  where book in ('debtor_receivable', 'owner_claim') group by component, currency having sum(amount_minor) <> 0 limit 1;
  if found then
    raise exception 'ledger: entry breaks the receivable/owner-claim mirror (%)', v_bad using errcode = 'LG001';
  end if;

  -- A correction of a receivable, up or down, waits for running allocations and nettings of this
  -- servicer (§5.2): lowering one can overdraw an allocated item, raising one can push a netted
  -- credit item above zero (I6), and two uncommitted checks would miss each other.
  if exists (select 1 from pg_temp._ledger_lines where book = 'debtor_receivable') then
    perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  end if;

  -- Get or create the ledger accounts.
  update pg_temp._ledger_lines set client_organization_id = v_client where book in ('debtor_receivable', 'owner_claim');
  update pg_temp._ledger_lines set portfolio_id = v_account.portfolio_id where book in ('debtor_receivable', 'owner_claim');
  update pg_temp._ledger_lines set owner_organization_id = v_owner where book = 'owner_claim';
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, portfolio_id,
                                     account_id, claim_item_id, component)
  select distinct p_organization_id, 'debtor_receivable', l.currency, l.client_organization_id, l.portfolio_id,
         v_account_id, l.claim_item_id, l.component
  from pg_temp._ledger_lines l where l.book = 'debtor_receivable'
  on conflict (claim_item_id, component) do nothing;
  insert into public.ledger_account (organization_id, book, currency, client_organization_id, owner_organization_id,
                                     portfolio_id, component)
  select distinct p_organization_id, l.book, l.currency, l.client_organization_id, l.owner_organization_id,
         l.portfolio_id, l.component
  from pg_temp._ledger_lines l where l.book <> 'debtor_receivable'
  on conflict (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component,
               bank_account_id)
    where claim_item_id is null do nothing;
  update pg_temp._ledger_lines l set ledger_account_id = la.id
  from public.ledger_account la
  where (l.book = 'debtor_receivable' and la.claim_item_id = l.claim_item_id and la.component = l.component)
     or (l.book <> 'debtor_receivable' and la.claim_item_id is null and la.organization_id = p_organization_id
         and la.book = l.book and la.currency = l.currency
         and la.client_organization_id is not distinct from l.client_organization_id
         and la.owner_organization_id is not distinct from l.owner_organization_id
         and la.portfolio_id is not distinct from l.portfolio_id
         and la.component is not distinct from l.component
         and la.bank_account_id is null);

  -- Canonical request hash: line order does not matter.
  v_hash := encode(sha256(convert_to(jsonb_build_object(
    'type', p_entry_type,
    'effective_date', p_effective_date,
    'account_id', v_account_id,
    'source', jsonb_build_array(p_meta ->> 'source_type', p_meta ->> 'source_id'),
    'reason', v_reason,
    'engine', jsonb_build_array(p_meta ->> 'engine_version', p_meta ->> 'rule_pack_version_id', p_meta ->> 'inputs_hash'),
    'lines', (select jsonb_agg(jsonb_build_array(ledger_account_id, currency, amount_minor)
                               order by ledger_account_id, amount_minor) from pg_temp._ledger_lines)
  )::text, 'UTF8')), 'hex');

  insert into public.ledger_entry (organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                   effective_date, line_count, idempotency_key, request_hash, source_type, source_id,
                                   reason, engine_version, rule_pack_version_id, inputs_hash)
  values (p_organization_id, v_client, case when v_has_claim then v_account.portfolio_id end, v_account_id,
          p_entry_type, p_effective_date, v_n, p_idempotency_key, v_hash, p_meta ->> 'source_type',
          p_meta ->> 'source_id', v_reason, p_meta ->> 'engine_version',
          nullif(p_meta ->> 'rule_pack_version_id', '')::uuid, p_meta ->> 'inputs_hash')
  on conflict (organization_id, idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then
    select e.id, e.request_hash into v_id, v_existing_hash from public.ledger_entry e
    where e.organization_id = p_organization_id and e.idempotency_key = p_idempotency_key;
    if v_existing_hash <> v_hash then
      raise exception 'ledger: idempotency key % was used for a different request', p_idempotency_key
        using errcode = 'LG004';
    end if;
    return query select v_id, false;
    return;
  end if;

  insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
  select v_id, line_no, ledger_account_id, amount_minor, currency, p_effective_date from pg_temp._ledger_lines;
  return query select v_id, true;
end;
$$;

create or replace function private.ledger_reverse(
  p_entry_id uuid,
  p_idempotency_key text,
  p_reason text,
  p_effective_date date default null
)
returns table (entry_id uuid, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_target public.ledger_entry;
  v_existing public.ledger_entry;
  v_date date;
  v_id uuid;
begin
  select * into v_target from public.ledger_entry where id = p_entry_id;
  if not found then
    raise exception 'ledger: entry % does not exist', p_entry_id using errcode = 'LG003';
  end if;
  v_date := coalesce(p_effective_date, v_target.effective_date);
  select * into v_existing from public.ledger_entry
  where organization_id = v_target.organization_id and idempotency_key = p_idempotency_key;
  if found then
    -- A replay must be the same request: same target, date and reason.
    if v_existing.reverses_entry_id = p_entry_id and v_existing.effective_date = v_date
       and v_existing.reason = btrim(p_reason) then
      return query select v_existing.id, false;
      return;
    end if;
    raise exception 'ledger: idempotency key % was used for a different request', p_idempotency_key
      using errcode = 'LG004';
  end if;
  if v_target.reverses_entry_id is not null then
    raise exception 'ledger: entry % is a reversal; post a new entry instead', p_entry_id using errcode = 'LG003';
  end if;
  if v_target.entry_type = 'cash_in' then
    raise exception 'ledger: entry % is a cash_in; correct a statement line with a payment-tagged cash_out', p_entry_id
      using errcode = 'LG003';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'ledger: a reversal needs a reason' using errcode = 'LG006';
  end if;
  if v_date < v_target.effective_date then
    raise exception 'ledger: a reversal cannot be dated before the entry it reverses' using errcode = 'LG003';
  end if;
  if v_date > private.paris_today() then
    raise exception 'ledger: effective date % is in the future', v_date using errcode = 'LG006';
  end if;
  -- Cash lines go back to the same bank accounts: they must still be active (a closed account
  -- holds no money). Bank rows first, then the advisory lock, as in ledger_post_set.
  perform 1 from public.bank_account b
  where b.id in (select la.bank_account_id from public.ledger_posting p
                 join public.ledger_account la on la.id = p.ledger_account_id
                 where p.entry_id = p_entry_id and la.bank_account_id is not null)
  order by b.id for share;
  if exists (select 1 from public.ledger_posting p
             join public.ledger_account la on la.id = p.ledger_account_id
             join public.bank_account b on b.id = la.bank_account_id
             where p.entry_id = p_entry_id and b.status <> 'active') then
    raise exception 'ledger: entry % moved money on a bank account that is now closed', p_entry_id using errcode = 'LG002';
  end if;
  -- A reversal can lower a receivable (reversing a debit): serialised with allocations (§5.2).
  perform pg_advisory_xact_lock(hashtext('payments:' || v_target.organization_id::text));
  -- Then the remit lock (M2c, §5.5) when the entry moves 4679: every writer of 4679 takes it, after the allocation lock.
  if exists (select 1 from public.ledger_posting p
             where p.entry_id = p_entry_id
               and (select la.book from public.ledger_account la where la.id = p.ledger_account_id) = 'due_to_servicer') then
    perform pg_advisory_xact_lock(hashtext('remit:' || v_target.organization_id::text));
  end if;
  begin
    insert into public.ledger_entry (organization_id, client_organization_id, portfolio_id, account_id, entry_type,
                                     effective_date, line_count, idempotency_key, request_hash, reverses_entry_id,
                                     boarding_batch_id, payment_id, source_type, source_id, reason)
    values (v_target.organization_id, v_target.client_organization_id, v_target.portfolio_id, v_target.account_id,
            'reversal', v_date, v_target.line_count, p_idempotency_key,
            encode(sha256(convert_to('reversal|' || p_entry_id || '|' || v_date, 'UTF8')), 'hex'),
            p_entry_id, v_target.boarding_batch_id, v_target.payment_id, 'ledger_entry', p_entry_id::text, btrim(p_reason))
    returning id into v_id;
  exception when unique_violation then
    -- A concurrent call won the race: a replay of the same request gets its reversal back.
    select * into v_existing from public.ledger_entry
    where organization_id = v_target.organization_id and idempotency_key = p_idempotency_key;
    if found and v_existing.reverses_entry_id = p_entry_id and v_existing.effective_date = v_date
       and v_existing.reason = btrim(p_reason) then
      return query select v_existing.id, false;
      return;
    elsif found then
      raise exception 'ledger: idempotency key % was used for a different request', p_idempotency_key
        using errcode = 'LG004';
    end if;
    raise exception 'ledger: entry % is already reversed', p_entry_id using errcode = 'LG003';
  end;
  insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency, effective_date)
  select v_id, line_no, ledger_account_id, -amount_minor, currency, v_date
  from public.ledger_posting where entry_id = p_entry_id;
  return query select v_id, true;
end;
$$;

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
         case when l.book in ('debtor_receivable', 'owner_claim', 'client_payable', 'commission_receivable', 'client_advance_receivable', 'servicer_revenue')
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
     -- with a client line (4670, 4111, 4112, 7060); never for the others
     or (e.given_client is not null and e.account_id is null
         and not exists (select 1 from pg_temp._lps_l l where l.entry_no = e.entry_no
                           and l.book in ('client_payable', 'commission_receivable', 'client_advance_receivable', 'servicer_revenue')))
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
                   and l.book in ('client_payable', 'commission_receivable', 'client_advance_receivable', 'servicer_revenue'))
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
                     'vat_collected', 'vat_pending', 'servicer_revenue', 'bank_fees', 'servicer_losses')
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

------------------------------------------------------------------------------------------
-- Confirmation issues the references (redefined: one line added)
------------------------------------------------------------------------------------------

------------------------------------------------------------------------------------------
-- Per-client running balance of 4670 and the pending queue of remittance items (§5.4 I13, §5.5, §9.1)
------------------------------------------------------------------------------------------

-- What each client is owed per currency (Σ of its 4670 postings, all dates): kept by the ALWAYS statement trigger
-- below, checked at commit (never in debit: I13, LG008). One row per (client, currency).
create table private.client_payable_balance (
  organization_id uuid not null references public.organization (id),
  client_organization_id uuid not null references public.organization (id),
  currency char(3) not null references public.currency (code),
  balance_minor bigint not null,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (client_organization_id, currency)
);
comment on table private.client_payable_balance is
  'Running balance of 4670 per (client, currency), kept by a trigger on the postings; never in debit at commit (LG008).';

-- The remittance items not yet in a run (§9.1): every entry that moves 4670 and is an item — an allocation, a forward
-- or their reversal, an advance or its reversal, the reversal of a remittance (a payout that came back), an unplanned
-- payout (inserted by the debit job, M2c-6). Settlements and planned remittances are not items. amount_minor: what
-- the entry adds to what the client is owed (−Σ of its 4670 postings). A run reserves its items (draft_run_id, M2c-4
-- adds the foreign key) and deletes them when it freezes its lines: an item is in the queue or in exactly one live line.
create table private.remittance_pending (
  ledger_entry_id uuid primary key,
  organization_id uuid not null,
  client_organization_id uuid not null,
  currency char(3) not null,
  kind text not null check (kind in ('allocation', 'allocation_reversal', 'forward', 'forward_reversal', 'client_advance',
                                     'client_advance_reversal', 'payout_returned', 'unplanned_payout')),
  amount_minor bigint not null check (amount_minor <> 0),
  posted_at timestamptz not null,
  draft_run_id uuid
);
create index remittance_pending_client_idx on private.remittance_pending
  (organization_id, client_organization_id, currency, posted_at);
comment on table private.remittance_pending is
  'Remittance items waiting for a run (fed by the 4670 posting trigger, read under the allocation lock).';

-- The trigger: one pass over the statement's new postings against the few 4670 ledger accounts (a hash join: nested
-- loops off, the accounts read through their partial index, never the whole table), whatever the statistics. The item
-- kind and the time of each entry are read by key (scalar subqueries, one per entry). Writers of 4670 hold the
-- allocation lock (ledger_post_set, ledger_reverse), so the queue is read under that lock as committed.
create or replace function private.ledger_posting_client_payable()
returns trigger
language plpgsql
security definer
set search_path = ''
set enable_nestloop = off
set enable_mergejoin = off
set enable_seqscan = off
as $$
begin
  -- One statement (no working table: this fires for every posting statement, reversals in loops included).
  with cpb as materialized (
    select n.entry_id, la.organization_id, la.client_organization_id, la.currency, sum(n.amount_minor) as amount_minor
    from new_rows n
    join (select l.id, l.organization_id, l.client_organization_id, l.currency
          from public.ledger_account l where l.book = 'client_payable') la on la.id = n.ledger_account_id
    group by n.entry_id, la.organization_id, la.client_organization_id, la.currency
  ),
  bal as (
    insert into private.client_payable_balance as b (organization_id, client_organization_id, currency, balance_minor)
    select x.organization_id, x.client_organization_id, x.currency, sum(x.amount_minor)
    from cpb x
    group by x.organization_id, x.client_organization_id, x.currency
    on conflict (client_organization_id, currency)
      do update set balance_minor = b.balance_minor + excluded.balance_minor, updated_at = clock_timestamp()
    returning 1
  )
  insert into private.remittance_pending as q (ledger_entry_id, organization_id, client_organization_id, currency, kind,
                                              amount_minor, posted_at)
  select y.entry_id, y.organization_id, y.client_organization_id, y.currency, y.kind, -y.amount_minor, y.posted_at
  from (select x.*,
               (select case e.entry_type
                         when 'allocation' then 'allocation'
                         when 'forward' then 'forward'
                         when 'client_advance' then 'client_advance'
                         when 'reversal' then (select case t.entry_type
                                                        when 'allocation' then 'allocation_reversal'
                                                        when 'forward' then 'forward_reversal'
                                                        when 'client_advance' then 'client_advance_reversal'
                                                        when 'remittance' then 'payout_returned' end
                                               from public.ledger_entry t where t.id = e.reverses_entry_id)
                       end
                from public.ledger_entry e where e.id = x.entry_id) as kind,
               (select e.posted_at from public.ledger_entry e where e.id = x.entry_id) as posted_at
        from cpb x
        where x.amount_minor <> 0) y
  where y.kind is not null   -- (the balance upsert in WITH always runs to completion)
  on conflict (ledger_entry_id) do update set amount_minor = q.amount_minor + excluded.amount_minor;
  return null;
end;
$$;
create trigger ledger_posting_client_payable after insert on public.ledger_posting
  referencing new table as new_rows for each statement execute function private.ledger_posting_client_payable();
alter table public.ledger_posting enable always trigger ledger_posting_client_payable;

-- I13 at commit: a client's 4670 is never in debit (no client's money ever covers another client's debit or the
-- servicer's: C. pén. 314-1, C. civ. 1993). Forgetting the cover of a remitted reversal fails here (M2c §13 #2). One
-- deferred event per balance row written IN DEBIT (WHEN: a balance in debit at commit was written by an update leaving
-- it in debit, which queued a check; review fix: a loop of single-entry postings, e.g. a chunk's return reversals,
-- queued one check per update, each walking the row's versions: quadratic); the current balance is read by its key.
create or replace function private.client_payable_check()
returns trigger
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare v bigint;
begin
  select b.balance_minor into v from private.client_payable_balance b
  where b.client_organization_id = new.client_organization_id and b.currency = new.currency;
  if v > 0 then
    raise exception 'ledger: client % would be in debit on 4670 by % % (client money short: cover it first)',
      new.client_organization_id, v, new.currency using errcode = 'LG008';
  end if;
  return null;
end;
$$;
create constraint trigger client_payable_in_credit after insert or update on private.client_payable_balance
  deferrable initially deferred for each row when (new.balance_minor > 0) execute function private.client_payable_check();
alter table private.client_payable_balance enable always trigger client_payable_in_credit;

-- The ledger's commit-time checks of what a function posted, now (LG001 … LG008 raised inside the caller's call).
create or replace function private.ledger_check_now()
returns void
language plpgsql
set search_path = ''
as $$
begin
  set constraints public.ledger_entry_balanced, private.client_payable_in_credit immediate;
  set constraints public.ledger_entry_balanced, private.client_payable_in_credit deferred;
end;
$$;

-- Back-fill (none in production): the balances and the queue from the 4670 postings already there.
insert into private.client_payable_balance (organization_id, client_organization_id, currency, balance_minor)
select la.organization_id, la.client_organization_id, la.currency, sum(p.amount_minor)
from public.ledger_account la join public.ledger_posting p on p.ledger_account_id = la.id
where la.book = 'client_payable'
group by la.organization_id, la.client_organization_id, la.currency;
insert into private.remittance_pending (ledger_entry_id, organization_id, client_organization_id, currency, kind,
                                        amount_minor, posted_at)
select x.id, x.organization_id, x.client_organization_id, x.currency, x.kind, x.owed, x.posted_at
from (select e.id, la.organization_id, la.client_organization_id, la.currency, e.posted_at, -sum(p.amount_minor) as owed,
             case e.entry_type when 'allocation' then 'allocation' when 'forward' then 'forward'
                               when 'reversal' then case t.entry_type when 'allocation' then 'allocation_reversal'
                                                                      when 'forward' then 'forward_reversal' end end as kind
      from public.ledger_entry e
      left join public.ledger_entry t on t.id = e.reverses_entry_id
      join public.ledger_posting p on p.entry_id = e.id
      join public.ledger_account la on la.id = p.ledger_account_id and la.book = 'client_payable'
      group by e.id, la.organization_id, la.client_organization_id, la.currency, e.posted_at, e.entry_type, t.entry_type) x
where x.kind is not null and x.owed <> 0;

------------------------------------------------------------------------------------------
-- Read access (§6.2, redefined from 20261109090000): every book without a portfolio is named. Client money (5120,
-- 4710, 4670), the servicer's money on the dedicated account (4679) and the servicer's fund (4689, 5122, 4111, 4112,
-- 44571, 44574, 7060, 6270, 6780): admins and ops managers at aal2; clients their own 4670 only, and only members with
-- access to the whole client (what a client is owed and its remittances cover all its portfolios: a member restricted
-- to some portfolios reads none of it, OQ-48 default; review fix). This closes the staff_org_ids / client_visible path
-- (collectors and clients no longer read 7060; compliance critique C6). A book added later without a portfolio is read
-- by nobody until it is named here.
------------------------------------------------------------------------------------------

-- Client organizations where the caller is a member with access to the whole client (§6.2): no portfolio restriction
-- (private.can_read_portfolio restricts a user with any portfolio_access row to those portfolios).
create or replace function private.client_whole_org_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.organization_id), '{}')
  from public.membership m
  join public.organization o on o.id = m.organization_id and o.kind <> 'servicer'
  where m.user_id = (select auth.uid())
    and not exists (select 1 from public.portfolio_access a where a.user_id = (select auth.uid()));
$$;
revoke execute on function private.client_whole_org_ids() from public, anon;
grant execute on function private.client_whole_org_ids() to authenticated;

drop policy ledger_account_read on public.ledger_account;
create policy ledger_account_read on public.ledger_account for select to authenticated using (
  portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])
  or (portfolio_id is null
      and book in ('client_money_cash', 'unallocated_payment', 'client_payable', 'due_to_servicer',
                   'due_from_client_funds', 'own_cash', 'commission_receivable', 'client_advance_receivable',
                   'vat_collected', 'vat_pending', 'servicer_revenue', 'bank_fees', 'servicer_losses')
      and organization_id = any ((select private.money_staff_org_ids())::uuid[]))
  or (portfolio_id is null and book = 'client_payable'
      and client_organization_id = any ((select private.client_whole_org_ids())::uuid[])));

-- Entries without a portfolio: money staff; clients (whole-client members) only their own entries of the types that
-- move what they are owed (forward, reversal, remittance, client_settlement, client_advance). Commission documents are
-- read as invoices (M2c-4/5), never as servicer-fund entries.
drop policy ledger_entry_read on public.ledger_entry;
create policy ledger_entry_read on public.ledger_entry for select to authenticated using (
  portfolio_id = any ((select private.readable_portfolio_ids())::uuid[])
  or (portfolio_id is null and organization_id = any ((select private.money_staff_org_ids())::uuid[]))
  or (portfolio_id is null and client_organization_id = any ((select private.client_whole_org_ids())::uuid[])
      and entry_type in ('forward', 'reversal', 'remittance', 'client_settlement', 'client_advance')));

-- The same rule for a balance asked by id.
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
                               'vat_collected', 'vat_pending', 'servicer_revenue', 'bank_fees', 'servicer_losses')
               and la.organization_id = any (private.money_staff_org_ids()))
           or (la.portfolio_id is null and la.book = 'client_payable'
               and la.client_organization_id = any (private.client_whole_org_ids())))
  ) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  return private.ledger_balance(p_ledger_account_id, coalesce(p_as_of, private.paris_today()), p_known_at);
end;
$$;

------------------------------------------------------------------------------------------
-- Transfers we order (§6.1 bank_transfer). M2c-1 orders only top-ups of a dedicated account from the own account, by
-- hand (ops type our TOP id as the end-to-end reference in their bank; the automatic top-up file is M2c-7). Payouts,
-- sweeps, refunds in files and the transfer files arrive with M2c-6, which adds their columns and foreign keys.
------------------------------------------------------------------------------------------

create table public.bank_transfer (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organization (id),
  kind text not null check (kind in ('payout', 'sweep', 'top_up', 'refund')),
  debtor_bank_account_id uuid not null,            -- the account debited (a top-up: the own account)
  creditor_bank_account_id uuid,                   -- our account credited (a top-up: the dedicated account)
  currency char(3) not null,
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  payee_name text not null check (length(btrim(payee_name)) between 1 and 70),
  payee_iban text not null check (private.iban_valid(payee_iban)),
  payee_bic text check (payee_bic ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'),
  end_to_end_id text not null unique check (end_to_end_id ~ '^(RMT|SWP|TOP|RFD)[0-9A-F]{12}$'),
  remittance_info text check (length(remittance_info) between 1 and 140),
  requested_execution_date date not null,
  status text not null default 'ordered' check (status in ('ordered', 'in_file', 'booked', 'returned', 'cancelled')),
  entry_id uuid unique references public.ledger_entry (id),          -- the entry booked from the bank's line
  return_entry_id uuid unique references public.ledger_entry (id),
  reason text check (length(btrim(reason)) between 1 and 2000),     -- ops' motif (staff only)
  ordered_by uuid,
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancel_reason text check (length(btrim(cancel_reason)) between 1 and 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bank_transfer_debtor_fk foreign key (debtor_bank_account_id, organization_id, currency)
    references public.bank_account (id, organization_id, currency),
  constraint bank_transfer_creditor_fk foreign key (creditor_bank_account_id, organization_id, currency)
    references public.bank_account (id, organization_id, currency),
  constraint bank_transfer_prefix check (left(end_to_end_id, 3) = case kind when 'payout' then 'RMT' when 'sweep' then 'SWP'
                                                                            when 'top_up' then 'TOP' else 'RFD' end),
  constraint bank_transfer_between_ours check ((kind in ('sweep', 'top_up')) = (creditor_bank_account_id is not null)),
  constraint bank_transfer_booked check ((status in ('booked', 'returned')) = (entry_id is not null)),
  constraint bank_transfer_returned check ((status = 'returned') = (return_entry_id is not null)),
  constraint bank_transfer_cancelled check ((status = 'cancelled') = (cancelled_at is not null and cancel_reason is not null))
);
create index bank_transfer_org_idx on public.bank_transfer (organization_id, status, created_at desc);
create index bank_transfer_creditor_idx on public.bank_transfer (creditor_bank_account_id, amount_minor)
  where creditor_bank_account_id is not null and status = 'ordered';
create index bank_transfer_debtor_idx on public.bank_transfer (debtor_bank_account_id) where status in ('ordered', 'in_file');
comment on table public.bank_transfer is
  'Transfers the servicer orders (our end-to-end id RMT/SWP/TOP/RFD + 12 hex). M2c-1: top-ups of a dedicated account.';

-- What was ordered never changes; the status moves forward only (ordered → in_file → booked → returned; ordered or
-- in_file → cancelled). A top-up goes from an active own account to an active client_funds account of the servicer.
create or replace function private.bank_transfer_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'ordered' then
      raise exception 'bank transfer: starts ordered' using errcode = 'check_violation';
    end if;
    if new.kind = 'top_up' and not (
         exists (select 1 from public.bank_account b where b.id = new.debtor_bank_account_id and b.purpose = 'own'
                   and b.status = 'active')
         and exists (select 1 from public.bank_account b where b.id = new.creditor_bank_account_id
                       and b.purpose = 'client_funds' and b.status = 'active'
                       and b.iban = new.payee_iban)) then
      raise exception 'bank transfer: a top-up goes from an active own account to an active client_funds account'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if (new.id, new.organization_id, new.kind, new.debtor_bank_account_id, new.creditor_bank_account_id, new.currency,
      new.amount_minor, new.payee_name, new.payee_iban, new.payee_bic, new.end_to_end_id, new.remittance_info,
      new.requested_execution_date, new.reason, new.ordered_by, new.created_at)
     is distinct from
     (old.id, old.organization_id, old.kind, old.debtor_bank_account_id, old.creditor_bank_account_id, old.currency,
      old.amount_minor, old.payee_name, old.payee_iban, old.payee_bic, old.end_to_end_id, old.remittance_info,
      old.requested_execution_date, old.reason, old.ordered_by, old.created_at)
     or (old.entry_id is not null and new.entry_id is distinct from old.entry_id)
     or (old.return_entry_id is not null and new.return_entry_id is distinct from old.return_entry_id)
     or (new.status <> old.status and not (
           (old.status = 'ordered' and new.status in ('in_file', 'booked', 'cancelled'))
           or (old.status = 'in_file' and new.status in ('booked', 'cancelled'))
           or (old.status = 'booked' and new.status = 'returned'))) then
    raise exception 'bank transfer %: what was ordered never changes, and its status only moves forward', old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger bank_transfer_guard before insert or update on public.bank_transfer
  for each row execute function private.bank_transfer_guard();
alter table public.bank_transfer enable always trigger bank_transfer_guard;
create trigger bank_transfer_no_delete before delete or truncate on public.bank_transfer
  for each statement execute function private.refuse_delete();
alter table public.bank_transfer enable always trigger bank_transfer_no_delete;
create trigger bank_transfer_touch before update on public.bank_transfer
  for each row execute function private.touch_updated_at();
create trigger bank_transfer_change_log after insert or update or delete on public.bank_transfer
  for each row execute function private.log_change();

-- « Approvisionner le compte dédié » (§13 #4; founder #7, #9): ops order a top-up from the own account; the command
-- gives our TOP id, to type as the end-to-end reference of the transfer in the bank. Nothing is booked now: the credit
-- on the dedicated account's statement is booked (servicer_top_up) by the debit job when it carries this id and this
-- amount. Admins and ops managers at aal2, idempotency key + request hash.
create or replace function public.request_top_up(p_idempotency_key text, p_own_bank_account_id uuid,
                                                 p_client_funds_bank_account_id uuid, p_amount_minor text,
                                                 p_reason text, p_requested_execution_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  o public.bank_account;
  c public.bank_account;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_date date := coalesce(p_requested_execution_date, private.paris_today());
  v_request jsonb;
  v_result jsonb;
  v_amount bigint;
  v_e2e text;
  v_id uuid;
  v_name text;
begin
  select * into o from public.bank_account where id = p_own_bank_account_id;
  if not found or not private.has_role(o.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('own_bank_account_id', p_own_bank_account_id,
                                  'client_funds_bank_account_id', p_client_funds_bank_account_id,
                                  'amount_minor', p_amount_minor, 'reason', v_reason,
                                  'requested_execution_date', p_requested_execution_date);
  v_result := private.command_replay('request_top_up', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p_amount_minor is null or p_amount_minor !~ '^[0-9]{1,16}$' or p_amount_minor::bigint <= 0 then
    raise exception 'invalid amount' using errcode = 'check_violation';
  end if;
  v_amount := p_amount_minor::bigint;
  -- Both accounts locked (in id order, like every writer) before they are checked: a concurrent close of either waits
  -- for this order (and then sees it in flight), or this order waits for the close and reads it closed (review fix:
  -- the own account was read unlocked, so a close could commit with a top-up in flight).
  perform 1 from public.bank_account b
  where b.id in (p_own_bank_account_id, p_client_funds_bank_account_id)
  order by b.id for share;
  select * into o from public.bank_account where id = p_own_bank_account_id;
  select * into c from public.bank_account where id = p_client_funds_bank_account_id;
  if not found or c.organization_id <> o.organization_id or c.purpose <> 'client_funds' or c.status <> 'active'
     or o.purpose <> 'own' or o.status <> 'active' or c.currency <> o.currency then
    raise exception 'top-up: from an active own account to an active client_funds account in the same currency'
      using errcode = 'check_violation';
  end if;
  if v_date < private.paris_today() then
    raise exception 'the requested execution date is in the past' using errcode = 'check_violation';
  end if;
  select left(btrim(legal_name), 70) into v_name from public.organization where id = o.organization_id;
  v_e2e := 'TOP' || upper(substr(md5(gen_random_uuid()::text), 1, 12));
  insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id, creditor_bank_account_id, currency,
                                    amount_minor, payee_name, payee_iban, payee_bic, end_to_end_id, remittance_info,
                                    requested_execution_date, reason, ordered_by)
  values (o.organization_id, 'top_up', o.id, c.id, c.currency, v_amount, v_name, c.iban, c.bic, v_e2e,
          'APPROVISIONNEMENT COMPTE DEDIE ' || v_e2e, v_date, v_reason, auth.uid())
  returning id into v_id;
  v_result := jsonb_build_object('transfer_id', v_id, 'end_to_end_id', v_e2e, 'amount_minor', v_amount::text,
                                 'currency', c.currency, 'payee_name', v_name, 'payee_iban', c.iban,
                                 'debtor_iban', o.iban, 'requested_execution_date', v_date);
  perform private.command_record('request_top_up', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Annuler » a top-up not booked yet (ops did not send it, or the bank refused it).
create or replace function public.cancel_top_up(p_idempotency_key text, p_transfer_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  t public.bank_transfer;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('transfer_id', p_transfer_id, 'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
begin
  select * into t from public.bank_transfer where id = p_transfer_id for update;
  if not found or t.kind <> 'top_up' or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('cancel_top_up', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if t.status <> 'ordered' then
    raise exception 'the top-up is no longer pending' using errcode = 'check_violation';
  end if;
  update public.bank_transfer set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(),
                                  cancel_reason = v_reason
  where id = t.id and status = 'ordered';
  v_result := jsonb_build_object('transfer_id', t.id, 'status', 'cancelled');
  perform private.command_record('cancel_top_up', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- Bank account commands (§16; redefined from 20261109090000). register_bank_account gains its purpose (one parameter
-- added, last, defaulted: the old signature is dropped so that one function answers). A second ACTIVE client_funds
-- account in a currency is refused (founder #14: money on a second account could never be remitted).
------------------------------------------------------------------------------------------

drop function public.register_bank_account(text, uuid, text, text, text, text, text, date);
create or replace function public.register_bank_account(
  p_idempotency_key text,
  p_organization_id uuid,
  p_label text,
  p_iban text,
  p_currency text,
  p_feed text,
  p_bic text default null,
  p_opened_on date default null,
  p_purpose text default 'client_funds'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_iban text := private.rf_normalise(coalesce(p_iban, ''));
  v_bic text := nullif(private.rf_normalise(coalesce(p_bic, '')), '');
  v_label text := btrim(coalesce(p_label, ''));
  v_opened date := coalesce(p_opened_on, private.paris_today());
  v_purpose text := coalesce(p_purpose, 'client_funds');
  v_feed text := case when coalesce(p_purpose, 'client_funds') = 'own' then null else p_feed end;
  v_request jsonb;
  v_result jsonb;
  v_id uuid;
begin
  if not private.has_role(p_organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  -- the request of a client_funds account hashes as before (keys used before M2c replay)
  v_request := jsonb_build_object('organization_id', p_organization_id, 'label', v_label, 'iban', v_iban,
                                  'currency', p_currency, 'feed', v_feed, 'bic', v_bic, 'opened_on', p_opened_on)
               || case when v_purpose = 'client_funds' then '{}'::jsonb
                       else jsonb_build_object('purpose', v_purpose) end;
  v_result := private.command_replay('register_bank_account', p_idempotency_key, v_request);
  if v_result is not null then
    return (v_result ->> 'bank_account_id')::uuid;
  end if;
  if v_purpose not in ('client_funds', 'own') then
    raise exception 'invalid purpose' using errcode = 'check_violation';
  end if;
  if v_label = '' or length(v_label) > 100 then
    raise exception 'a label is required (100 characters at most)' using errcode = 'check_violation';
  end if;
  if not private.iban_valid(v_iban) then
    raise exception 'invalid IBAN' using errcode = 'check_violation';
  end if;
  if v_bic is not null and v_bic !~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$' then
    raise exception 'invalid BIC' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.currency where code = p_currency) then
    raise exception 'unsupported currency' using errcode = 'check_violation';
  end if;
  if v_purpose = 'client_funds' and (v_feed is null or v_feed not in ('camt053', 'csv')) then
    raise exception 'invalid statement feed' using errcode = 'check_violation';
  end if;
  if v_opened > private.paris_today() then
    raise exception 'the opening date cannot be in the future' using errcode = 'check_violation';
  end if;
  -- One registration at a time per servicer: the one-account-per-currency rule sees every earlier one.
  perform pg_advisory_xact_lock(hashtext('bank_accounts:' || p_organization_id::text));
  if exists (select 1 from public.bank_account
             where organization_id = p_organization_id and iban = v_iban and currency = p_currency) then
    raise exception 'this IBAN is already registered' using errcode = 'unique_violation';
  end if;
  -- An IBAN has one purpose, in every currency (review fix): the account dedicated to the creditors' funds (R124-2
  -- al. 2) is never also recorded as the servicer's own account, nor the other way round.
  if exists (select 1 from public.bank_account
             where organization_id = p_organization_id and iban = v_iban and purpose <> v_purpose) then
    raise exception 'this IBAN is already registered for another purpose' using errcode = 'unique_violation';
  end if;
  if v_purpose = 'client_funds' and exists (
       select 1 from public.bank_account
       where organization_id = p_organization_id and purpose = 'client_funds' and currency = p_currency
         and status = 'active') then
    raise exception 'a client_funds account is already active in this currency (one per currency)'
      using errcode = 'unique_violation';
  end if;
  insert into public.bank_account (organization_id, purpose, iban, bic, currency, label, feed, opened_on, created_by)
  values (p_organization_id, v_purpose, v_iban, v_bic, p_currency, v_label, v_feed, v_opened, auth.uid())
  returning id into v_id;
  perform private.command_record('register_bank_account', p_idempotency_key, v_request,
                                 jsonb_build_object('bank_account_id', v_id));
  return v_id;
end;
$$;

-- Closing needs a zero cash balance on a client_funds account (client money never stays on a closed account); no
-- top-up in flight from or to the account (an own account named in the billing settings is refused from M2c-2).
create or replace function public.close_bank_account(p_idempotency_key text, p_bank_account_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.bank_account;
  v_request jsonb := jsonb_build_object('bank_account_id', p_bank_account_id, 'reason', btrim(coalesce(p_reason, '')));
begin
  select * into v from public.bank_account where id = p_bank_account_id for update;
  if not found or not private.has_role(v.organization_id, array['admin']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  if private.command_replay('close_bank_account', p_idempotency_key, v_request) is not null then
    return;
  end if;
  if v.status = 'closed' then
    raise exception 'the bank account is already closed' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if v.purpose = 'client_funds'
     and (select coalesce(sum(p.amount_minor), 0) from public.ledger_account la
          join public.ledger_posting p on p.ledger_account_id = la.id
          where la.bank_account_id = v.id and la.book = 'client_money_cash') <> 0 then
    raise exception 'the bank account still holds client money' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_transfer t
             where (t.debtor_bank_account_id = v.id or t.creditor_bank_account_id = v.id)
               and t.status in ('ordered', 'in_file')) then
    raise exception 'transfers from or to this bank account are in flight' using errcode = 'check_violation';
  end if;
  update public.bank_account
  set status = 'closed', closed_on = private.paris_today(), closed_reason = btrim(p_reason)
  where id = v.id;
  perform private.command_record('close_bank_account', p_idempotency_key, v_request, jsonb_build_object('closed', true));
end;
$$;

------------------------------------------------------------------------------------------
-- Statement lines: our own transfers (§6.1, §12). Python twin: collectoo_worker.payments.statement.classify (a parity
-- test compares them on random lines).
------------------------------------------------------------------------------------------

-- payment_info_id: camt.053 NtryDtls/Btch/PmtInfId, the PmtInf of our file a batch debit books (M2c-6 links a bank's
-- batch booking to a file by it). New kinds: transfer_out (debit: our RMT/SWP id, or to our own IBAN), own_transfer_in
-- (credit: our TOP id, or from a registered own IBAN), client_transfer_in (credit from a client's payout IBAN). None is
-- ever taken for a debtor payment by itself (an own credit becomes one only by ops' decision: release_own_credit).
alter table public.bank_transaction add column payment_info_id text check (length(payment_info_id) between 1 and 35),
  drop constraint bank_transaction_kind_check,
  add constraint bank_transaction_kind_check check (kind in ('debtor_credit', 'return', 'refund_out', 'psp_payout',
    'other_debit', 'batch_unsplit', 'suspected_duplicate', 'transfer_out', 'own_transfer_in', 'client_transfer_in')),
  drop constraint bank_transaction_kind,
  add constraint bank_transaction_kind check (case direction
    when 'credit' then kind in ('debtor_credit', 'return', 'psp_payout', 'batch_unsplit', 'suspected_duplicate',
                                'own_transfer_in', 'client_transfer_in')
    else kind in ('return', 'refund_out', 'other_debit', 'batch_unsplit', 'suspected_duplicate', 'transfer_out') end);
alter table private.bank_import_stage add column payment_info_id text;
-- Our transfers and credits the debit job looks at, led by the servicer.
create index bank_transaction_own_idx on public.bank_transaction (organization_id, booking_date, id)
  where kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in');
create index bank_transaction_payment_info_idx on public.bank_transaction (bank_account_id, payment_info_id)
  where payment_info_id is not null;

alter table private.bank_line_held_kind drop constraint bank_line_held_kind_kind_check,
  add constraint bank_line_held_kind_kind_check check (kind in ('debtor_credit', 'return', 'refund_out', 'other_debit',
    'batch_unsplit', 'transfer_out', 'own_transfer_in', 'client_transfer_in'));
alter table public.bank_duplicate_resolution drop constraint bank_duplicate_resolution_released_kind_check,
  add constraint bank_duplicate_resolution_released_kind_check check (released_kind in ('debtor_credit', 'return',
    'refund_out', 'other_debit', 'batch_unsplit', 'transfer_out', 'own_transfer_in', 'client_transfer_in'));

-- The IBANs of the clients' payout accounts (client_transfer_in). M2c-2 registers payout accounts and redefines this
-- function over them; until then a client's IBAN is not known, so no credit is read as the client's.
create or replace function private.registered_client_ibans(p_organization_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $$
  select '{}'::text[];
$$;

-- What the worker's parser needs to classify a statement of a bank account: the servicer's own IBANs (any status: a
-- closed own account is still ours) and its clients' payout IBANs.
create or replace function private.statement_classification_ibans(p_bank_account_id uuid)
returns table (own_ibans text[], client_ibans text[])
language sql
stable
security definer
set search_path = ''
as $$
  select array(select o.iban from public.bank_account o where o.organization_id = b.organization_id and o.purpose = 'own'
               order by o.iban),
         private.registered_client_ibans(b.organization_id)
  from public.bank_account b where b.id = p_bank_account_id;
$$;

-- The kind of a line once our own transfers are recognised, from the parser's reading (a return or our RFD refund
-- stays what it is): a credit carrying our TOP id or from one of our own IBANs is ours; one from a client's payout IBAN
-- is the client's; a debit carrying our RMT or SWP id, or to one of our own IBANs, is a transfer out. The parser's own
-- readings of these kinds are read again from the line's facts (so a stale list never decides).
create or replace function private.bank_line_refined_kind(p_kind text, p_direction text, p_end_to_end_id text,
                                                          p_counterparty_iban text, p_own_ibans text[],
                                                          p_client_ibans text[])
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
    when b.base = 'debtor_credit' and p_direction = 'credit' then
      case when coalesce(p_end_to_end_id ~ '^TOP[0-9A-F]{12}$', false)
                or coalesce(p_counterparty_iban = any (p_own_ibans), false) then 'own_transfer_in'
           when coalesce(p_counterparty_iban = any (p_client_ibans), false) then 'client_transfer_in'
           else 'debtor_credit' end
    when b.base = 'other_debit' and p_direction = 'debit' then
      case when coalesce(p_end_to_end_id ~ '^(RMT|SWP)[0-9A-F]{12}$', false)
                or coalesce(p_counterparty_iban = any (p_own_ibans), false) then 'transfer_out'
           else 'other_debit' end
    else b.base end
  from (select case p_kind when 'own_transfer_in' then 'debtor_credit' when 'client_transfer_in' then 'debtor_credit'
                           when 'transfer_out' then 'other_debit' else p_kind end as base) b;
$$;

-- The parser's reading of a line held as a duplicate (redefined from 20261110120000: the new kinds are kept too).
create or replace function private.bank_transaction_held_kind()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
begin
  insert into private.bank_line_held_kind (bank_transaction_id, kind, method)
  select n.id, s.kind, s.method
  from new_rows n
  cross join lateral (select x.kind, x.method from private.bank_import_stage x
                      where x.statement_id = n.statement_id and x.line_no = n.line_no
                      offset 0) s
  where n.kind = 'suspected_duplicate'
    and s.kind in ('debtor_credit', 'return', 'refund_out', 'other_debit', 'batch_unsplit', 'transfer_out',
                   'own_transfer_in', 'client_transfer_in')
  on conflict (bank_transaction_id) do nothing;
  return null;
end;
$$;

-- What a held line is without a recorded reading (redefined from 20261110120000): from its own facts, then our own
-- transfers recognised (a credit from our own IBAN is never released as a debtor credit: only ops' release_own_credit
-- makes it a payment).
create or replace function private.held_line_kind(p_bank_transaction_id uuid)
returns table (kind text, method text)
language sql
stable
set search_path = ''
as $$
  select coalesce(h.kind, private.bank_line_refined_kind(case
           when t.return_reason is not null or t.reversal_indicator or t.original_end_to_end_id is not null then 'return'
           when t.direction = 'credit' then 'debtor_credit'
           when t.end_to_end_id like 'RFD%' then 'refund_out'
           else 'other_debit' end, t.direction, t.end_to_end_id, t.counterparty_iban,
           array(select o.iban from public.bank_account o where o.organization_id = t.organization_id and o.purpose = 'own'),
           private.registered_client_ibans(t.organization_id))),
         coalesce(h.method, 'other')
  from public.bank_transaction t
  left join private.bank_line_held_kind h on h.bank_transaction_id = t.id
  where t.id = p_bank_transaction_id;
$$;

------------------------------------------------------------------------------------------
-- Statement import (redefined from 20261109120000): our own transfers classified (above), payment_info_id stored, their
-- counts in the result. Nothing else changes.
------------------------------------------------------------------------------------------
create or replace function private.ingest_statement(p_statement_id uuid, p_header jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.bank_statement;
  b public.bank_account;
  prev public.bank_statement;
  v_sections jsonb := coalesce(p_header -> 'sections', '[]');
  v_bad text;
  v_n bigint;
  v_new bigint;
  v_entries bigint := 0;
  v_cash_in jsonb;
  v_counts jsonb;
  v_warnings jsonb := '[]';
  v_check jsonb;
  v_from date;
  v_to date;
  v_cash bigint;
  v_unposted record;
  v_own text[];
  v_client text[];
begin
  select * into s from public.bank_statement where id = p_statement_id for update;
  if not found then
    raise exception 'statement_unknown: statement % does not exist', p_statement_id using errcode = '22023';
  end if;
  if s.status <> 'uploaded' then
    return jsonb_build_object('skipped', s.status);  -- a redelivered job: already done
  end if;
  -- One import at a time per bank account: dedup, overlaps and suspected duplicates see every earlier line.
  perform pg_advisory_xact_lock(hashtext('bank_import:' || s.bank_account_id::text));
  select * into b from public.bank_account where id = s.bank_account_id for share;  -- a closure waits
  if b.status <> 'active' or b.purpose <> 'client_funds' then
    raise exception 'bank_account_closed: bank account % is not an active client_funds account', b.id
      using errcode = '22023';
  end if;
  -- A file is the statement of one bank account: imported for another account of the servicer (the
  -- wrong one chosen first), it is refused, so its money is never booked on two accounts. Imports of
  -- the same file are serialised across the servicer's accounts.
  perform pg_advisory_xact_lock(hashtext('bank_import_file:' || s.organization_id::text || ':' || s.file_sha256));
  select min(p.bank_account_id::text) into v_bad from public.bank_statement p
  where p.organization_id = s.organization_id and p.file_sha256 = s.file_sha256
    and p.bank_account_id <> s.bank_account_id and p.status = 'imported';
  if v_bad is not null then
    raise exception 'imported_on_other_account: this file was imported for bank account %', v_bad using errcode = '22023';
  end if;
  if coalesce(p_header ->> 'format', '') <> s.format or jsonb_typeof(v_sections) <> 'array'
     or (s.format = 'camt053' and jsonb_array_length(v_sections) = 0)
     or (s.format = 'csv' and jsonb_array_length(v_sections) <> 0)
     or coalesce(p_header ->> 'version', '00') !~ '^[0-9]{2}$' then
    raise exception 'header_invalid: the parsed header does not describe a % statement', s.format using errcode = '22023';
  end if;

  -- This statement's lines, in a working table of our own (ADR-0012 temp-schema rule), analysed: every
  -- later query starts from it, so no plan depends on the statistics of the tables loaded below.
  drop table if exists pg_temp._bi_stage;
  create temp table _bi_stage on commit drop as
  select * from private.bank_import_stage where statement_id = p_statement_id;
  alter table pg_temp._bi_stage add primary key (line_no);
  analyze pg_temp._bi_stage;
  -- M2c-1 (§12): our own transfers and credits are classified here whatever the parser knew (the registered own IBANs
  -- may be newer than the job's list): a credit carrying our TOP id or from a registered own IBAN is ours, never a
  -- debtor payment; one from a client's payout IBAN goes to ops; a debit carrying our RMT/SWP id or to our own IBAN
  -- is a transfer out. The stage rows are kept in step (a line held as a duplicate keeps this reading).
  v_own := array(select o.iban from public.bank_account o
                 where o.organization_id = s.organization_id and o.purpose = 'own');
  v_client := private.registered_client_ibans(s.organization_id);
  drop table if exists pg_temp._bi_refined;
  create temp table _bi_refined on commit drop as
  select y.line_no, y.kind from (
    select x.line_no, x.kind as old_kind,
           private.bank_line_refined_kind(x.kind, x.direction, x.end_to_end_id, x.counterparty_iban, v_own, v_client)
             as kind
    from pg_temp._bi_stage x) y
  where y.kind is distinct from y.old_kind;
  if exists (select 1 from pg_temp._bi_refined) then
    update pg_temp._bi_stage x set kind = r.kind from pg_temp._bi_refined r where r.line_no = x.line_no;
    update private.bank_import_stage x set kind = r.kind from pg_temp._bi_refined r
    where x.statement_id = p_statement_id and x.line_no = r.line_no;
  end if;
  select count(*) into v_n from pg_temp._bi_stage;
  if v_n <> coalesce((p_header ->> 'line_count')::bigint, -1) then
    raise exception 'header_invalid: % staged lines, % announced', v_n, p_header ->> 'line_count' using errcode = '22023';
  end if;

  -- Lines are well formed (first offending line named).
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x where x.currency <> s.currency;
  if v_bad is not null then
    raise exception 'currency_mismatch: line % is not in %', v_bad, s.currency using errcode = '22023';
  end if;
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x where x.booking_date > private.paris_today();
  if v_bad is not null then
    raise exception 'future_booking_date: line % is booked after today', v_bad using errcode = '22023';
  end if;
  select min(x.line_no)::text into v_bad from pg_temp._bi_stage x
  where x.direction is null or x.direction not in ('credit', 'debit')
     or x.amount_minor is null or x.amount_minor <= 0 or x.amount_minor > 1000000000000000
     or x.booking_date is null or x.dedup_key is null or x.dedup_key !~ '^[tech]:' or length(x.dedup_key) > 300
     or x.method is null or x.method not in ('sct', 'sdd', 'card', 'cheque', 'other')
     or x.kind is null or x.kind not in ('debtor_credit', 'return', 'refund_out', 'other_debit', 'batch_unsplit',
                                         'transfer_out', 'own_transfer_in', 'client_transfer_in')
     or (x.direction = 'credit' and x.kind not in ('debtor_credit', 'return', 'batch_unsplit', 'own_transfer_in',
                                                   'client_transfer_in'))
     or (x.direction = 'debit' and x.kind in ('debtor_credit', 'own_transfer_in', 'client_transfer_in'))
     or length(x.payment_info_id) not between 1 and 35
     or (s.format = 'csv' and (x.section_no <> 0 or x.dedup_key !~ '^[ch]:' or x.entry_ref is not null))
     or (s.format = 'camt053' and (x.section_no < 1 or x.section_no > jsonb_array_length(v_sections)
                                   or x.dedup_key !~ '^[teh]:'))
     or length(x.entry_ref) not between 1 and 300
     -- an entry key is e:<the line's entry reference>#<n>, n from 1
     or (x.dedup_key ~ '^e:' and not coalesce(left(x.dedup_key, length(x.entry_ref) + 3) = 'e:' || x.entry_ref || '#'
                                              and substr(x.dedup_key, length(x.entry_ref) + 4) ~ '^[1-9][0-9]*$', false));
  if v_bad is not null then
    raise exception 'line_invalid: line % is not a well-formed bank line', v_bad using errcode = '22023';
  end if;
  select min(d.dedup_key) into v_bad
  from (select x.dedup_key from pg_temp._bi_stage x group by x.dedup_key having count(*) > 1) d;
  if v_bad is not null then
    raise exception 'duplicate_reference_in_file: % appears twice in the file', v_bad using errcode = '22023';
  end if;

  -- camt.053: per <Stmt>, opening + credits - debits = closing (the parser checked it already).
  if s.format = 'camt053' then
    select min(sec.ord)::text into v_bad
    from jsonb_array_elements(v_sections) with ordinality as sec (v, ord)
    left join (select x.section_no,
                      sum(case x.direction when 'credit' then x.amount_minor else -x.amount_minor end) as moved
               from pg_temp._bi_stage x group by x.section_no) m on m.section_no = sec.ord
    where sec.v ->> 'opening_minor' is null or sec.v ->> 'closing_minor' is null
       or (sec.v ->> 'opening_minor')::numeric + coalesce(m.moved, 0) <> (sec.v ->> 'closing_minor')::numeric;
    if v_bad is not null then
      raise exception 'unbalanced: statement % of the file: opening + lines <> closing balance', v_bad
        using errcode = '22023';
    end if;
  end if;

  -- 1. Lines this bank account reported already (the same file again, an overlapping statement): skipped,
  --    but only when the bank tells the same facts. A known reference with another amount, direction or
  --    date refuses the file: a line is never dropped because its reference was reused.
  drop table if exists pg_temp._bi_known;
  create temp table _bi_known on commit drop as
  select x.line_no, (x.direction, x.amount_minor, x.booking_date) is distinct from
                    (t.direction, t.amount_minor, t.booking_date) as conflict
  from pg_temp._bi_stage x
  join public.bank_transaction t on t.bank_account_id = s.bank_account_id and t.dedup_key = x.dedup_key;
  select min(k.line_no)::text into v_bad from pg_temp._bi_known k where k.conflict;
  if v_bad is not null then
    raise exception 'reference_conflict: line % has the bank reference of an earlier line with another amount, direction or date',
      v_bad using errcode = '22023';
  end if;
  drop table if exists pg_temp._bi_new;
  create temp table _bi_new on commit drop as
  select x.* from pg_temp._bi_stage x
  where not exists (select 1 from pg_temp._bi_known k where k.line_no = x.line_no);
  alter table pg_temp._bi_new add primary key (line_no);
  analyze pg_temp._bi_new;

  -- A camt.053 entry (Ntry/AcctSvcrRef) is booked once, at the level of detail of its first import: a new
  -- line of an entry this bank account already has means the entry comes back split another way (unsplit
  -- then detailed, or the reverse, or other detail references). Refused: the money would be booked twice.
  v_bad := private.bank_import_entry_known(s.bank_account_id)::text;
  if v_bad is not null then
    raise exception 'entry_detail_differs: line % is part of a bank entry imported earlier with other details', v_bad
      using errcode = '22023';
  end if;

  -- 2. CSV safety net (design §8.3 step 5): same day, amount and direction as a line of another import,
  --    with a similar label -> held as a suspected duplicate (no payment, no cash) until ops decide. Two
  --    lines that both carry the bank's own id are different transactions by the bank's word.
  if s.format = 'csv' then
    -- The same operation on another bank account of the servicer (an export uploaded on the wrong
    -- account first): with the bank's id and the same day, amount and direction, the bank says it is the
    -- same operation and the file is refused; with the same fingerprint (no bank id), the line is held.
    drop table if exists pg_temp._bi_elsewhere;
    create temp table _bi_elsewhere on commit drop as
    select * from private.bank_import_lines_elsewhere(s.organization_id, s.bank_account_id);
    select min(e.line_no)::text into v_bad from pg_temp._bi_elsewhere e where e.dedup_key like 'c:%';
    if v_bad is not null then
      raise exception 'imported_on_other_account: line % was imported for another bank account', v_bad
        using errcode = '22023';
    end if;
    update pg_temp._bi_new n set kind = 'suspected_duplicate'
    from pg_temp._bi_elsewhere e where e.line_no = n.line_no;

    update pg_temp._bi_new n set kind = 'suspected_duplicate'
    from (select distinct x.line_no
          from pg_temp._bi_new x
          join public.bank_transaction t on t.bank_account_id = s.bank_account_id and t.booking_date = x.booking_date
            and t.amount_minor = x.amount_minor and t.direction = x.direction
          where not (x.dedup_key like 'c:%' and t.dedup_key like 'c:%')
            and extensions.similarity(upper(coalesce(t.counterparty_name, '') || ' ' || coalesce(t.remittance_text, '')),
                                      upper(coalesce(x.counterparty_name, '') || ' ' || coalesce(x.remittance_text, '')))
                >= 0.5) d
    where n.line_no = d.line_no;
  end if;

  -- 3. The facts.
  drop table if exists pg_temp._bi_ins;
  create temp table _bi_ins (id uuid primary key, line_no integer not null unique) on commit drop;
  with ins as (
    insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no, dedup_key, direction,
      amount_minor, currency, booking_date, value_date, reversal_indicator, bank_tx_code, acct_svcr_ref, end_to_end_id,
      tx_id, mandate_ref, counterparty_name, ultimate_counterparty_name, counterparty_iban, remittance_text,
      creditor_reference, return_reason, original_end_to_end_id, batch_entry_ref, entry_ref, kind, payment_info_id)
    select s.organization_id, s.bank_account_id, s.id, n.line_no, n.dedup_key, n.direction, n.amount_minor, s.currency,
           n.booking_date, n.value_date, coalesce(n.reversal_indicator, false), n.bank_tx_code, n.acct_svcr_ref,
           n.end_to_end_id, n.tx_id, n.mandate_ref, n.counterparty_name, n.ultimate_counterparty_name,
           n.counterparty_iban, n.remittance_text, n.creditor_reference, n.return_reason, n.original_end_to_end_id,
           n.batch_entry_ref, n.entry_ref, n.kind, n.payment_info_id
    from pg_temp._bi_new n
    order by n.line_no
    on conflict (bank_account_id, dedup_key) do nothing
    returning id, line_no
  )
  insert into pg_temp._bi_ins select ins.id, ins.line_no from ins;
  analyze pg_temp._bi_ins;
  select count(*) into v_new from pg_temp._bi_ins;
  if v_new <> (select count(*) from pg_temp._bi_new) then
    -- cannot happen under the per-account lock; retried by the queue if it ever does
    raise exception 'statement %: lines were imported concurrently', s.id using errcode = '40001';
  end if;

  -- 4. One payment per credit a debtor paid (bank facts copied; unmatched until M2b-3 matches it).
  drop table if exists pg_temp._bi_pay;
  create temp table _bi_pay on commit drop as
  select i.id as bank_transaction_id, n.line_no, n.booking_date, n.amount_minor
  from pg_temp._bi_ins i join pg_temp._bi_new n on n.line_no = i.line_no
  where n.direction = 'credit' and n.kind in ('debtor_credit', 'batch_unsplit');
  analyze pg_temp._bi_pay;
  insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, value_date, payer_name, payer_iban, end_to_end_id,
                              remittance_text, creditor_reference)
  select s.organization_id, s.bank_account_id, p.bank_transaction_id, s.format, n.method, n.amount_minor, s.currency,
         n.booking_date, n.value_date, coalesce(n.counterparty_name, n.ultimate_counterparty_name), n.counterparty_iban,
         n.end_to_end_id, n.remittance_text, n.creditor_reference
  from pg_temp._bi_pay p join pg_temp._bi_new n on n.line_no = p.line_no
  order by p.line_no;

  -- 5. cash_in: one entry per booking date of this statement (design §2 #1), Dr 5120 / Cr 4710 pool.
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  select (row_number() over (order by d.booking_date))::integer, s.organization_id, 'cash_in', d.booking_date,
         'cash_in:' || s.id::text || ':' || d.booking_date::text, 'bank_statement', s.id::text
  from (select distinct p.booking_date from pg_temp._bi_pay p) d;
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select e.entry_no, l.line_no, l.book, l.sign * t.total, s.currency,
         case when l.book = 'client_money_cash' then s.bank_account_id end
  from pg_temp._lps_entry e
  join (select p.booking_date, sum(p.amount_minor) as total from pg_temp._bi_pay p group by p.booking_date) t
    on t.booking_date = e.effective_date
  cross join (values (1, 'client_money_cash', 1), (2, 'unallocated_payment', -1)) as l (line_no, book, sign);
  if exists (select 1 from pg_temp._lps_entry) then
    select count(*) into v_entries from private.ledger_post_set() r where r.created;
  end if;

  -- 6. I11, from the tables: for each booking date, the cash booked for this statement = Σ of its payments.
  select coalesce(jsonb_agg(jsonb_build_object('date', y.d, 'entry_id', y.entry_id, 'minor', y.total::text)
                            order by y.d), '[]')
  into v_cash_in
  from (select e.effective_date as d, e.id as entry_id, sum(lp.amount_minor) as total
        from (select distinct p.booking_date from pg_temp._bi_pay p) k
        join public.ledger_entry e on e.organization_id = s.organization_id
          and e.idempotency_key = 'cash_in:' || s.id::text || ':' || k.booking_date::text
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'client_money_cash'
        group by e.effective_date, e.id) y;
  select min(coalesce(x.d, (y.v ->> 'date')::date)::text) into v_bad
  from (select p.booking_date as d, sum(p.amount_minor) as total
        from pg_temp._bi_pay k join public.payment p on p.bank_transaction_id = k.bank_transaction_id
        group by p.booking_date) x
  full join jsonb_array_elements(v_cash_in) y (v) on (y.v ->> 'date')::date = x.d
  where x.total is distinct from (y.v ->> 'minor')::bigint;
  if v_bad is not null then
    raise exception 'statement %: the cash booked on % differs from its payments (I11)', s.id, v_bad using errcode = 'LG001';
  end if;

  -- 7. What the import did (amounts as text).
  select jsonb_build_object(
    'lines', v_n,
    'new_lines', v_new,
    'known_lines', v_n - v_new,
    'skipped_not_booked', coalesce((p_header ->> 'skipped_not_booked')::bigint, 0),
    'credits', jsonb_build_object('lines', count(*) filter (where n.direction = 'credit'),
                                  'minor', coalesce(sum(n.amount_minor) filter (where n.direction = 'credit'), 0)::text),
    'debits', jsonb_build_object('lines', count(*) filter (where n.direction = 'debit'),
                                 'minor', coalesce(sum(n.amount_minor) filter (where n.direction = 'debit'), 0)::text),
    'payments', jsonb_build_object('count', count(p.line_no), 'minor', coalesce(sum(p.amount_minor), 0)::text),
    'unposted', jsonb_build_object(
      'lines', count(*) filter (where p.line_no is null),
      'minor', coalesce(sum(case n.direction when 'credit' then n.amount_minor else -n.amount_minor end)
                        filter (where p.line_no is null), 0)::text),
    'cash_in', v_cash_in,
    'cash_in_entries', v_entries,
    'returns', count(*) filter (where n.kind = 'return'),
    'refunds_out', count(*) filter (where n.kind = 'refund_out'),
    'other_debits', count(*) filter (where n.kind = 'other_debit'),
    'batch_unsplit', count(*) filter (where n.kind = 'batch_unsplit'),
    'suspected_duplicates', count(*) filter (where n.kind = 'suspected_duplicate'),
    'transfers_out', count(*) filter (where n.kind = 'transfer_out'),
    'own_transfers_in', count(*) filter (where n.kind = 'own_transfer_in'),
    'client_transfers_in', count(*) filter (where n.kind = 'client_transfer_in'))
  into v_counts
  from pg_temp._bi_new n left join pg_temp._bi_pay p on p.line_no = n.line_no;

  -- 8. Dates and balances of the file; continuity with the previous statement (« relevé manquant »).
  if s.format = 'camt053' then
    select min((v ->> 'from_date')::date), max((v ->> 'to_date')::date) into v_from, v_to
    from jsonb_array_elements(v_sections) v;
    -- within the file
    select coalesce(jsonb_agg(jsonb_build_object('code', 'opening_differs', 'stmt_id', cur.v ->> 'stmt_id',
                                                 'expected_minor', pre.v ->> 'closing_minor',
                                                 'actual_minor', cur.v ->> 'opening_minor') order by cur.ord), '[]')
    into v_warnings
    from jsonb_array_elements(v_sections) with ordinality as cur (v, ord)
    join jsonb_array_elements(v_sections) with ordinality as pre (v, ord) on pre.ord = cur.ord - 1
    where (cur.v ->> 'opening_minor')::bigint <> (pre.v ->> 'closing_minor')::bigint;
    -- with the statement that covers the day before this one: of the imported statements starting before
    -- it, the one that ends last (an index scan). If it ends on or after this one's first day, the day
    -- before is covered already (the overlap warning says so): nothing to compare. Only the closing at
    -- its last day is known, so an older statement is never compared.
    select * into prev from public.bank_statement p
    where p.bank_account_id = s.bank_account_id and p.status = 'imported' and p.format = 'camt053'
      and p.from_date < v_from
    order by p.to_date desc, p.finished_at desc
    limit 1;
    if found and prev.to_date < v_from then
      if prev.closing_booked_minor is distinct from (v_sections -> 0 ->> 'opening_minor')::bigint then
        v_warnings := v_warnings || jsonb_build_object('code', 'opening_differs', 'previous_statement_id', prev.id,
          'expected_minor', prev.closing_booked_minor::text, 'actual_minor', v_sections -> 0 ->> 'opening_minor');
      end if;
      if (prev.sections -> -1 ->> 'seq') is not null and (v_sections -> 0 ->> 'seq') is not null
         and (v_sections -> 0 ->> 'seq')::bigint not in ((prev.sections -> -1 ->> 'seq')::bigint + 1, 1) then
        v_warnings := v_warnings || jsonb_build_object('code', 'sequence_gap', 'previous_statement_id', prev.id,
          'previous_seq', prev.sections -> -1 ->> 'seq', 'seq', v_sections -> 0 ->> 'seq');
      end if;
    end if;
  else
    select min(x.booking_date), max(x.booking_date) into v_from, v_to from pg_temp._bi_stage x;
  end if;
  select count(*) into v_n from public.bank_statement p
  where p.bank_account_id = s.bank_account_id and p.status = 'imported' and p.from_date <= v_to and p.to_date >= v_from;
  if v_n > 0 then
    v_warnings := v_warnings || jsonb_build_object('code', 'overlap', 'statements', v_n);
  end if;

  -- 9. I9 at import: closing balance = 5120[bank] + lines not booked (camt.053 only: a CSV has no balance).
  if s.format = 'camt053' then
    select coalesce(sum(lp.amount_minor), 0)::bigint into v_cash
    from public.ledger_account la
    join public.ledger_posting lp on lp.ledger_account_id = la.id and lp.effective_date <= v_to
    where la.bank_account_id = s.bank_account_id and la.book = 'client_money_cash';
    select * into v_unposted from private.bank_unposted(s.bank_account_id, v_to);
    v_check := jsonb_build_object(
      'as_of', v_to,
      'closing_minor', v_sections -> -1 ->> 'closing_minor',
      'cash_minor', v_cash::text,
      'unposted_minor', v_unposted.minor::text,
      'unposted_lines', v_unposted.lines,
      'difference_minor', ((v_sections -> -1 ->> 'closing_minor')::bigint - v_cash - v_unposted.minor)::text);
  end if;

  update public.bank_statement
  set status = 'imported', finished_at = now(),
      format_version = case when s.format = 'camt053' then p_header ->> 'version' end,
      stmt_id = v_sections -> 0 ->> 'stmt_id',
      electronic_seq_no = (v_sections -> 0 ->> 'seq')::bigint,
      from_date = v_from, to_date = v_to,
      opening_booked_minor = (v_sections -> 0 ->> 'opening_minor')::bigint,
      closing_booked_minor = (v_sections -> -1 ->> 'closing_minor')::bigint,
      sections = case when s.format = 'camt053' then v_sections end,
      counts = v_counts, warnings = v_warnings, bank_check = v_check
  where id = s.id;
  delete from private.bank_import_stage where statement_id = s.id;
  return v_counts;
end;
$$;

------------------------------------------------------------------------------------------
-- Booking a bank line in the funds (§6.1 bank_line_booking, §12): one bank line → n entries. M2c-1 books bank fees,
-- top-ups from the own account and the servicer's loss on a return larger than what is left of its payment (OQ-34);
-- M2c-6 adds payouts, sweeps, returned and unplanned payouts. The M2b links (bank_debit_link: returns, refunds) stay
-- the path of the payers' money; a loss line is the M2b return of what is left plus a `loss` booking of the excess.
------------------------------------------------------------------------------------------

create table public.bank_line_booking (
  bank_transaction_id uuid not null references public.bank_transaction (id),
  seq smallint not null check (seq between 1 and 100),
  organization_id uuid not null references public.organization (id),
  bank_account_id uuid not null,
  kind text not null check (kind in ('payout', 'sweep', 'top_up', 'payout_returned', 'unplanned_payout', 'fee', 'loss',
                                     'client_payment')),
  transfer_id uuid references public.bank_transfer (id),
  entry_id uuid not null unique references public.ledger_entry (id),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 1000000000000000),
  method text not null check (method in ('auto', 'ops')),
  reason text check (length(btrim(reason)) between 1 and 2000),     -- ops' motif (staff only)
  decided_by uuid,
  decided_at timestamptz not null default now(),
  primary key (bank_transaction_id, seq),
  constraint bank_line_booking_method check ((method = 'ops') = (decided_by is not null)
                                             and (method <> 'ops' or reason is not null))
);
create index bank_line_booking_org_idx on public.bank_line_booking (organization_id, decided_at desc);
create index bank_line_booking_transfer_idx on public.bank_line_booking (transfer_id) where transfer_id is not null;
comment on table public.bank_line_booking is
  'Entries of the funds a bank line was booked by (fees, top-ups, the servicer''s losses; payouts and sweeps in M2c-6).';

-- Each booking fits its line (servicer, bank account, direction, kind as read or released), its entry (type, source,
-- the line's date and bank account) and its transfer. One keyed lookup per row (kept lateral).
create or replace function private.bank_line_booking_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare v_bad text;
begin
  select min(n.bank_transaction_id::text || ':' || n.seq) into v_bad
  from new_rows n
  cross join lateral (
    select t.organization_id, t.bank_account_id, t.direction, t.booking_date,
           case when t.kind = 'suspected_duplicate' then r.released_kind else t.kind end as kind,
           e.entry_type, e.effective_date, e.source_type, e.source_id, e.organization_id as entry_org,
           (select l.kind from public.bank_debit_link l where l.bank_transaction_id = t.id) as link_kind,
           exists (select 1 from public.payment p where p.bank_transaction_id = t.id offset 0) as paid,
           (select x.creditor_bank_account_id from public.bank_transfer x where x.id = n.transfer_id) as transfer_creditor,
           (select x.kind from public.bank_transfer x where x.id = n.transfer_id) as transfer_kind,
           (select count(*) from public.ledger_posting p
            where p.entry_id = n.entry_id
              and (select la.bank_account_id from public.ledger_account la where la.id = p.ledger_account_id)
                  = t.bank_account_id) as on_line_bank
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    left join public.ledger_entry e on e.id = n.entry_id
    where t.id = n.bank_transaction_id
    offset 0) x
  where x.organization_id <> n.organization_id or x.bank_account_id <> n.bank_account_id
     or x.entry_org is distinct from n.organization_id or x.effective_date is distinct from x.booking_date
     or x.on_line_bank <> 1
     or x.kind is null
     or (n.kind in ('fee', 'loss', 'payout', 'sweep', 'unplanned_payout') and x.direction <> 'debit')
     or (n.kind in ('top_up', 'payout_returned', 'client_payment') and x.direction <> 'credit')
     -- a fee is an other debit (our own transfers out are never fees: review fix), or (M2c-6) the charge on a returned
     -- payout
     or (n.kind = 'fee' and not (x.kind in ('other_debit', 'return') and x.entry_type = 'bank_fee'))
     or (n.kind = 'loss' and not (x.kind = 'return' and x.entry_type = 'servicer_loss'))
     or (n.kind = 'top_up' and not (x.kind = 'own_transfer_in' and x.entry_type = 'servicer_top_up'))
     -- a line explained without booking, or a payment's return or refund, is not also booked; a loss completes a
     -- return of what was left of its payment; a line that is a payment (a debtor's credit, an own credit released as
     -- a relayed debtor payment) is booked by its cash_in, never in the funds
     or (x.link_kind is not null and not (n.kind = 'loss' and x.link_kind = 'return'))
     or x.paid
     or (n.transfer_id is not null and (x.transfer_creditor is distinct from n.bank_account_id
                                        or x.transfer_kind is distinct from 'top_up' or n.kind <> 'top_up'
                                        or x.source_type <> 'bank_transfer' or x.source_id <> n.transfer_id::text))
     or (n.transfer_id is null and (x.source_type <> 'bank_transaction'
                                    or x.source_id <> n.bank_transaction_id::text));
  if v_bad is not null then
    raise exception 'bank line booking %: it does not match its line, entry or transfer', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger bank_line_booking_guard after insert on public.bank_line_booking
  referencing new table as new_rows for each statement execute function private.bank_line_booking_guard();
alter table public.bank_line_booking enable always trigger bank_line_booking_guard;
create trigger bank_line_booking_append_only before update or delete or truncate on public.bank_line_booking
  for each statement execute function private.refuse_change();
alter table public.bank_line_booking enable always trigger bank_line_booking_append_only;

-- At commit: what a line's bookings and its M2b link (a return's or a refund's cash_out) booked is its amount, no more,
-- no less (I19 per line). Keyed lookups.
create or replace function private.bank_line_booking_check()
returns trigger
language plpgsql
security definer
set search_path = ''
set enable_seqscan = off
as $$
declare
  v_line bigint;
  v_booked bigint;
  v_linked bigint;
begin
  select t.amount_minor into v_line from public.bank_transaction t where t.id = new.bank_transaction_id;
  select coalesce(sum(b.amount_minor), 0) into v_booked from public.bank_line_booking b
  where b.bank_transaction_id = new.bank_transaction_id;
  select coalesce(-sum(p.amount_minor), 0) into v_linked
  from public.bank_debit_link l
  join public.ledger_posting p on p.entry_id = l.cash_entry_id
  where l.bank_transaction_id = new.bank_transaction_id and l.kind in ('return', 'refund')
    and (select la.book from public.ledger_account la where la.id = p.ledger_account_id) = 'client_money_cash';
  if v_booked + v_linked <> v_line then
    raise exception 'bank line %: booked % of its %', new.bank_transaction_id, v_booked + v_linked, v_line
      using errcode = 'LG001';
  end if;
  return null;
end;
$$;
create constraint trigger bank_line_booking_complete after insert on public.bank_line_booking
  deferrable initially deferred for each row execute function private.bank_line_booking_check();
alter table public.bank_line_booking enable always trigger bank_line_booking_complete;

-- An own credit released as a relayed debtor payment (§12: « own_transfer_in matching nothing → … a debtor payment
-- relayed by the servicer (it becomes a payment) », ledger critique #8; review fix): a debtor paid the servicer on its
-- own account and the servicer passed the money on to the dedicated account. Ops' decision and motif; the payment is
-- the line's (payment.bank_transaction_id, public.release_own_credit). Append-only.
create table public.bank_own_credit_release (
  bank_transaction_id uuid primary key references public.bank_transaction (id),
  organization_id uuid not null references public.organization (id),
  bank_account_id uuid not null,
  reason text not null check (length(btrim(reason)) between 1 and 2000),     -- ops' motif (staff only)
  decided_by uuid not null,
  decided_at timestamptz not null default now()
);
create index bank_own_credit_release_org_idx on public.bank_own_credit_release (organization_id, decided_at desc);
comment on table public.bank_own_credit_release is
  'Credits from the servicer''s own account that ops released as debtor payments relayed by the servicer (each became a '
  'payment of the dedicated account, unmatched, for ops to assign).';

-- A release is of an own credit of its servicer and bank account (as read, or released from a held duplicate), neither
-- booked in the funds nor linked. One keyed lookup per row.
create or replace function private.bank_own_credit_release_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare v_bad text;
begin
  select min(n.bank_transaction_id::text) into v_bad
  from new_rows n
  left join lateral (select q.organization_id, q.bank_account_id, q.direction, q.kind from public.bank_transaction q
                     where q.id = n.bank_transaction_id offset 0) t on true
  left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                     where q.bank_transaction_id = n.bank_transaction_id offset 0) r on true
  where t.organization_id is distinct from n.organization_id or t.bank_account_id is distinct from n.bank_account_id
     or t.direction <> 'credit'
     or not coalesce(t.kind = 'own_transfer_in'
                     or (t.kind = 'suspected_duplicate' and r.decision = 'released'
                         and r.released_kind = 'own_transfer_in'), false)
     or exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = n.bank_transaction_id offset 0)
     or exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = n.bank_transaction_id offset 0);
  if v_bad is not null then
    raise exception 'own credit release %: not an own credit of its bank account, or already booked or linked', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;
create trigger bank_own_credit_release_guard after insert on public.bank_own_credit_release
  referencing new table as new_rows for each statement execute function private.bank_own_credit_release_guard();
alter table public.bank_own_credit_release enable always trigger bank_own_credit_release_guard;
create trigger bank_own_credit_release_append_only before update or delete or truncate on public.bank_own_credit_release
  for each statement execute function private.refuse_change();
alter table public.bank_own_credit_release enable always trigger bank_own_credit_release_append_only;

-- Lines of a bank account booked on or before a date that are not in the ledger (redefined from 20261110120000; I9:
-- closing balance at D = 5120[bank](D) + this): the lines booked by a funds entry are in the ledger too.
create or replace function private.bank_unposted(p_bank_account_id uuid, p_as_of date)
returns table (minor bigint, lines bigint)
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(case t.direction when 'credit' then t.amount_minor else -t.amount_minor end), 0)::bigint,
         count(*)
  from public.bank_transaction t
  where t.bank_account_id = p_bank_account_id and t.booking_date <= p_as_of
    and not (t.direction = 'credit' and t.kind in ('debtor_credit', 'batch_unsplit'))
    and not exists (select 1 from public.payment p where p.bank_transaction_id = t.id)
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id and l.kind <> 'explained')
    and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id);
$$;

------------------------------------------------------------------------------------------
-- Posting bookings: one function for the debit job (automatic, set-based) and ops' link_debit (one line, every
-- refusal raised). The caller fills pg_temp._bank_booking (private.bank_booking_begin).
------------------------------------------------------------------------------------------

create or replace function private.bank_booking_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._bank_booking;
  drop table if exists pg_temp._booking_skipped;
  drop table if exists pg_temp._booking_failed;
  create temp table _bank_booking (
    ord integer not null unique,
    bank_transaction_id uuid primary key,
    kind text not null check (kind in ('fee', 'top_up', 'loss')),
    transfer_id uuid,               -- top_up: our TOP transfer the credit carries
    amount_minor bigint,            -- loss: the excess over what was left of the payment (else the line's amount)
    method text not null check (method in ('auto', 'ops')),
    decided_by uuid,
    reason text
  ) on commit drop;
  create temp table _booking_skipped (bank_transaction_id uuid primary key, why text not null) on commit drop;
  create temp table _booking_failed (bank_transaction_id uuid primary key, detail text not null) on commit drop;
  -- job: the lines it leaves to ops, with why
  drop table if exists pg_temp._booking_review;
  create temp table _booking_review (
    bank_transaction_id uuid primary key,
    reason text not null,
    candidates jsonb not null default '[]',
    detail text
  ) on commit drop;
end;
$$;

-- Posts the rows of pg_temp._bb (checked by the caller under its locks): one entry per line, its booking, the transfer
-- booked; then the ledger's commit-time checks and the lines' completeness, now.
create or replace function private.bank_booking_post_rows(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id, reason)
  select b.ord, p_organization_id,
         case b.kind when 'fee' then 'bank_fee' when 'top_up' then 'servicer_top_up' else 'servicer_loss' end,
         b.line_date,
         case b.kind when 'fee' then 'fee:' when 'top_up' then 'topup:' else 'loss:' end || b.bank_transaction_id,
         case when b.transfer_id is not null then 'bank_transfer' else 'bank_transaction' end,
         coalesce(b.transfer_id, b.bank_transaction_id)::text,
         coalesce(nullif(btrim(b.reason), ''), case b.kind when 'loss' then 'Excédent du retour sur le paiement (OQ-34)' end)
  from pg_temp._bb b;
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id)
  select b.ord, x.line_no, x.book, x.sign * b.book_minor, b.currency,
         case x.book when 'client_money_cash' then b.line_bank when 'own_cash' then b.own_bank end
  from pg_temp._bb b
  cross join lateral (
    select * from (values
      -- bank_fee: +4679 / −5120 ‖ +6270 / −4689
      ('fee', 1, 'due_to_servicer', 1), ('fee', 2, 'client_money_cash', -1),
      ('fee', 3, 'bank_fees', 1), ('fee', 4, 'due_from_client_funds', -1),
      -- servicer_top_up: +5120 / −4679 ‖ +4689 / −5122
      ('top_up', 1, 'client_money_cash', 1), ('top_up', 2, 'due_to_servicer', -1),
      ('top_up', 3, 'due_from_client_funds', 1), ('top_up', 4, 'own_cash', -1),
      -- servicer_loss: +4679 / −5120 ‖ +6780 / −4689
      ('loss', 1, 'due_to_servicer', 1), ('loss', 2, 'client_money_cash', -1),
      ('loss', 3, 'servicer_losses', 1), ('loss', 4, 'due_from_client_funds', -1)
    ) v (kind, line_no, book, sign) where v.kind = b.kind) x;
  drop table if exists pg_temp._bb_posted;
  create temp table _bb_posted on commit drop as select * from private.ledger_post_set();
  insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id, kind, transfer_id,
                                        entry_id, amount_minor, method, reason, decided_by)
  select b.bank_transaction_id,
         (select coalesce(max(k.seq), 0) + 1 from public.bank_line_booking k where k.bank_transaction_id = b.bank_transaction_id),
         p_organization_id, b.line_bank, b.kind, b.transfer_id, r.entry_id, b.book_minor, b.method,
         nullif(btrim(b.reason), ''), b.decided_by
  from pg_temp._bb b join pg_temp._bb_posted r on r.entry_no = b.ord
  order by b.ord;
  update public.bank_transfer x set status = 'booked', entry_id = r.entry_id
  from pg_temp._bb b join pg_temp._bb_posted r on r.entry_no = b.ord
  where b.transfer_id is not null and x.id = b.transfer_id;
  delete from public.bank_debit_review v using pg_temp._bb b where v.bank_transaction_id = b.bank_transaction_id;
  perform private.ledger_check_now();
  set constraints public.bank_line_booking_complete immediate;
  set constraints public.bank_line_booking_complete deferred;
end;
$$;

-- Posts pg_temp._bank_booking. Locks in the order of every funds writer: the transfers FOR UPDATE, the bank accounts
-- FOR SHARE, the bank lines FOR NO KEY UPDATE (the lock every decision on a line takes: an M2b link in
-- private.post_debit_links, an own credit released as a payment; review fix: a line was booked here and linked there
-- at once, each not seeing the other), then (in ledger_post_set) the remit lock. Every lock and every fact is read by
-- key from the rows asked (review fix: a join or IN from them to bank_transaction read the whole table per chunk at
-- zero rows over its pages). Re-checks every row on what it finds under these locks; p_strict (ops) raises the first
-- refusal, otherwise (job) refused rows go to pg_temp._booking_skipped, and rows the posting refuses (a ledger check)
-- to pg_temp._booking_failed, the others posted (one bad line never stops the job).
create or replace function private.post_bank_bookings(p_organization_id uuid, p_strict boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why record;
  r record;
  v_state text;
  v_msg text;
begin
  perform 1 from public.bank_transfer x
  where x.id = any (array(select b.transfer_id from pg_temp._bank_booking b where b.transfer_id is not null))
  order by x.id for update;
  perform 1 from public.bank_account a
  where a.id = any (array(
          select t.bank_account_id from pg_temp._bank_booking b
          cross join lateral (select q.bank_account_id from public.bank_transaction q
                              where q.id = b.bank_transaction_id offset 0) t
          union
          select x.debtor_bank_account_id from pg_temp._bank_booking b
          cross join lateral (select q.debtor_bank_account_id from public.bank_transfer q
                              where q.id = b.transfer_id offset 0) x))
  order by a.id for share;
  perform 1 from public.bank_transaction t
  where t.id = any (array(select b.bank_transaction_id from pg_temp._bank_booking b))
  order by t.id for no key update;

  -- The facts, read under the locks (one keyed lookup per row: laterals holding only the key).
  drop table if exists pg_temp._bb;
  create temp table _bb on commit drop as
  select b.*, t.organization_id as line_org, t.bank_account_id as line_bank, t.direction, t.currency,
         t.amount_minor as line_minor, t.booking_date as line_date, coalesce(dr.released_kind, t.kind) as line_kind,
         (t.kind = 'suspected_duplicate' and dr.decision is distinct from 'released') as held,
         t.counterparty_iban, t.end_to_end_id,
         -- booked in the funds, or an own credit released as a relayed debtor payment (booked by its cash_in)
         (exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = b.bank_transaction_id offset 0)
          or exists (select 1 from public.bank_own_credit_release c
                     where c.bank_transaction_id = b.bank_transaction_id offset 0)) as booked,
         (select l.kind from public.bank_debit_link l where l.bank_transaction_id = b.bank_transaction_id) as link_kind,
         coalesce((select -sum(p.amount_minor) from public.bank_debit_link l
                   join public.ledger_posting p on p.entry_id = l.cash_entry_id
                   where l.bank_transaction_id = b.bank_transaction_id and l.kind = 'return'
                     and (select la.book from public.ledger_account la where la.id = p.ledger_account_id)
                         = 'client_money_cash'), 0)::bigint as linked_minor,
         x.organization_id as tr_org, x.kind as tr_kind, x.status as tr_status, x.creditor_bank_account_id as tr_creditor,
         x.debtor_bank_account_id as tr_debtor, x.amount_minor as tr_minor, x.currency as tr_currency,
         null::uuid as own_bank, null::bigint as book_minor, null::text as why
  from pg_temp._bank_booking b
  left join lateral (select q.organization_id, q.bank_account_id, q.direction, q.currency, q.amount_minor,
                            q.booking_date, q.kind, q.counterparty_iban, q.end_to_end_id
                     from public.bank_transaction q where q.id = b.bank_transaction_id offset 0) t on true
  left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                     where q.bank_transaction_id = b.bank_transaction_id offset 0) dr on true
  left join lateral (select q.organization_id, q.kind, q.status, q.creditor_bank_account_id, q.debtor_bank_account_id,
                            q.amount_minor, q.currency
                     from public.bank_transfer q where q.id = b.transfer_id offset 0) x on true;
  -- a top-up's own account: its transfer's, or (ops, no transfer) the registered own account the credit came from
  update pg_temp._bb b set own_bank = coalesce(b.tr_debtor, (
    select o.id from public.bank_account o
    where o.organization_id = b.line_org and o.purpose = 'own' and o.status = 'active' and o.iban = b.counterparty_iban
      and o.currency = b.currency))
  where b.kind = 'top_up';
  update pg_temp._bb b set book_minor = case when b.kind = 'loss' then b.amount_minor else b.line_minor end
  where b.bank_transaction_id is not null;

  update pg_temp._bb b set why = case
    when b.line_org is distinct from p_organization_id then 'line_unknown'
    when b.held then 'held_duplicate'
    when b.booked then 'already_booked'
    when b.method = 'ops' and nullif(btrim(b.reason), '') is null then 'reason_required'
    when b.kind = 'fee' then case
      when b.link_kind is not null then 'already_linked'
      -- an other debit only: our own transfers out are booked as sweeps and payouts (M2c-6) or explained, never as
      -- fees (review fix: a withdrawal to the own account read as a bank fee)
      when b.direction <> 'debit' or b.line_kind <> 'other_debit' then 'not_a_fee'
      when b.transfer_id is not null or b.amount_minor is not null then 'bad_request' end
    when b.kind = 'top_up' then case
      when b.link_kind is not null then 'already_linked'
      when b.direction <> 'credit' or b.line_kind <> 'own_transfer_in' then 'not_an_own_credit'
      when b.amount_minor is not null then 'bad_request'
      when b.transfer_id is not null and (b.tr_org is distinct from p_organization_id or b.tr_kind <> 'top_up'
                                          or b.tr_creditor is distinct from b.line_bank) then 'transfer_unknown'
      when b.transfer_id is not null and b.tr_status <> 'ordered' then 'transfer_not_pending'
      when b.transfer_id is not null and (b.tr_minor <> b.line_minor or b.tr_currency <> b.currency) then 'amount_differs'
      when b.own_bank is null then 'own_account_unknown' end
    when b.kind = 'loss' then case
      when b.direction <> 'debit' or b.line_kind <> 'return' then 'not_a_return'
      when b.link_kind is not null and b.link_kind <> 'return' then 'already_linked'
      when b.transfer_id is not null or b.amount_minor is null or b.amount_minor <= 0 then 'bad_request'
      when b.amount_minor + b.linked_minor <> b.line_minor then 'amount_differs' end
  end
  where b.bank_transaction_id is not null;  -- (every row: PostgREST sessions refuse an UPDATE without WHERE)
  update pg_temp._bb b set why = 'transfer_twice'
  where b.why is null and b.transfer_id is not null
    and exists (select 1 from pg_temp._bb o where o.transfer_id = b.transfer_id and o.why is null and o.ord < b.ord);
  select b.why into v_why from pg_temp._bb b where b.why is not null order by b.ord limit 1;
  if found and p_strict then
    raise exception 'bank booking refused: %', v_why.why using errcode = 'check_violation';
  end if;
  insert into pg_temp._booking_skipped (bank_transaction_id, why)
  select b.bank_transaction_id, b.why from pg_temp._bb b where b.why is not null
  on conflict (bank_transaction_id) do update set why = excluded.why;
  delete from pg_temp._bb b where b.why is not null;
  analyze pg_temp._bb;

  if p_strict then
    begin
      perform private.bank_booking_post_rows(p_organization_id);
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      if v_state like 'LG%' or v_state like '22%' or v_state like '23%' then
        raise exception 'bank booking refused: posting_failed (%: %)', v_state, left(v_msg, 500)
          using errcode = 'check_violation';
      end if;
      raise;
    end;
  elsif exists (select 1 from pg_temp._bb) then
    begin
      perform private.bank_booking_post_rows(p_organization_id);   -- the whole chunk at once
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
        raise;
      end if;
      -- a row the posting refuses: each row tried alone (always rolled back), the refused ones to ops, then the others
      drop table if exists pg_temp._bb_all;
      create temp table _bb_all on commit drop as select * from pg_temp._bb;
      for r in select a.ord, a.bank_transaction_id from pg_temp._bb_all a order by a.ord loop
        begin
          delete from pg_temp._bb b where b.bank_transaction_id is not null;
          insert into pg_temp._bb select * from pg_temp._bb_all a where a.ord = r.ord;
          perform private.bank_booking_post_rows(p_organization_id);
          raise exception 'bank booking tried' using errcode = 'BB000';
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
          if v_state <> 'BB000' then
            if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
              raise;
            end if;
            insert into pg_temp._booking_failed (bank_transaction_id, detail)
            values (r.bank_transaction_id, left(v_state || ': ' || v_msg, 2000))
            on conflict (bank_transaction_id) do nothing;
          end if;
        end;
      end loop;
      delete from pg_temp._bb b where b.bank_transaction_id is not null;
      insert into pg_temp._bb select * from pg_temp._bb_all a
      where not exists (select 1 from pg_temp._booking_failed f where f.bank_transaction_id = a.bank_transaction_id);
      if exists (select 1 from pg_temp._bb) then
        perform private.bank_booking_post_rows(p_organization_id);
      end if;
    end;
  end if;

  return jsonb_build_object(
    'fees', (select count(*) from pg_temp._bb where kind = 'fee'),
    'top_ups', (select count(*) from pg_temp._bb where kind = 'top_up'),
    'losses', (select count(*) from pg_temp._bb where kind = 'loss'),
    'skipped', (select count(*) from pg_temp._booking_skipped),
    'failed', (select count(*) from pg_temp._booking_failed));
end;
$$;

-- The lines the debit job may book in the funds (§12), in date order after `p_after`: debits carrying a bank charge
-- code (camt.053 BkTxCd sub-family CHRG or FEES: a fee), our transfers out, credits from our own account (with the
-- ordered top-up whose TOP id they carry) and from a client. Not booked, not linked, not released as a payment. Every
-- lookup is keyed and structural (review fix): each NOT EXISTS and the duplicate's resolution hold only the line's key
-- (OFFSET 0: never an anti-join that, at zero rows over its pages, materialised every booking and compared each line
-- with all of them), and the transfer is found by its end-to-end id alone (unique; the servicer is checked on the row
-- found: with the servicer inside, the servicer's index could serve it and read all its transfers per line).
create or replace function private.bank_booking_candidates(p_organization_id uuid, p_after_date date, p_after_id uuid,
                                                           p_limit integer)
returns table (line_id uuid, line_kind text, direction text, bank_account_id uuid, amount_minor bigint,
               booking_date date, bank_tx_code text, end_to_end_id text, transfer_id uuid, transfer_status text,
               transfer_amount_minor bigint, transfer_creditor_bank_account_id uuid, transfer_date date)
language plpgsql
stable
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
begin
  return query
  select x.id, x.kind, x.direction, x.bank_account_id, x.amount_minor, x.booking_date, x.bank_tx_code, x.end_to_end_id,
         tr.id, tr.status, tr.amount_minor, tr.creditor_bank_account_id, (tr.created_at at time zone 'Europe/Paris')::date
  from (select t.id, coalesce(r.released_kind, t.kind) as kind, t.direction, t.bank_account_id, t.amount_minor,
               t.booking_date, t.bank_tx_code, t.end_to_end_id
        from public.bank_transaction t
        left join lateral (select q.decision, q.released_kind from public.bank_duplicate_resolution q
                           where q.bank_transaction_id = t.id offset 0) r on true
        where t.organization_id = p_organization_id
          and (t.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
               or (t.kind = 'other_debit' and split_part(t.bank_tx_code, '/', 3) in ('CHRG', 'FEES'))
               or (t.kind = 'suspected_duplicate' and r.decision = 'released'
                   and r.released_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')))
          and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
          and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
          and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
          and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id offset 0)
        order by t.booking_date, t.id
        limit greatest(coalesce(p_limit, 2000), 1)) x
  left join lateral (select q.id, q.status, q.amount_minor, q.creditor_bank_account_id, q.created_at, q.organization_id
                     from public.bank_transfer q
                     where x.kind = 'own_transfer_in' and q.end_to_end_id = x.end_to_end_id
                     offset 0) tr on tr.organization_id = p_organization_id
  order by x.booking_date, x.id;
end;
$$;

-- The job's decisions (pg_temp._bank_booking: automatic bookings; pg_temp._booking_review: lines left to ops): bookings
-- posted, the lines' reviews replaced.
create or replace function private.apply_bank_bookings(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb;
begin
  update pg_temp._bank_booking set method = 'auto', decided_by = null where bank_transaction_id is not null;
  v := private.post_bank_bookings(p_organization_id, false);
  insert into pg_temp._booking_review (bank_transaction_id, reason, detail)
  select f.bank_transaction_id, 'posting_failed', f.detail from pg_temp._booking_failed f
  on conflict (bank_transaction_id) do update set reason = excluded.reason, detail = excluded.detail;
  insert into pg_temp._booking_review (bank_transaction_id, reason)
  select s.bank_transaction_id, 'changed' from pg_temp._booking_skipped s
  on conflict (bank_transaction_id) do nothing;
  delete from public.bank_debit_review v using pg_temp._booking_review r where v.bank_transaction_id = r.bank_transaction_id;
  insert into public.bank_debit_review (bank_transaction_id, organization_id, reason, candidates, detail)
  select r.bank_transaction_id, p_organization_id, r.reason, r.candidates, r.detail
  from pg_temp._booking_review r
  cross join lateral (select q.organization_id from public.bank_transaction q
                      where q.id = r.bank_transaction_id offset 0) t
  where t.organization_id = p_organization_id
    and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_own_credit_release c
                    where c.bank_transaction_id = r.bank_transaction_id offset 0);
  return v || jsonb_build_object('reviews', (select count(*) from pg_temp._booking_review));
end;
$$;

-- Why the job leaves a line of the funds to ops (new reasons of bank_debit_review).
alter table public.bank_debit_review drop constraint bank_debit_review_reason_check,
  add constraint bank_debit_review_reason_check check (reason in ('no_candidate', 'ambiguous', 'amount_differs',
    'partial_return', 'refund_not_pending', 'already_returned', 'changed', 'payment_returned', 'before_previous_return',
    'posting_failed', 'top_up_not_found', 'top_up_differs', 'client_credit', 'own_transfer_out'));

------------------------------------------------------------------------------------------
-- The M2b debit links (redefined from 20261110120000): a link may book a part of its line (ops: a loss line's return
-- of what is left of its payment); a line booked in the funds is not linked again; the 4670 guard (LG008) is checked
-- inside the call, so the job sends a refused line to ops instead of failing at commit. « Débits et retours » lists
-- our own transfers and credits to classify, and the funds bookings among the lines decided.
------------------------------------------------------------------------------------------

create or replace function private.debit_link_begin()
returns void
language plpgsql
set search_path = ''
as $$
begin
  drop table if exists pg_temp._debit_link;
  drop table if exists pg_temp._debit_review;
  drop table if exists pg_temp._debit_skipped;
  drop table if exists pg_temp._debit_failed;
  create temp table _debit_link (
    ord integer not null unique,
    bank_transaction_id uuid primary key,
    kind text not null check (kind in ('return', 'refund', 'refund_returned', 'explained')),
    payment_id uuid,
    refund_request_id uuid,
    method text not null check (method in ('auto', 'ops')),
    decided_by uuid,
    reason text,
    expected_left_minor bigint,     -- ops: what is left of the payment as the page showed it (compare and set)
    amount_minor bigint             -- ops (M2c): the part of the line this link books (a loss: what was left)
  ) on commit drop;
  create temp table _debit_review (
    bank_transaction_id uuid primary key,
    reason text not null,
    candidates jsonb not null default '[]',
    detail text
  ) on commit drop;
  create temp table _debit_skipped (
    bank_transaction_id uuid primary key,
    why text not null
  ) on commit drop;
  -- job: links the posting refused (each line on its own), for ops
  create temp table _debit_failed (
    bank_transaction_id uuid primary key,
    candidates jsonb not null,
    detail text not null
  ) on commit drop;
end;
$$;

create or replace function private.post_debit_links(p_organization_id uuid, p_strict boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why record;
  r record;
  v_state text;
  v_msg text;
begin
  -- a refund (or its bounce) is the request's payment
  update pg_temp._debit_link l set payment_id = q.payment_id
  from public.refund_request q where q.id = l.refund_request_id and l.payment_id is null;
  analyze pg_temp._debit_link;

  perform 1 from public.account a
  where a.id in (select p.account_id from public.payment p
                 where p.id in (select l.payment_id from pg_temp._debit_link l where l.payment_id is not null))
  order by a.id for key share;
  perform 1 from public.payment p
  where p.id in (select l.payment_id from pg_temp._debit_link l where l.payment_id is not null)
  order by p.id for update;
  perform 1 from public.refund_request q
  where q.payment_id in (select l.payment_id from pg_temp._debit_link l where l.payment_id is not null)
  order by q.id for update;
  perform 1 from public.bank_account b
  where b.id in (select t.bank_account_id from public.bank_transaction t
                 where t.id in (select l.bank_transaction_id from pg_temp._debit_link l))
  order by b.id for share;
  perform pg_advisory_xact_lock(hashtext('payments:' || p_organization_id::text));
  -- M2c: the lines themselves (the lock every decision on a line takes: a booking in private.post_bank_bookings, an
  -- own credit released as a payment; review fix: a line was linked here and booked there at once, each not seeing
  -- the other). After the allocation lock: the job holds it while its funds pass locks lines.
  perform 1 from public.bank_transaction t
  where t.id = any (array(select l.bank_transaction_id from pg_temp._debit_link l))
  order by t.id for no key update;

  -- The facts, read under the locks. free_from: the latest reversal of the payment dated after the entry it reverses
  -- (a return, a refund that bounced, an allocation ops reversed later): until then its money was allocated or out, so
  -- nothing goes out of it before that date (I4; post_allocations' not_before). One keyed lookup per link (laterals
  -- holding only the key).
  drop table if exists pg_temp._dl;
  create temp table _dl on commit drop as
  select l.*, t.organization_id as line_org, t.bank_account_id as line_bank, t.direction, t.currency,
         coalesce(l.amount_minor, t.amount_minor) as line_minor, t.booking_date as line_date,
         coalesce(dr.released_kind, t.kind) as line_kind,
         (t.kind = 'suspected_duplicate' and dr.decision is distinct from 'released') as held,
         exists (select 1 from public.bank_debit_link x where x.bank_transaction_id = l.bank_transaction_id offset 0)
           as linked,
         -- booked in the funds, or an own credit released as a relayed debtor payment
         (exists (select 1 from public.bank_line_booking x where x.bank_transaction_id = l.bank_transaction_id offset 0)
          or exists (select 1 from public.bank_own_credit_release x
                     where x.bank_transaction_id = l.bank_transaction_id offset 0)) as booked,
         p.organization_id as pay_org, p.bank_account_id as pay_bank, p.booking_date as pay_date, p.status as pay_status,
         p.account_id, p.amount_minor as pay_minor, nb.d as free_from,
         q.payment_id as req_payment, q.status as req_status, q.amount_minor as req_minor, q.bank_account_id as req_bank,
         q.cash_out_entry_id as req_entry, q.executed_on as req_executed_on, q.prior_status as req_prior_status,
         q.prior_review_reason as req_prior_reason,
         0::bigint as allocated, 0::bigint as returned, 0::bigint as unallocated, 0::bigint as pending,
         null::text as why, null::uuid as cash_entry_id
  from pg_temp._debit_link l
  left join lateral (select x.organization_id, x.bank_account_id, x.direction, x.currency, x.amount_minor,
                            x.booking_date, x.kind
                     from public.bank_transaction x where x.id = l.bank_transaction_id offset 0) t on true
  left join lateral (select x.decision, x.released_kind from public.bank_duplicate_resolution x
                     where x.bank_transaction_id = l.bank_transaction_id offset 0) dr on true
  left join lateral (select x.organization_id, x.bank_account_id, x.booking_date, x.status, x.account_id, x.amount_minor
                     from public.payment x where x.id = l.payment_id offset 0) p on true
  left join lateral (select x.payment_id, x.status, x.amount_minor, x.bank_account_id, x.cash_out_entry_id,
                            x.executed_on, x.prior_status, x.prior_review_reason
                     from public.refund_request x where x.id = l.refund_request_id offset 0) q on true
  left join lateral (select max(e.effective_date) as d from public.ledger_entry e
                     join public.ledger_entry v on v.id = e.reverses_entry_id
                     where e.payment_id = l.payment_id and e.effective_date > v.effective_date) nb on true;
  update pg_temp._dl d set allocated = x.allocated_minor, returned = x.returned_minor, unallocated = x.unallocated_minor
  from private.payment_positions(array(select l.payment_id from pg_temp._debit_link l where l.payment_id is not null)) x
  where x.payment_id = d.payment_id;
  update pg_temp._dl d set pending = s.total
  from (select q.payment_id, sum(q.amount_minor) as total from public.refund_request q
        where q.payment_id in (select l.payment_id from pg_temp._debit_link l) and q.status = 'requested'
        group by q.payment_id) s
  where s.payment_id = d.payment_id;

  update pg_temp._dl d set why = case
    when d.line_org is distinct from p_organization_id then 'line_unknown'
    when d.linked then 'already_linked'
    when d.booked then 'already_booked'
    -- a part of a line (M2c: the return of what is left of a payment, its excess the servicer's loss) is ops' only
    when d.amount_minor is not null and (d.method <> 'ops' or d.kind <> 'return' or d.amount_minor <= 0) then 'bad_request'
    when d.held then 'held_duplicate'
    -- our own transfers out and the credits from our own account or a client are never a payment's return, refund or
    -- refund that came back (whatever payment or request is named)
    when d.kind <> 'explained' and d.line_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
      then 'not_a_return'
    when d.kind = 'explained' then case
      when d.payment_id is not null or d.refund_request_id is not null then 'bad_request'
      when d.direction = 'credit' and d.line_kind in ('debtor_credit', 'batch_unsplit') then 'payment_line'
      -- money that went back out for one of our payments is booked, never only explained: our refund (RFD id), or a
      -- return whose references name a payment of this bank account (end-to-end id, or the bank transaction id of the
      -- credit it takes back). The line waits in « À classer » (and the ageing alert) until it is linked (I9; review
      -- fix: a chargeback larger than what is left of its payment is never hidden as an explained gap, OQ-34). A
      -- return naming nothing of ours (e.g. a fee's direct debit the bank rejected) is explained with a motif.
      when d.direction = 'debit' and d.line_kind = 'refund_out' then 'not_explainable'
      when d.direction = 'debit' and d.line_kind = 'return' and exists (
             select 1 from public.bank_transaction x
             where x.id = d.bank_transaction_id
               and (exists (select 1 from public.payment p
                            where p.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id)
                              and p.bank_account_id = x.bank_account_id)
                    or (x.tx_id is not null
                        and exists (select 1 from public.bank_transaction o join public.payment p on p.bank_transaction_id = o.id
                                    where o.bank_account_id = x.bank_account_id and o.tx_id = x.tx_id
                                      and o.direction = 'credit')))) then 'not_explainable'
      when nullif(btrim(d.reason), '') is null then 'reason_required' end
    when d.pay_org is distinct from p_organization_id then 'payment_unknown'
    when d.pay_bank is distinct from d.line_bank then 'other_bank_account'
    when d.kind = 'return' then case
      when d.direction <> 'debit' or d.line_kind not in ('return', 'refund_out', 'other_debit') then 'not_a_return'
      when d.refund_request_id is not null then 'bad_request'
      when d.pay_status = 'returned' then 'already_returned'
      when d.line_date < d.pay_date then 'before_payment'
      when d.line_date < d.free_from then 'before_previous_return'
      -- the job links exactly what is left (payments.debits): anything else, the payment changed since it read it
      when d.method = 'auto' and d.line_minor <> d.pay_minor - d.returned then 'payment_changed'
      when d.line_minor > d.pay_minor - d.returned then 'amount_exceeds'
      when d.line_minor < d.pay_minor - d.returned and d.pending > 0 then 'refund_pending'  -- partial: cancel it first
      when d.method = 'ops' and d.expected_left_minor is distinct from d.pay_minor - d.returned then 'payment_changed' end
    when d.kind = 'refund' then case
      when d.direction <> 'debit' or d.line_kind not in ('refund_out', 'other_debit', 'return') then 'not_a_refund'
      when d.req_status is distinct from 'requested' or d.req_payment is distinct from d.payment_id then 'refund_not_pending'
      when d.req_bank is distinct from d.line_bank then 'other_bank_account'
      when d.line_minor <> d.req_minor then 'amount_differs'
      when d.line_date < d.pay_date then 'before_payment'
      when d.line_date < d.free_from then 'before_previous_return'
      when d.line_minor > d.unallocated then 'amount_exceeds' end
    when d.kind = 'refund_returned' then case
      when d.direction <> 'credit' or d.line_kind <> 'return' then 'not_a_refund_return'
      when d.req_status is distinct from 'executed' or d.req_payment is distinct from d.payment_id then 'refund_not_executed'
      -- the bank took the payment back after the refund: where the money that came back goes is not decided (OQ)
      when d.pay_status = 'returned' then 'payment_returned'
      when d.line_minor <> d.req_minor then 'amount_differs'
      when d.line_date < d.req_executed_on then 'before_refund' end
  end
  where d.bank_transaction_id is not null;  -- (every row: PostgREST sessions refuse an UPDATE without WHERE)
  -- one link per payment per call (a later one waits for the next run)
  update pg_temp._dl d set why = 'payment_twice'
  where d.why is null and d.payment_id is not null
    and exists (select 1 from pg_temp._dl o where o.payment_id = d.payment_id and o.why is null and o.ord < d.ord);
  select d.why, d.bank_transaction_id into v_why from pg_temp._dl d where d.why is not null order by d.ord limit 1;
  if found and p_strict then
    raise exception 'debit link refused: %', v_why.why using errcode = 'check_violation';
  end if;
  insert into pg_temp._debit_skipped (bank_transaction_id, why)
  select d.bank_transaction_id, d.why from pg_temp._dl d where d.why is not null
  on conflict (bank_transaction_id) do update set why = excluded.why;
  delete from pg_temp._dl d where d.why is not null;
  analyze pg_temp._dl;

  if p_strict then
    begin
      perform private.debit_post_rows(p_organization_id);
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
      if v_state like 'LG%' or v_state like '22%' or v_state like '23%' then
        raise exception 'debit link refused: posting_failed (%: %)', v_state, left(v_msg, 500)
          using errcode = 'check_violation';
      end if;
      raise;
    end;
  elsif exists (select 1 from pg_temp._dl) then
    begin
      perform private.debit_post_rows(p_organization_id);   -- the whole chunk at once
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
        raise;  -- not the data's doing (a lock, the machine): the queue retries the run
      end if;
      -- A link the posting refuses (the chunk's subtransaction rolled back): each link is tried on its own in a
      -- subtransaction that is always rolled back (a try leaves nothing, not even its locks: the posting's working
      -- tables would otherwise hold some until commit, for every link); the ones refused go to ops, then the others
      -- are posted together (one link per payment: each posts as it did alone).
      drop table if exists pg_temp._dl_all;
      create temp table _dl_all on commit drop as select * from pg_temp._dl;
      create index on pg_temp._dl_all (ord);
      for r in select a.ord, a.bank_transaction_id, a.payment_id, a.refund_request_id from pg_temp._dl_all a
               order by a.ord loop
        begin
          delete from pg_temp._dl d where d.bank_transaction_id is not null;
          insert into pg_temp._dl select * from pg_temp._dl_all a where a.ord = r.ord;
          perform private.debit_post_rows(p_organization_id);
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
          raise exception 'debit link tried' using errcode = 'DL000';   -- posts on its own: undo the try
        exception when others then
          get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
          if v_state <> 'DL000' then
            if not (v_state like 'LG%' or v_state like '22%' or v_state like '23%') then
              raise;
            end if;
            insert into pg_temp._debit_failed (bank_transaction_id, candidates, detail)
            values (r.bank_transaction_id,
                    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('payment_id', r.payment_id,
                                                                           'refund_request_id', r.refund_request_id))),
                    left(v_state || ': ' || v_msg, 2000))
            on conflict (bank_transaction_id) do nothing;
          end if;
        end;
      end loop;
      delete from pg_temp._dl d where d.bank_transaction_id is not null;
      insert into pg_temp._dl select * from pg_temp._dl_all a
      where not exists (select 1 from pg_temp._debit_failed f where f.bank_transaction_id = a.bank_transaction_id);
      if exists (select 1 from pg_temp._dl) then
        perform private.debit_post_rows(p_organization_id);
      perform private.ledger_check_now();   -- M2c: a client's 4670 never in debit (LG008), raised here
      end if;
    end;
  end if;

  return jsonb_build_object(
    'returns', (select count(*) from pg_temp._dl where kind = 'return'),
    'refunds', (select count(*) from pg_temp._dl where kind = 'refund'),
    'refunds_returned', (select count(*) from pg_temp._dl where kind = 'refund_returned'),
    'explained', (select count(*) from pg_temp._dl where kind = 'explained'),
    'skipped', (select count(*) from pg_temp._debit_skipped),
    'failed', (select count(*) from pg_temp._debit_failed));
end;
$$;

create or replace function public.debit_queue(p_tab text default 'a-classer', p_offset integer default 0,
                                              p_limit integer default 20)
returns table (bank_transaction_id uuid, statement_id uuid, bank_account_id uuid, direction text, kind text,
               amount_minor text, currency char(3), booking_date date, age_days integer, counterparty_name text,
               counterparty_iban_end text, remittance_text text, end_to_end_id text, original_end_to_end_id text,
               return_reason text, review_reason text, candidates jsonb, decision text, decided_at timestamptz,
               decided_payment_id uuid, total bigint, held_kind text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_orgs uuid[] := private.money_staff_org_ids();
  v_today date := private.paris_today();
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_total bigint;
begin
  drop table if exists pg_temp._dq;
  if p_tab = 'doublons' then
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.kind = 'suspected_duplicate'
      and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id);
  elsif p_tab = 'frais' then
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.organization_id = any (v_orgs) and t.kind = 'other_debit'
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
      and not (t.direction = 'debit'
               and exists (select 1 from public.refund_request q
                           where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
                             and q.organization_id = t.organization_id and q.status = 'requested'));
  elsif p_tab = 'traites' then
    -- from the decisions (a few per day), never from the servicer's lines
    create temp table _dq on commit drop as
    select t.*, null::text as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    where t.id in (select l.bank_transaction_id from public.bank_debit_link l where l.organization_id = any (v_orgs)
                   union
                   select k.bank_transaction_id from public.bank_line_booking k
                   where k.organization_id = any (v_orgs)
                   union
                   select c.bank_transaction_id from public.bank_own_credit_release c
                   where c.organization_id = any (v_orgs)
                   union
                   select r.bank_transaction_id from public.bank_duplicate_resolution r
                   where r.organization_id = any (v_orgs)
                     and not (r.decision = 'released' and r.released_kind in ('return', 'refund_out')
                              and not exists (select 1 from public.bank_debit_link l
                                              where l.bank_transaction_id = r.bank_transaction_id)));
  else
    create temp table _dq on commit drop as
    select t.*, coalesce(r.released_kind, t.kind) as eff_kind, null::text as dq_reason, null::jsonb as dq_candidates
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = any (v_orgs) and t.kind in ('return', 'refund_out', 'suspected_duplicate')
      and (t.kind <> 'suspected_duplicate' or r.released_kind in ('return', 'refund_out'))
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
    union all
    -- M2c: our transfers out, credits from our own account or from a client (released duplicates of those kinds
    -- too), not booked, explained or released as a relayed debtor payment yet
    select t.*, coalesce(r.released_kind, t.kind), null::text, null::jsonb
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = any (v_orgs)
      and (t.kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')
           or (t.kind = 'suspected_duplicate'
               and r.released_kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in')))
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
      and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
    union all
    -- an other debit of a pending refund's amount on its bank account: maybe that refund (from the pending requests,
    -- a few, to the lines of their amount); not one booked already (review fix: a fee the job booked stayed listed,
    -- with no action that works)
    select t.*, t.kind, 'refund_amount_match', m.candidates
    from (select o.id, jsonb_agg(jsonb_build_object('refund_request_id', q.id, 'payment_id', q.payment_id)
                                 order by q.requested_at, q.id) as candidates
          from public.refund_request q
          join public.bank_transaction o
            on o.bank_account_id = q.bank_account_id and o.amount_minor = q.amount_minor and o.kind = 'other_debit'
           and o.direction = 'debit' and o.organization_id = q.organization_id
          where q.organization_id = any (v_orgs) and q.status = 'requested'
            and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = o.id)
            and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = o.id)
          group by o.id) m
    join public.bank_transaction t on t.id = m.id;
  end if;
  select count(*) into v_total from pg_temp._dq;
  return query
  select t.id, t.statement_id, t.bank_account_id, t.direction, coalesce(t.eff_kind, t.kind), t.amount_minor::text,
         t.currency, t.booking_date, (v_today - t.booking_date)::integer, t.counterparty_name, right(t.counterparty_iban, 4),
         t.remittance_text, t.end_to_end_id, t.original_end_to_end_id, t.return_reason, coalesce(v.reason, t.dq_reason),
         coalesce((select jsonb_agg(c.v || coalesce(
                     (select jsonb_build_object('amount_minor', p.amount_minor::text, 'currency', p.currency,
                                                'booking_date', p.booking_date, 'payer_name', p.payer_name,
                                                'status', p.status, 'left_minor', (pos.amount_minor - pos.returned_minor)::text,
                                                'file_reference', a.external_ref)
                      from public.payment p
                      left join public.account a on a.id = p.account_id
                      cross join lateral private.payment_positions(array[p.id]) pos
                      where p.id = (c.v ->> 'payment_id')::uuid and p.organization_id = t.organization_id), '{}')
                   || coalesce((select jsonb_build_object('end_to_end_id', q.end_to_end_id, 'refund_status', q.status,
                                                          'refund_minor', q.amount_minor::text)
                                from public.refund_request q
                                where q.id = (c.v ->> 'refund_request_id')::uuid
                                  and q.organization_id = t.organization_id), '{}')
                     order by c.ord)
                   from jsonb_array_elements(coalesce(v.candidates, t.dq_candidates)) with ordinality c (v, ord)),
                  '[]'::jsonb),
         coalesce((select string_agg(k.kind, '+' order by k.seq) from public.bank_line_booking k
                   where k.bank_transaction_id = t.id),
                  case when c.bank_transaction_id is not null then 'relayed_payment' end, l.kind,
                  case r.decision when 'duplicate' then 'duplicate'
                                           when 'released' then 'released' end),
         coalesce(l.decided_at, c.decided_at, r.decided_at),
         coalesce(l.payment_id, (select p.id from public.payment p
                                 where c.bank_transaction_id is not null and p.bank_transaction_id = t.id)),
         v_total,
         -- a held duplicate: how the import read it (the « Libérer » sheet says what it becomes)
         case when t.kind = 'suspected_duplicate' then (select h.kind from private.held_line_kind(t.id) h) end
  from (select * from pg_temp._dq x
        order by (case when p_tab = 'traites' then x.created_at end) desc nulls last, x.booking_date, x.id
        offset v_offset limit v_limit) t
  left join public.bank_debit_review v on v.bank_transaction_id = t.id
  left join public.bank_debit_link l on l.bank_transaction_id = t.id
  left join public.bank_own_credit_release c on c.bank_transaction_id = t.id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
  order by (case when p_tab = 'traites' then t.created_at end) desc nulls last, t.booking_date, t.id;
end;
$$;

-- « Lier » / « Classer » by ops (redefined from 20261110120000; M2c kinds added, same signature):
--   fee:        a debit booked as a bank fee on the dedicated account (bank_fee: the servicer's cost, founder #9);
--   own_credit: a credit from our own account booked as a top-up (servicer_top_up), from the own account its TOP id's
--               order names, or else the registered own account it came from;
--   loss:       a return larger than what is left of its payment (OQ-34, founder #8): the payment's return of what is
--               left (M2b, compare and set on p_expected_left_minor) and the servicer's loss for the excess
--               (servicer_loss), never charged to the client or another client.
-- Every refusal is raised (« debit link refused: … » or « bank booking refused: … »).
create or replace function public.link_debit(p_idempotency_key text, p_bank_transaction_id uuid, p_kind text,
                                             p_payment_id uuid, p_refund_request_id uuid, p_expected_left_minor text,
                                             p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  v_out jsonb;
  v_left bigint;
  v_transfer uuid;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'kind', p_kind, 'payment_id', p_payment_id,
                                  'refund_request_id', p_refund_request_id, 'expected_left_minor', p_expected_left_minor,
                                  'reason', v_reason);
  v_result := private.command_replay('link_debit', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if p_kind is null or p_kind not in ('return', 'refund', 'refund_returned', 'explained', 'fee', 'own_credit', 'loss') then
    raise exception 'debit link refused: bad_request' using errcode = 'check_violation';
  end if;
  if (p_kind in ('return', 'loss')) <> (p_expected_left_minor is not null)
     or (p_expected_left_minor is not null and p_expected_left_minor !~ '^[0-9]{1,16}$')
     or (p_kind in ('return', 'loss')) <> (p_payment_id is not null)
     or (p_kind in ('refund', 'refund_returned')) <> (p_refund_request_id is not null) then
    raise exception 'debit link refused: bad_request' using errcode = 'check_violation';
  end if;

  if p_kind in ('return', 'refund', 'refund_returned', 'explained') then
    perform private.debit_link_begin();
    insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, refund_request_id, method, decided_by,
                                     reason, expected_left_minor)
    values (1, t.id, p_kind, p_payment_id, p_refund_request_id, 'ops', auth.uid(), v_reason,
            p_expected_left_minor::bigint);
    v_out := private.post_debit_links(t.organization_id, true);
  elsif p_kind = 'loss' then
    v_left := p_expected_left_minor::bigint;
    if v_left >= t.amount_minor then
      raise exception 'debit link refused: not_a_loss' using errcode = 'check_violation';
    end if;
    v_out := '{}';
    if v_left > 0 then
      -- the payment's return of what is left of it (the M2b path: its allocations reversed at the return date)
      perform private.debit_link_begin();
      insert into pg_temp._debit_link (ord, bank_transaction_id, kind, payment_id, method, decided_by, reason,
                                       expected_left_minor, amount_minor)
      values (1, t.id, 'return', p_payment_id, 'ops', auth.uid(), v_reason, v_left, v_left);
      v_out := private.post_debit_links(t.organization_id, true);
    elsif not exists (select 1 from private.payment_positions(array[p_payment_id]) x
                      join public.payment p on p.id = x.payment_id
                      where p.organization_id = t.organization_id and p.bank_account_id = t.bank_account_id
                        and x.amount_minor - x.returned_minor = 0) then
      -- nothing is left of the payment (as the page showed): the whole line is the servicer's loss
      raise exception 'debit link refused: payment_changed' using errcode = 'check_violation';
    end if;
    perform private.bank_booking_begin();
    insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, amount_minor, method, decided_by, reason)
    values (1, t.id, 'loss', t.amount_minor - v_left, 'ops', auth.uid(), v_reason);
    v_out := v_out || jsonb_build_object('booking', private.post_bank_bookings(t.organization_id, true));
  else
    -- a credit carrying the TOP id of a pending top-up is that top-up
    if p_kind = 'own_credit' then
      select x.id into v_transfer from public.bank_transfer x
      where x.end_to_end_id = t.end_to_end_id and x.organization_id = t.organization_id and x.kind = 'top_up'
        and x.status = 'ordered';
    end if;
    perform private.bank_booking_begin();
    insert into pg_temp._bank_booking (ord, bank_transaction_id, kind, transfer_id, method, decided_by, reason)
    values (1, t.id, case p_kind when 'fee' then 'fee' else 'top_up' end, v_transfer, 'ops', auth.uid(), v_reason);
    v_out := jsonb_build_object('booking', private.post_bank_bookings(t.organization_id, true));
  end if;
  v_result := jsonb_build_object('bank_transaction_id', t.id, 'kind', p_kind, 'result', v_out);
  perform private.command_record('link_debit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

------------------------------------------------------------------------------------------
-- An own credit released as a debtor payment relayed by the servicer (§12, ledger critique #8; review fix: such a
-- credit could only become the servicer's money or an explained gap, while the debtor's debt was never lowered). The
-- credit is booked as a released duplicate credit is: a payment of the dedicated account and its cash_in at the line's
-- booking date (one path, private.book_credit_payment, shared with « Libérer »).
------------------------------------------------------------------------------------------

-- A credit a debtor paid, booked as a payment of the dedicated account: the payment (the line's bank facts) and its
-- cash_in at the line's booking date, tagged with its statement (I11 sums every cash_in of a statement day; the import
-- posts one per day, a released credit one of its own, keyed by its line). Called under the caller's locks.
create or replace function private.book_credit_payment(p_bank_transaction_id uuid, p_method text, p_payer_name text,
                                                       p_payer_iban text, p_review_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.bank_transaction;
  s public.bank_statement;
  v_payment uuid;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  select * into s from public.bank_statement where id = t.statement_id;
  insert into public.payment (organization_id, bank_account_id, bank_transaction_id, channel, method, amount_minor,
                              currency, booking_date, value_date, payer_name, payer_iban, end_to_end_id,
                              remittance_text, creditor_reference, review_reason)
  values (t.organization_id, t.bank_account_id, t.id, s.format, p_method, t.amount_minor, t.currency, t.booking_date,
          t.value_date, p_payer_name, p_payer_iban, t.end_to_end_id, t.remittance_text, t.creditor_reference,
          p_review_reason)
  returning id into v_payment;
  perform private.ledger_post_set_begin();
  insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key, source_type,
                                  source_id)
  values (1, t.organization_id, 'cash_in', t.booking_date,
          'cash_in:' || t.statement_id || ':' || t.booking_date || ':' || t.id, 'bank_statement', t.statement_id::text);
  insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency, bank_account_id) values
    (1, 1, 'client_money_cash', t.amount_minor, t.currency, t.bank_account_id),
    (1, 2, 'unallocated_payment', -t.amount_minor, t.currency, null);
  perform private.ledger_post_set();
  return v_payment;
end;
$$;

-- « Libérer » / « Doublon confirmé » (redefined from 20261110120000: a released debtor credit is booked through
-- private.book_credit_payment; nothing else changes).
create or replace function public.resolve_duplicate(p_idempotency_key text, p_bank_transaction_id uuid,
                                                    p_is_duplicate boolean, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb;
  v_result jsonb;
  k record;
  v_payment uuid;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_request := jsonb_build_object('bank_transaction_id', p_bank_transaction_id, 'is_duplicate', p_is_duplicate,
                                  'reason', v_reason);
  v_result := private.command_replay('resolve_duplicate', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'a reason is required' using errcode = 'check_violation';
  end if;
  if t.kind <> 'suspected_duplicate' or p_is_duplicate is null then
    raise exception 'duplicate: this line is not held as a suspected duplicate' using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtext('bank_import:' || t.bank_account_id::text));
  if exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id) then
    raise exception 'duplicate: already decided: reload the page' using errcode = 'check_violation';
  end if;
  if p_is_duplicate then
    insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id, bank_account_id, decision,
                                                  reason, decided_by)
    values (t.id, t.organization_id, t.bank_account_id, 'duplicate', v_reason, auth.uid());
    v_result := jsonb_build_object('bank_transaction_id', t.id, 'decision', 'duplicate');
  else
    select * into k from private.held_line_kind(t.id);
    insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id, bank_account_id, decision,
                                                  released_kind, reason, decided_by)
    values (t.id, t.organization_id, t.bank_account_id, 'released', k.kind, v_reason, auth.uid());
    if k.kind in ('debtor_credit', 'batch_unsplit') then
      v_payment := private.book_credit_payment(t.id, k.method,
                                               coalesce(t.counterparty_name, t.ultimate_counterparty_name),
                                               t.counterparty_iban, null);
      perform pgmq.send('payments', jsonb_build_object('type', 'match', 'organization_id', t.organization_id,
                                                       'trigger', 'import'));
    elsif k.kind in ('return', 'refund_out') then
      perform pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', t.organization_id));
    end if;
    v_result := jsonb_build_object('bank_transaction_id', t.id, 'decision', 'released', 'kind', k.kind,
                                   'payment_id', v_payment);
  end if;
  perform private.command_record('resolve_duplicate', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- « Versement relayé par le cabinet »: an own credit (as read, or a held duplicate released as one), neither booked
-- in the funds nor linked, becomes a debtor payment the servicer relayed: a payment of the dedicated account (payer
-- « Versement relayé par le cabinet », never the own account's IBAN: a refund goes to the IBAN ops give), unmatched with
-- review reason no_match, so it waits in « Paiements à traiter » for ops to assign it to its file; its cash_in at the
-- line's booking date. Ops' motif is kept (bank_own_credit_release). Admins and ops managers at aal2, idempotency key +
-- request hash; the bank account FOR SHARE then the line FOR NO KEY UPDATE (the lock every decision on a line takes).
-- Refusals: « own credit release refused: not_own_credit | already_booked | already_linked | reason_required » (23514).
create or replace function public.release_own_credit(p_idempotency_key text, p_bank_transaction_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
set lock_timeout = '2s'
as $$
declare
  t public.bank_transaction;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_request jsonb := jsonb_build_object('bank_transaction_id', p_bank_transaction_id,
                                        'reason', btrim(coalesce(p_reason, '')));
  v_result jsonb;
  v_kind text;
  v_held boolean;
  v_payment uuid;
begin
  select * into t from public.bank_transaction where id = p_bank_transaction_id;
  if not found or not private.has_role(t.organization_id, array['admin', 'ops_manager']) then
    raise exception 'not allowed' using errcode = 'insufficient_privilege';
  end if;
  v_result := private.command_replay('release_own_credit', p_idempotency_key, v_request);
  if v_result is not null then
    return v_result;
  end if;
  if v_reason = '' or length(v_reason) > 2000 then
    raise exception 'own credit release refused: reason_required' using errcode = 'check_violation';
  end if;
  perform 1 from public.bank_account b where b.id = t.bank_account_id for share;
  perform 1 from public.bank_transaction x where x.id = t.id for no key update;
  -- the facts, read under the locks
  select coalesce(r.released_kind, t.kind), (t.kind = 'suspected_duplicate' and r.decision is distinct from 'released')
  into v_kind, v_held
  from (select 1) d
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id;
  if t.direction <> 'credit' or v_kind <> 'own_transfer_in' or v_held then
    raise exception 'own credit release refused: not_own_credit' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id) then
    raise exception 'own credit release refused: already_linked' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
     or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
     or exists (select 1 from public.payment p where p.bank_transaction_id = t.id) then
    raise exception 'own credit release refused: already_booked' using errcode = 'check_violation';
  end if;
  insert into public.bank_own_credit_release (bank_transaction_id, organization_id, bank_account_id, reason, decided_by)
  values (t.id, t.organization_id, t.bank_account_id, v_reason, auth.uid());
  v_payment := private.book_credit_payment(t.id, 'other', 'Versement relayé par le cabinet', null, 'no_match');
  delete from public.bank_debit_review v where v.bank_transaction_id = t.id;
  v_result := jsonb_build_object('payment_id', v_payment, 'status', 'unmatched');
  perform private.command_record('release_own_credit', p_idempotency_key, v_request, v_result);
  return v_result;
end;
$$;

-- A released own credit is a payment too (redefined from 20261110120000): its line is a credit a debtor paid, a
-- single payment or an unsplit batch, a line held as a suspected duplicate that ops released as such a credit, or
-- (M2c) an own credit ops released as a relayed debtor payment.
create or replace function private.payment_insert_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  select min(n.id::text) into v_bad
  from new_rows n
  join public.bank_transaction t on t.id = n.bank_transaction_id
  join public.bank_statement s on s.id = t.statement_id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
  where t.direction <> 'credit' or s.format <> n.channel
     or not (t.kind in ('debtor_credit', 'batch_unsplit')
             or (t.kind = 'suspected_duplicate' and coalesce(r.decision = 'released'
                                                              and r.released_kind in ('debtor_credit', 'batch_unsplit'),
                                                              false))
             or (coalesce(r.released_kind, t.kind) = 'own_transfer_in'
                 and exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id
                             offset 0)));
  if v_bad is not null then
    raise exception 'payment %: its bank line is not a debtor credit of a statement in this channel', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

-- A link fits its line (redefined from 20261110120000; M2c: a line booked in the funds or released as a relayed
-- debtor payment is not linked as well — the backstop of the line lock; a loss line's booking follows its link).
create or replace function private.bank_debit_link_guard()
returns trigger
language plpgsql
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
declare v_bad text;
begin
  select min(n.bank_transaction_id::text) into v_bad
  from new_rows n
  left join public.bank_transaction t on t.id = n.bank_transaction_id
  left join public.bank_duplicate_resolution r on r.bank_transaction_id = n.bank_transaction_id
  left join public.payment p on p.id = n.payment_id
  left join public.refund_request q on q.id = n.refund_request_id
  left join public.ledger_entry e on e.id = n.cash_entry_id
  where t.id is null or t.organization_id <> n.organization_id or t.bank_account_id <> n.bank_account_id
     or (t.kind = 'suspected_duplicate' and r.decision is distinct from 'released')
     or (n.payment_id is not null and p.bank_account_id is distinct from t.bank_account_id)
     or (n.refund_request_id is not null and (q.payment_id is distinct from n.payment_id
                                              or q.bank_account_id is distinct from t.bank_account_id))
     or (n.kind in ('return', 'refund') and t.direction <> 'debit')
     or (n.kind = 'refund_returned' and t.direction <> 'credit')
     or (n.kind = 'explained' and t.direction = 'credit' and coalesce(r.released_kind, t.kind) in ('debtor_credit', 'batch_unsplit'))
     or (n.cash_entry_id is not null and (e.payment_id is distinct from n.payment_id
                                          or (n.kind in ('return', 'refund') and e.entry_type <> 'cash_out')
                                          or (n.kind = 'refund_returned' and e.entry_type <> 'reversal')))
     or exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = n.bank_transaction_id offset 0)
     or exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = n.bank_transaction_id
                offset 0);
  if v_bad is not null then
    raise exception 'bank debit link %: it does not match its line, payment, refund or entry', v_bad
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

-- The debit job's candidates (redefined from 20261110130000; review fix: a return booked whole as the servicer's
-- loss — expected_left 0, a booking and no link — was a candidate forever, its review written again by every run):
-- a line booked in the funds is no candidate either. Each NOT EXISTS holds only the line's key (OFFSET 0: never an
-- anti-join that, at zero rows over its pages, materialises the whole table for each line). SET clauses, security
-- definer and grants as before.
create or replace function private.debit_candidates(p_organization_id uuid, p_after_date date, p_after_id uuid,
                                                    p_limit integer)
returns table (line_id uuid, line_kind text, direction text, bank_account_id uuid, amount_minor bigint,
               booking_date date, payment_id uuid, refund_request_id uuid, via text, cand_bank_account_id uuid,
               cand_amount_minor bigint, cand_left_minor bigint, cand_unallocated_minor bigint,
               cand_pending_minor bigint, cand_status text, cand_date date, cand_payment_status text,
               cand_free_from date)
language plpgsql
security definer
set search_path = ''
set enable_hashjoin = off
set enable_mergejoin = off
as $$
#variable_conflict use_column
begin
  drop table if exists pg_temp._dc_line;
  create temp table _dc_line on commit drop as
  select x.* from (
    select t.id, coalesce(r.released_kind, t.kind) as kind, t.direction, t.bank_account_id, t.amount_minor,
           t.booking_date, t.end_to_end_id, t.original_end_to_end_id, t.tx_id
    from public.bank_transaction t
    left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
    where t.organization_id = p_organization_id
      and t.kind in ('return', 'refund_out', 'suspected_duplicate')
      and (p_after_date is null or (t.booking_date, t.id) > (p_after_date, p_after_id))
      and (t.kind <> 'suspected_duplicate' or r.decision = 'released')
      and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id offset 0)
      and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id offset 0)
    order by t.booking_date, t.id) x
  where (x.direction = 'debit' and x.kind in ('return', 'refund_out')) or (x.direction = 'credit' and x.kind = 'return')
  order by x.booking_date, x.id
  limit greatest(coalesce(p_limit, 10000), 1);
  analyze pg_temp._dc_line;

  drop table if exists pg_temp._dc_cand;
  create temp table _dc_cand on commit drop as
  -- a return of a credit: the payment that carries its end-to-end id, or whose line carries its bank transaction id
  select x.id as line_id, c.payment_id, null::uuid as refund_request_id, c.via
  from pg_temp._dc_line x
  cross join lateral (
    select p.id as payment_id, 'end_to_end_id'::text as via
    from (select q.id, q.bank_account_id from public.payment q
          where q.end_to_end_id = coalesce(x.original_end_to_end_id, x.end_to_end_id) offset 0) p
    where p.bank_account_id = x.bank_account_id
    union
    select p.id, 'tx_id'
    from public.bank_transaction o
    cross join lateral (select q.id from public.payment q where q.bank_transaction_id = o.id offset 0) p
    where x.tx_id is not null and o.bank_account_id = x.bank_account_id and o.tx_id = x.tx_id and o.direction = 'credit'
  ) c
  where x.direction = 'debit' and x.kind = 'return'
  union all
  -- our refund: the request whose RFD id the debit carries; a refund that came back: the one the credit names
  select x.id, q.payment_id, q.id, 'end_to_end_id'
  from pg_temp._dc_line x
  cross join lateral (select r.id, r.payment_id, r.organization_id, r.bank_account_id from public.refund_request r
                      where r.end_to_end_id = case when x.direction = 'debit' then x.end_to_end_id
                                                   else coalesce(x.original_end_to_end_id, x.end_to_end_id) end
                      offset 0) q
  where (x.kind = 'refund_out' or (x.direction = 'credit' and x.kind = 'return'))
    and q.organization_id = p_organization_id and q.bank_account_id = x.bank_account_id;   -- never another tenant's
  create index on pg_temp._dc_cand (line_id);
  analyze pg_temp._dc_cand;

  -- Each payment named, once: its position, its pending refunds, its free-from date (keyed lookups per payment).
  drop table if exists pg_temp._dc_pos;
  create temp table _dc_pos on commit drop as
  select x.payment_id, x.amount_minor - x.returned_minor as left_minor, x.unallocated_minor,
         coalesce((select sum(z.amount_minor) from public.refund_request z
                   where z.payment_id = x.payment_id and z.status = 'requested'), 0)::bigint as pending_minor,
         (select max(e.effective_date) from public.ledger_entry e
          join public.ledger_entry v on v.id = e.reverses_entry_id
          where e.payment_id = x.payment_id and e.effective_date > v.effective_date) as free_from
  from private.payment_positions(array(select distinct y.payment_id from pg_temp._dc_cand y
                                       where y.payment_id is not null)) x;
  alter table pg_temp._dc_pos add primary key (payment_id);
  analyze pg_temp._dc_pos;

  return query
  select x.id, x.kind, x.direction, x.bank_account_id, x.amount_minor, x.booking_date, c.payment_id, c.refund_request_id,
         c.via, coalesce(q.bank_account_id, p.bank_account_id), coalesce(q.amount_minor, p.amount_minor),
         pos.left_minor, pos.unallocated_minor, pos.pending_minor,
         coalesce(q.status, p.status), coalesce(q.executed_on, p.booking_date), p.status, pos.free_from
  from pg_temp._dc_line x
  left join pg_temp._dc_cand c on c.line_id = x.id
  left join lateral (select z.bank_account_id, z.amount_minor, z.status, z.booking_date from public.payment z
                     where z.id = c.payment_id offset 0) p on true
  left join lateral (select z.bank_account_id, z.amount_minor, z.status, z.executed_on from public.refund_request z
                     where z.id = c.refund_request_id offset 0) q on true
  left join pg_temp._dc_pos pos on pos.payment_id = c.payment_id
  order by x.booking_date, x.id, c.payment_id;
end;
$$;

-- The job's decisions (redefined from 20261110120000; review fix): no review is written for a line booked in the
-- funds (a return booked whole as the servicer's loss) or released as a relayed debtor payment; the line is read by
-- its key. Nothing else changes.
create or replace function private.apply_debit_decisions(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v jsonb;
begin
  update pg_temp._debit_link set method = 'auto', decided_by = null, expected_left_minor = null
  where bank_transaction_id is not null;
  v := private.post_debit_links(p_organization_id, false);
  -- refused by the posting itself: ops decide (never retried in a loop: the next run tries it once more)
  insert into pg_temp._debit_review (bank_transaction_id, reason, candidates, detail)
  select f.bank_transaction_id, 'posting_failed', f.candidates, f.detail from pg_temp._debit_failed f
  on conflict (bank_transaction_id) do update
    set reason = excluded.reason, candidates = excluded.candidates, detail = excluded.detail;
  insert into pg_temp._debit_review (bank_transaction_id, reason)
  select s.bank_transaction_id, 'changed' from pg_temp._debit_skipped s
  on conflict (bank_transaction_id) do nothing;
  delete from public.bank_debit_review v using pg_temp._debit_review r where v.bank_transaction_id = r.bank_transaction_id;
  insert into public.bank_debit_review (bank_transaction_id, organization_id, reason, candidates, detail)
  select r.bank_transaction_id, p_organization_id, r.reason, r.candidates, r.detail
  from pg_temp._debit_review r
  cross join lateral (select q.organization_id from public.bank_transaction q
                      where q.id = r.bank_transaction_id offset 0) t
  where t.organization_id = p_organization_id
    and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = r.bank_transaction_id offset 0)
    and not exists (select 1 from public.bank_own_credit_release c
                    where c.bank_transaction_id = r.bank_transaction_id offset 0);
  return v || jsonb_build_object('reviews', (select count(*) from pg_temp._debit_review));
end;
$$;

------------------------------------------------------------------------------------------
-- Nightly checks (§15; redefined from 20261110120000, each check in the same single statement): I8′ with 4679, the
-- servicer's fund closed, the 4679 / 4689 mirror (I12), each client's 4670 never in debit and its running balance =
-- its postings (I13), what each client is owed = its pending items (I14 before runs), I19 per dedicated account; the
-- ageing of lines to classify counts our own transfers and credits not booked (nor released as payments); the alert
-- servicer_shortfall: the servicer owes the dedicated account more than its ordered top-ups cover.
------------------------------------------------------------------------------------------
create or replace function private.run_payment_checks(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run uuid;
  v_today date := private.paris_today();
  v_summary jsonb;
  v_violations integer;
  v_alerts integer;
begin
  if not exists (select 1 from public.organization o where o.id = p_organization_id and o.kind = 'servicer') then
    raise exception 'checks: unknown servicer %', p_organization_id using errcode = '22023';
  end if;
  insert into public.payment_check_run (organization_id) values (p_organization_id) returning id into v_run;
  drop table if exists pg_temp._chk;
  create temp table _chk (code text, severity text, subject_type text, subject_id uuid, currency char(3),
                          amount_minor bigint, count integer, oldest_days integer, details jsonb) on commit drop;

  -- Every check reads the books in ONE statement, so in one snapshot: an entry or a payment committed while the
  -- checks run (a link, a release, an allocation from a PostgREST session) is in every check or in none — never a gap
  -- between the cash read by one check and the payments read by another (review fix: the job runs READ COMMITTED,
  -- where each statement of a function sees the latest commits).
  insert into pg_temp._chk (code, severity, subject_type, subject_id, currency, amount_minor, count, oldest_days, details)
  with pos as materialized (
    -- Every payment's position from its tagged entries (one pass), and its pending refunds.
    select p.id, p.status, p.review_reason, p.account_id, p.amount_minor, p.currency, p.booking_date, p.bank_account_id,
           p.updated_at, coalesce(s.a, 0)::bigint as allocated, coalesce(s.r, 0)::bigint as returned,
           (p.amount_minor - coalesce(s.a, 0) - coalesce(s.r, 0))::bigint as unallocated,
           coalesce(q.pending, 0)::bigint as pending, coalesce(q.n, 0) as pending_n
    from public.payment p
    left join (select e.payment_id,
                      sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) in ('allocation', 'forward')) as a,
                      sum(lp.amount_minor) filter (where coalesce(t.entry_type, e.entry_type) = 'cash_out') as r
               from public.ledger_entry e
               left join public.ledger_entry t on t.id = e.reverses_entry_id
               join public.ledger_posting lp on lp.entry_id = e.id
               join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
               where e.organization_id = p_organization_id and e.payment_id is not null
               group by e.payment_id) s on s.payment_id = p.id
    left join (select q.payment_id, sum(q.amount_minor) as pending, count(*) as n from public.refund_request q
               where q.organization_id = p_organization_id and q.status = 'requested' group by q.payment_id) q
      on q.payment_id = p.id
    where p.organization_id = p_organization_id
  )
  -- I8′: the dedicated-account fund closed per currency (5120 + 4710 + 4670 + 4679 = 0), the servicer's fund closed
  -- per currency (own_fund_identity), and the 4679 / 4689 mirror (fund_mirror, I12), from one pass over the funds.
  select x.code, 'violation'::text, 'servicer'::text, null::uuid, x.currency::char(3), x.total::bigint,
         null::integer, null::integer, x.details
  from (select f.currency, v.code, v.total, v.details
        from (select la.currency,
                     sum(lp.amount_minor) filter (where b.money_of = 'client') as client_total,
                     sum(lp.amount_minor) filter (where b.money_of = 'servicer') as servicer_total,
                     sum(lp.amount_minor) filter (where la.book in ('due_to_servicer', 'due_from_client_funds'))
                       as mirror_total,
                     sum(lp.amount_minor) filter (where la.book = 'client_money_cash') as cash,
                     sum(lp.amount_minor) filter (where la.book = 'unallocated_payment') as pool,
                     sum(lp.amount_minor) filter (where la.book = 'client_payable') as owed,
                     sum(lp.amount_minor) filter (where la.book = 'due_to_servicer') as servicer_share,
                     sum(lp.amount_minor) filter (where la.book = 'due_from_client_funds') as servicer_claim
              from public.ledger_account la
              join public.ledger_book b on b.code = la.book and b.money_of in ('client', 'servicer')
              join public.ledger_posting lp on lp.ledger_account_id = la.id
              where la.organization_id = p_organization_id and la.portfolio_id is null
              group by la.currency) f
        cross join lateral (values
          ('client_money_identity', coalesce(f.client_total, 0),
           jsonb_build_object('cash_minor', coalesce(f.cash, 0)::text, 'unallocated_minor', coalesce(f.pool, 0)::text,
                              'owed_minor', coalesce(f.owed, 0)::text,
                              'due_to_servicer_minor', coalesce(f.servicer_share, 0)::text)),
          ('own_fund_identity', coalesce(f.servicer_total, 0), '{}'::jsonb),
          ('fund_mirror', coalesce(f.mirror_total, 0),
           jsonb_build_object('due_to_servicer_minor', coalesce(f.servicer_share, 0)::text,
                              'due_from_client_funds_minor', coalesce(f.servicer_claim, 0)::text))
        ) v (code, total, details)) x
  where x.total <> 0

  union all
  -- I13: each client's 4670 never in debit, and its running balance = its postings (the commit guard's source).
  select 'client_payable_debit', 'violation', 'client', coalesce(p.client_organization_id, r.client_organization_id),
         coalesce(p.currency, r.currency), coalesce(p.total, 0)::bigint, null, null,
         jsonb_build_object('postings_minor', coalesce(p.total, 0)::text, 'running_minor', coalesce(r.balance_minor, 0)::text)
  from (select la.client_organization_id, la.currency, sum(lp.amount_minor) as total
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'client_payable'
        group by la.client_organization_id, la.currency) p
  full join (select c.client_organization_id, c.currency, c.balance_minor from private.client_payable_balance c
             where c.organization_id = p_organization_id) r
    on r.client_organization_id = p.client_organization_id and r.currency = p.currency
  where coalesce(p.total, 0) > 0 or coalesce(p.total, 0) <> coalesce(r.balance_minor, 0)

  union all
  -- I14 (completeness; M2c-4 adds the runs approved and not booked yet): what each client is owed = its items
  -- waiting in the pending queue.
  select 'remittance_completeness', 'violation', 'client', coalesce(r.client_organization_id, q.client_organization_id),
         coalesce(r.currency, q.currency), (-coalesce(r.balance_minor, 0) - coalesce(q.total, 0))::bigint, null, null,
         jsonb_build_object('owed_minor', (-coalesce(r.balance_minor, 0))::text, 'pending_minor', coalesce(q.total, 0)::text)
  from (select c.client_organization_id, c.currency, c.balance_minor from private.client_payable_balance c
        where c.organization_id = p_organization_id) r
  full join (select q.client_organization_id, q.currency, sum(q.amount_minor) as total from private.remittance_pending q
             where q.organization_id = p_organization_id group by q.client_organization_id, q.currency) q
    on q.client_organization_id = r.client_organization_id and q.currency = r.currency
  where -coalesce(r.balance_minor, 0) <> coalesce(q.total, 0)

  union all
  -- I19, per dedicated account: its cash = what its payments brought in less what went back out to the payers
  -- (returns, refunds) + what its lines booked in the funds moved (top-ups in; fees, losses out; payouts and sweeps
  -- from M2c-6). Every 5120 movement of a funds entry comes from a bank line booked here.
  select 'bank_cash_identity', 'violation', 'bank_account', coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id),
         b.currency, (coalesce(c.cash, 0) - coalesce(y.held, 0) - coalesce(k.moved, 0))::bigint, null, null,
         jsonb_build_object('cash_minor', coalesce(c.cash, 0)::text, 'unallocated_minor', coalesce(y.unallocated, 0)::text,
                            'allocated_minor', coalesce(y.allocated, 0)::text,
                            'booked_lines_minor', coalesce(k.moved, 0)::text)
  from (select la.bank_account_id, sum(lp.amount_minor) as cash
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'client_money_cash'
        group by la.bank_account_id) c
  full join (select x.bank_account_id, sum(x.amount_minor - x.returned) as held, sum(x.unallocated) as unallocated,
                    sum(x.allocated) as allocated
             from pos x where x.bank_account_id is not null group by x.bank_account_id) y
    on y.bank_account_id = c.bank_account_id
  full join (select k.bank_account_id,
                    sum(case t.direction when 'credit' then k.amount_minor else -k.amount_minor end) as moved
             from public.bank_line_booking k join public.bank_transaction t on t.id = k.bank_transaction_id
             where k.organization_id = p_organization_id
             group by k.bank_account_id) k on k.bank_account_id = coalesce(c.bank_account_id, y.bank_account_id)
  join public.bank_account b on b.id = coalesce(c.bank_account_id, y.bank_account_id, k.bank_account_id)
  where coalesce(c.cash, 0) <> coalesce(y.held, 0) + coalesce(k.moved, 0)

  union all
  -- I11: the cash booked for a statement day = its payments (released duplicates included).
  select 'cash_in_statement', 'violation', 'bank_statement', coalesce(ci.statement_id, pd.statement_id), null,
         (coalesce(ci.total, 0) - coalesce(pd.total, 0))::bigint, null, null,
         jsonb_build_object('date', coalesce(ci.d, pd.d), 'cash_in_minor', coalesce(ci.total, 0)::text,
                            'payments_minor', coalesce(pd.total, 0)::text)
  from (select e.source_id::uuid as statement_id, e.effective_date as d, sum(lp.amount_minor) as total
        from public.ledger_entry e
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'client_money_cash'
        where e.organization_id = p_organization_id and e.entry_type = 'cash_in'
        group by e.source_id, e.effective_date) ci
  full join (select t.statement_id, p.booking_date as d, sum(p.amount_minor) as total
             from public.payment p join public.bank_transaction t on t.id = p.bank_transaction_id
             where p.organization_id = p_organization_id
             group by t.statement_id, p.booking_date) pd
    on pd.statement_id = ci.statement_id and pd.d = ci.d
  where coalesce(ci.total, 0) <> coalesce(pd.total, 0)

  union all
  -- I4, I5 and design §7: each payment's position against its status.
  select 'payment_position', 'violation', 'payment', c.id, c.currency, c.unallocated, null, v_today - c.booking_date,
         jsonb_build_object('status', c.status, 'allocated_minor', c.allocated::text,
                            'unallocated_minor', c.unallocated::text, 'returned_minor', c.returned::text,
                            'pending_refund_minor', c.pending::text)
  from pos c
  where c.unallocated < 0 or c.allocated < 0 or c.returned < 0
     or (c.status = 'allocated' and not (c.allocated > 0 and c.unallocated = 0))
     or (c.status = 'partially_allocated' and not (c.allocated > 0 and c.unallocated > 0))
     or (c.status in ('unmatched', 'matched') and not (c.allocated = 0 and c.unallocated > 0))
     or (c.status = 'unmatched' and c.account_id is not null)
     or (c.status = 'refunded' and not (c.allocated = 0 and c.unallocated = 0 and c.returned = c.amount_minor))
     or (c.status = 'returned' and not (c.allocated = 0 and c.unallocated = 0))
     or ((c.status = 'refund_pending') <> (c.pending_n > 0))
     or c.pending > c.unallocated

  union all
  -- the net allocated per (payment, file) is never negative
  select 'payment_negative_allocation', 'violation', 'payment', x.payment_id, null, x.total::bigint, null, null,
         jsonb_build_object('account_id', x.account_id)
  from (select e.payment_id, e.account_id, sum(lp.amount_minor) as total
        from public.ledger_entry e
        left join public.ledger_entry t on t.id = e.reverses_entry_id
        join public.ledger_posting lp on lp.entry_id = e.id
        join public.ledger_account la on la.id = lp.ledger_account_id and la.book = 'unallocated_payment'
        where e.organization_id = p_organization_id and e.payment_id is not null
          and coalesce(t.entry_type, e.entry_type) = 'allocation'
        group by e.payment_id, e.account_id) x
  where x.total < 0

  union all
  -- I6: no receivable a payment (or a credit note, or a payment made to the client) lowered is below zero now; no item
  -- below zero as a whole once such an entry touched it.
  select 'receivable_negative', 'violation', 'claim_item', x.claim_item_id, x.currency, x.balance::bigint, null, null,
         jsonb_build_object('component', x.component)
  from (select la.claim_item_id, la.component, la.currency, sum(lp.amount_minor) as balance
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'debtor_receivable'
          and exists (select 1 from public.ledger_posting q join public.ledger_entry e on e.id = q.entry_id
                      where q.ledger_account_id = la.id and q.amount_minor < 0
                        and (e.entry_type in ('allocation', 'netting')
                             or (e.entry_type = 'adjustment' and e.source_type = 'direct_payment')))
        group by la.claim_item_id, la.component, la.currency) x
  where x.balance < 0
  union all
  select 'item_negative', 'violation', 'claim_item', y.claim_item_id, y.currency, y.balance::bigint, null, null,
         '{}'::jsonb
  from (select la.claim_item_id, la.currency, sum(lp.amount_minor) as balance
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'debtor_receivable'
          and la.claim_item_id in (
            select l2.claim_item_id from public.ledger_account l2
            join public.ledger_posting q on q.ledger_account_id = l2.id
            join public.ledger_entry e on e.id = q.entry_id
            where l2.organization_id = p_organization_id and l2.book = 'debtor_receivable' and q.amount_minor < 0
              and (e.entry_type = 'allocation' or (e.entry_type = 'adjustment' and e.source_type = 'direct_payment')))
        group by la.claim_item_id, la.currency) y
  where y.balance < 0

  union all
  -- The owner-claim mirror (M2a risk #5): per portfolio, component and currency, 3100 = −Σ1100.
  select 'owner_claim_mirror', 'violation', 'portfolio', x.portfolio_id, x.currency, x.total::bigint, null, null,
         jsonb_build_object('component', x.component)
  from (select la.portfolio_id, la.component, la.currency, sum(lp.amount_minor) as total
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book in ('debtor_receivable', 'owner_claim')
        group by la.portfolio_id, la.component, la.currency) x
  where x.total <> 0

  union all
  -- R124-6: one receipt number per payment on a file and a current version about its file (void once returned). A
  -- payment changed in the last hour may still be in the receipts queue.
  select y.code, 'violation', 'payment', y.id, null, null, null, v_today - y.booking_date,
         jsonb_build_object('status', y.status)
  from (select c.id, c.booking_date, c.status,
               case when r.payment_id is null and c.status <> 'returned' then 'receipt_missing'
                    when r.numbers > 1 then 'receipt_numbers'
                    when c.status = 'returned' and r.payment_id is not null and cur.kind <> 'void' then 'receipt_not_void'
                    when c.status <> 'returned' and r.payment_id is not null
                         and (cur.kind = 'void' or cur.account_id is distinct from c.account_id) then 'receipt_stale'
               end as code
        from pos c
        left join (select x.payment_id, count(distinct x.number) as numbers, max(x.version) as v
                   from public.receipt x where x.organization_id = p_organization_id group by x.payment_id) r
          on r.payment_id = c.id
        left join public.receipt cur on cur.payment_id = c.id and cur.version = r.v
        where c.account_id is not null and c.updated_at < now() - interval '1 hour'
          and not (c.status in ('matched', 'partially_allocated') and c.review_reason is null)) y
  where y.code is not null

  union all
  -- R124-5: one notification per entry that moves what a client is owed, one per payment held for a file, one per
  -- return of a payment on a file.
  select 'notification_missing', 'violation', 'ledger_entry', e.id, null, null, null, null,
         jsonb_build_object('entry_type', e.entry_type, 'payment_id', e.payment_id)
  from public.ledger_entry e
  left join public.ledger_entry t on t.id = e.reverses_entry_id
  where e.organization_id = p_organization_id and e.payment_id is not null
    and (e.entry_type in ('allocation', 'forward') or (e.entry_type = 'reversal' and t.entry_type in ('allocation', 'forward')))
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = e.id)
  union all
  select 'notification_missing', 'violation', 'payment', c.id, null, null, null, null,
         jsonb_build_object('kind', 'payment_held')
  from pos c
  where c.review_reason = 'hold_blocks_allocation' and c.account_id is not null
    and not exists (select 1 from public.client_notification n
                    where n.payment_id = c.id and n.account_id = c.account_id and n.kind = 'payment_held')
  union all
  select 'notification_missing', 'violation', 'payment', l.payment_id, null, null, null, null,
         jsonb_build_object('kind', 'payment_returned')
  from public.bank_debit_link l
  join public.payment p on p.id = l.payment_id
  where l.organization_id = p_organization_id and l.kind = 'return' and p.account_id is not null
    and not exists (select 1 from public.client_notification n where n.ledger_entry_id = l.cash_entry_id)

  union all
  -- Statements (I9): a camt.053 statement whose opening is not the previous closing (« relevé manquant »), and each
  -- bank account's balance at its last statement against the ledger cash plus the lines not booked.
  select 'statement_gap', 'alert', 'bank_statement', x.id, null, (x.opening_booked_minor - x.prev_closing)::bigint,
         null, null,
         jsonb_build_object('bank_account_id', x.bank_account_id, 'from_date', x.from_date, 'previous_to_date', x.prev_to)
  from (select s.id, s.bank_account_id, s.from_date, s.opening_booked_minor,
               lag(s.closing_booked_minor) over w as prev_closing, lag(s.to_date) over w as prev_to
        from public.bank_statement s
        where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
        window w as (partition by s.bank_account_id order by s.from_date, s.to_date, s.finished_at)) x
  where x.prev_closing is not null and x.prev_to < x.from_date and x.opening_booked_minor <> x.prev_closing
  union all
  select 'bank_balance_gap', 'alert', 'bank_account', z.bank_account_id, z.currency,
         (z.closing - z.cash - z.unposted)::bigint, null, null,
         jsonb_build_object('as_of', z.to_date, 'closing_minor', z.closing::text, 'cash_minor', z.cash::text,
                            'unposted_minor', z.unposted::text, 'unposted_lines', z.unposted_lines)
  from (select l.bank_account_id, l.currency, l.to_date, l.closing_booked_minor as closing,
               coalesce((select sum(lp.amount_minor) from public.ledger_account la
                         join public.ledger_posting lp on lp.ledger_account_id = la.id and lp.effective_date <= l.to_date
                         where la.bank_account_id = l.bank_account_id and la.book = 'client_money_cash'), 0) as cash,
               u.minor as unposted, u.lines as unposted_lines
        from (select distinct on (s.bank_account_id) s.bank_account_id, s.currency, s.to_date, s.closing_booked_minor
              from public.bank_statement s
              where s.organization_id = p_organization_id and s.status = 'imported' and s.format = 'camt053'
              order by s.bank_account_id, s.to_date desc, s.finished_at desc) l
        cross join lateral private.bank_unposted(l.bank_account_id, l.to_date) u) z
  where z.closing - z.cash - z.unposted <> 0

  union all
  -- servicer_shortfall (§15, P0; review fix): the servicer owes the dedicated account more than the top-ups ordered
  -- cover — 4679 in debit (the fees and losses booked on the account are the servicer's cost, founder #8, #9) less
  -- the top-ups ordered and not booked yet: an approvisionnement from the own account is to order, for this amount.
  select 'servicer_shortfall', 'alert', 'servicer', null, s.currency, (s.owed - coalesce(o.ordered, 0))::bigint, null,
         null, jsonb_build_object('due_to_servicer_minor', s.owed::text,
                                  'top_ups_ordered_minor', coalesce(o.ordered, 0)::text)
  from (select la.currency, sum(lp.amount_minor) as owed
        from public.ledger_account la join public.ledger_posting lp on lp.ledger_account_id = la.id
        where la.organization_id = p_organization_id and la.book = 'due_to_servicer'
        group by la.currency) s
  left join (select x.currency, sum(x.amount_minor) as ordered from public.bank_transfer x
             where x.organization_id = p_organization_id and x.kind = 'top_up' and x.status in ('ordered', 'in_file')
             group by x.currency) o on o.currency = s.currency
  where s.owed - coalesce(o.ordered, 0) > 0

  union all
  -- Ageing (alerts, one row per code with the oldest and up to 50 payments or lines).
  select x.code, 'alert', 'servicer', null, x.currency, x.total, x.n, x.oldest, jsonb_build_object('ids', x.ids)
  from (select 'unmatched_ageing' as code, c.currency, sum(c.unallocated)::bigint as total, count(*)::integer as n,
               max(v_today - c.booking_date) as oldest,
               (array_agg(c.id order by c.booking_date, c.id))[1:50] as ids
        from pos c
        where c.status = 'unmatched' and v_today - c.booking_date >= 20
        group by c.currency
        union all
        select 'unallocated_ageing', c.currency, sum(c.unallocated)::bigint, count(*)::integer,
               max(v_today - c.booking_date), (array_agg(c.id order by c.booking_date, c.id))[1:50]
        from pos c
        where c.account_id is not null and c.unallocated > 0 and c.status in ('matched', 'partially_allocated')
          and c.review_reason is not null and v_today - c.booking_date >= 20
        group by c.currency
        union all
        select 'refund_pending_ageing', q.currency, sum(q.amount_minor)::bigint, count(*)::integer,
               max(v_today - (q.requested_at at time zone 'Europe/Paris')::date),
               (array_agg(q.payment_id order by q.requested_at, q.id))[1:50]
        from public.refund_request q
        where q.organization_id = p_organization_id and q.status = 'requested'
          and v_today - (q.requested_at at time zone 'Europe/Paris')::date >= 5
        group by q.currency
        union all
        -- returns, our refunds, credits undoing a debit (released duplicates of those kinds) not linked — they can
        -- only be booked, never explained — and other debits of a pending refund's amount on its bank account
        select 'debit_unclassified', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from public.bank_transaction t
        left join public.bank_duplicate_resolution r on r.bank_transaction_id = t.id
        where t.organization_id = p_organization_id
          and (t.kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in', 'client_transfer_in')
               or (t.kind = 'suspected_duplicate'
                   and r.released_kind in ('return', 'refund_out', 'transfer_out', 'own_transfer_in',
                                           'client_transfer_in'))
               or (t.kind = 'other_debit' and t.direction = 'debit'
                   and exists (select 1 from public.refund_request q
                               where q.bank_account_id = t.bank_account_id and q.amount_minor = t.amount_minor
                                 and q.organization_id = t.organization_id and q.status = 'requested')))
          and not exists (select 1 from public.bank_debit_link l where l.bank_transaction_id = t.id)
          and not exists (select 1 from public.bank_line_booking k where k.bank_transaction_id = t.id)
          and not exists (select 1 from public.bank_own_credit_release c where c.bank_transaction_id = t.id)
          and v_today - t.booking_date >= 3
        group by t.currency
        union all
        select 'duplicate_unresolved', t.currency, sum(t.amount_minor)::bigint, count(*)::integer,
               max(v_today - t.booking_date), (array_agg(t.id order by t.booking_date, t.id))[1:50]
        from public.bank_transaction t
        where t.organization_id = p_organization_id and t.kind = 'suspected_duplicate'
          and not exists (select 1 from public.bank_duplicate_resolution r where r.bank_transaction_id = t.id)
          and v_today - t.booking_date >= 3
        group by t.currency
        union all
        select 'direct_payment_waiting', d.currency, sum(d.amount_minor)::bigint, count(*)::integer,
               max(v_today - (d.requested_at at time zone 'Europe/Paris')::date),
               (array_agg(d.id order by d.requested_at, d.id))[1:50]
        from public.direct_payment d
        where d.organization_id = p_organization_id and d.status = 'requested' and d.requested_at < now() - interval '1 hour'
        group by d.currency) x;

  insert into public.payment_check_result (run_id, organization_id, code, severity, subject_type, subject_id, currency,
                                           amount_minor, count, oldest_days, details)
  select v_run, p_organization_id, c.code, c.severity, c.subject_type, c.subject_id, c.currency, c.amount_minor, c.count,
         c.oldest_days, coalesce(c.details, '{}')
  from pg_temp._chk c;
  select coalesce(jsonb_object_agg(x.code, x.n), '{}') into v_summary
  from (select c.code, count(*) as n from pg_temp._chk c group by c.code) x;
  select count(*) filter (where c.severity = 'violation'), count(*) filter (where c.severity = 'alert')
  into v_violations, v_alerts from pg_temp._chk c;
  update public.payment_check_run
  set finished_at = clock_timestamp(), violations = v_violations, alerts = v_alerts, summary = v_summary
  where id = v_run;
  return jsonb_build_object('run_id', v_run, 'violations', v_violations, 'alerts', v_alerts, 'by_code', v_summary);
end;
$$;

------------------------------------------------------------------------------------------
-- Read access (§6.2): transfers and bank line bookings are money staff's (third-party payer data and the servicer's
-- treasury); the private tables are read by nobody through the Data API. No write policy: writes go through the
-- definer functions above or the worker.
------------------------------------------------------------------------------------------

alter table public.bank_transfer enable row level security;
alter table public.bank_line_booking enable row level security;
alter table public.bank_own_credit_release enable row level security;
alter table private.client_payable_balance enable row level security;
alter table private.remittance_pending enable row level security;
revoke all on public.bank_transfer, public.bank_line_booking, public.bank_own_credit_release
  from public, anon, authenticated;
revoke all on private.client_payable_balance, private.remittance_pending from public, anon, authenticated, service_role;
grant select on public.bank_transfer, public.bank_line_booking, public.bank_own_credit_release
  to authenticated, service_role;
create policy bank_transfer_read on public.bank_transfer for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy bank_line_booking_read on public.bank_line_booking for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));
create policy bank_own_credit_release_read on public.bank_own_credit_release for select to authenticated
  using (organization_id = any ((select private.money_staff_org_ids())::uuid[]));

------------------------------------------------------------------------------------------
-- Privileges
------------------------------------------------------------------------------------------

revoke execute on function private.bank_statement_purpose_guard(), private.ledger_posting_client_payable(),
  private.client_payable_check(), private.ledger_check_now(), private.registered_client_ibans(uuid),
  private.statement_classification_ibans(uuid), private.bank_line_refined_kind(text, text, text, text, text[], text[]),
  private.bank_transfer_guard(), private.bank_line_booking_guard(), private.bank_line_booking_check(),
  private.bank_booking_begin(), private.bank_booking_post_rows(uuid), private.post_bank_bookings(uuid, boolean),
  private.bank_booking_candidates(uuid, date, uuid, integer), private.apply_bank_bookings(uuid),
  private.bank_own_credit_release_guard(), private.book_credit_payment(uuid, text, text, text, text),
  private.payment_insert_guard(), private.bank_debit_link_guard(), private.debit_candidates(uuid, date, uuid, integer),
  private.apply_debit_decisions(uuid)
  from public, anon, authenticated, service_role;
-- The worker (service_role) classifies statements (the parser's parity), runs the debit job's bookings, and checks the
-- ledger at once in its own transactions (tests, property machine).
grant execute on function private.statement_classification_ibans(uuid),
  private.bank_line_refined_kind(text, text, text, text, text[], text[]), private.bank_booking_begin(),
  private.bank_booking_candidates(uuid, date, uuid, integer), private.apply_bank_bookings(uuid),
  private.ledger_check_now() to service_role;
-- (as granted by 20261110120000 and 20261110130000: the debit job's)
grant execute on function private.debit_candidates(uuid, date, uuid, integer), private.apply_debit_decisions(uuid)
  to service_role;
revoke execute on function public.register_bank_account(text, uuid, text, text, text, text, text, date, text),
  public.request_top_up(text, uuid, uuid, text, text, date), public.cancel_top_up(text, uuid, text),
  public.release_own_credit(text, uuid, text), public.resolve_duplicate(text, uuid, boolean, text) from public, anon;
grant execute on function public.register_bank_account(text, uuid, text, text, text, text, text, date, text),
  public.request_top_up(text, uuid, uuid, text, text, date), public.cancel_top_up(text, uuid, text),
  public.release_own_credit(text, uuid, text), public.resolve_duplicate(text, uuid, boolean, text) to authenticated;

-- The lines imported before this migration: the debit job books their bank charges (M2b fee lines) at its next run.
select pgmq.send('payments', jsonb_build_object('type', 'process_debits', 'organization_id', x.organization_id))
from (select distinct t.organization_id from public.bank_transaction t
      where t.kind = 'other_debit' and split_part(t.bank_tx_code, '/', 3) in ('CHRG', 'FEES')) x;
