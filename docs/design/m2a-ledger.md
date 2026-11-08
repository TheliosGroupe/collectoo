# M2a Ledger: synthesized implementation design (M2-01 … M2-05)

Status: design for PR M2a (implementation follows in the same PR). Produced by a three-design panel and a judge; checked against branch `m2a`.

---

## 0. Decision in one paragraph

Three append-only tables in `public`: `ledger_account`, `ledger_entry` and `ledger_posting`. Their names come from the DOMAIN glossary, plus four small reference tables. Every write goes through `SECURITY DEFINER` functions in `private`, executable by `service_role` only.

Integrity is enforced in four ways, and each one also holds for the owner role and under `session_replication_role = replica`:
- `ENABLE ALWAYS` append-only triggers.
- One `ENABLE ALWAYS` deferred check per entry: line count, zero sum per currency, receivable/owner-claim mirror, reversal mirror.
- `ENABLE ALWAYS` set-based statement guards.
- A `line_count` closure: once an entry has passed its check, no line can be added to it.

Opening balances are posted **at confirmation, not at commit**, by a **background worker job** (new batch state `confirming`). Commit computes the same opening plan with the same SQL function and checks it against the data-quality (DQ) report, so rollback stays the existing hard delete.

The equality "Σ opening = DQ reconciled total" (M2-05) becomes a database invariant, checked three times: at staging (Python), at commit (SQL plan) and at posting (SQL ledger). It also needs six fixes to M1 boarding; without them the equality is false today.

---

## 1. Panel scores

Each criterion is scored out of 10. The weighted total uses: correctness 25 %, the five other criteria 15 % each.

| Criterion | D1 integrity | D2 scale | D3 audit |
|---|---|---|---|
| Correctness of invariants | **9.5** — line_count closure; ALWAYS guards; reversal mirror; freeze; reconciliation at commit and confirm | 7 — insert guards and the balance check are ORIGIN (replica mode skips them); txid closure; drops conflicting duplicates (keeps the first) instead of refusing them | 8.5 — declarative composite FKs; ALWAYS balance check; reversal multiset check; the xid8 closure can be forged by the owner (D3 says so itself) |
| Fit with existing code | 7.5 — private functions, uuid; but 9 copied columns per posting and synchronous confirm | 6.5 — bigint ids break the uuid convention and push cents/ids through JS numbers; DOMAIN names, definer read RPCs | 8 — matches the worker/queue pattern; but adds a new `ledger` schema |
| Performance 50k → 1M | 6 — ~10 s at 50k, synchronous, above PostgREST's 8 s | **9.5** — ~3.8 s at 50k, ~92 s at 1M, measured | 6.5 — ~11–12 s at 50k (many FKs), but the async job makes it harmless for the UI |
| Tests for the acceptance criteria | **9.5** | 8 | 9 |
| Fit for M2b/M3 | 7.5 — per-item 1100; per-claim 3100; copied columns are hard to evolve | 5.5 — no claim_item dimension (per-invoice allocation and €40 left for later re-tagging); future components hard-coded in a CHECK | **9.5** — per-item 1100; owner+portfolio 3100; entry types with allowed books (CPCE-02 hook); engine metadata; async confirm |
| Simplicity | 5 — many triggers, copied columns, freeze and delete guards | **8** | 6 — 3 reference tables, 14 components seeded, gross opening lines |
| **Weighted total** | **7.7** | **7.4** | **8.1** |

**What the synthesis keeps from each design**
- **D3 (the skeleton):**
  - Grain: 1100 per (claim_item × component), 3100 pooled per (owner × portfolio × component × currency).
  - Asynchronous confirmation with a `confirming` state.
  - `ledger_entry_type.allowed_books`.
  - Composite FK from `ledger_account` to `account`, which freezes the tenant and currency.
  - Custom `LG0xx` SQLSTATEs.
  - Static test against raw ledger DML.
  - Statement-timeout test in the scale run.
  - Fixes to kind precedence and derived refs.
- **D1 (integrity mechanics):**
  - `line_count` closure.
  - ALWAYS statement guards over transition tables.
  - Reconciliation at commit **and** at posting.
  - Idempotency key unique per organization, plus request hash.
  - `known_at`.
  - Only the components needed now are seeded.
  - The list of M1 gaps.
  - Catalog checks on `tgenabled = 'A'`.
- **D2 (performance):**
  - No per-row FKs on `ledger_posting`; one set-based guard instead.
  - Statement-level append-only triggers.
  - SECURITY DEFINER read RPCs with an explicit check, plus private twins for the worker.
  - Set-based opening built from temp tables (no `ANALYZE` of shared tables).
  - Names from the DOMAIN glossary.
- **Rejected:**
  - bigint ids (D2).
  - A new `ledger` schema (D3): `private` already plays that role.
  - Copied tenant columns on postings (D1).
  - Gross opening lines (original and seller_paid as two lines, D3).
  - Reversal of a reversal (D1).
  - xid8 closure (D3).
  - ORIGIN-only guards (D2).

---

## 2. Naming: how the three source documents are reconciled

| Concept | ROADMAP | ADR-0006 / ARCH §8 | DOMAIN §2.1 / §3.5 | **Chosen** | Why |
|---|---|---|---|---|---|
| Header | `journal_entry` | `ledger_entry` | `ledger_entry` | **`ledger_entry`** | 3 of 4 sources agree |
| Line | `posting` | `ledger_line` | `ledger_posting` | **`ledger_posting`** | DOMAIN is the glossary (CLAUDE.md); matches ROADMAP's "posting"; `ledger_` prefix like its siblings |
| Accounts | `ledger_account` | ledger account code | `ledger_account` | **`ledger_account`** | all sources agree |
| Value date | `effective_date` (M2-03) | `value_date` | `effective_date` | **`effective_date`** | ROADMAP + DOMAIN |
| Booking time | — | `booked_at` | `posted_at` | **`posted_at`** | DOMAIN |
| Books | — | descriptive names + numbers | `debtor_receivable`, `owner_claim`, `unallocated_payment`, `client_payable`, `servicer_revenue`, `client_money_cash`, `own_cash` | **DOMAIN codes + ARCH numbers** | glossary codes; the number is kept as `account_number` |
| Reverse command | `ledger.reverse(entry_id)` | — | — | SQL `private.ledger_reverse`, Python `collectoo_worker.ledger.reverse` | `private` is the existing internal schema; the ROADMAP name is the Python API |
| Tenant columns | — | `client_org_id` | `client_organization_id` | **`client_organization_id`** | the existing code uses it |

Record all of this in **ADR-0012**, which amends ADR-0006. Align ROADMAP M2-01/02/05, ARCHITECTURE §6 and §8, and DOMAIN §2.1, §3.5 and §4.4 in the same PR.

---

## 3. Key decisions and rationale

1. **Post opening balances at confirmation.** All three designs agree.
   - Ledger rows can never be deleted. If openings were posted at commit:
     - every rollback would become 50k reversal entries plus "void" accounts kept forever;
     - `unique (portfolio_id, external_ref)` would have to become partial, and the "already boarded" skip at staging would need rework;
     - every account query would need a `status <> 'void'` filter;
     - claims would enter the books before the R124-3 mandate check.
   - Confirmation is the step that makes claims serviced (founder: "commit stays fully reversible"), so the books only ever hold claims under an active mandate.
   - Dates: `effective_date = cut_off_date` and `posted_at` = confirmation time, so balances "as of" a date are the same as if posting had happened at commit.
   - Review still sees what will be posted: commit stores `boarding_batch.opening_plan`, built by the same function that does the posting.
2. **Confirmation runs in the background** (new state `confirming`).
   - Measured: 6–12 s for 50k loans, minutes for 1M. The web calls `confirm_boarding_batch` through PostgREST, where the `authenticated` role's `statement_timeout` (8 s on Supabase) applies. A `SET` inside the function cannot extend it.
   - Today confirm takes ~1.7 s at 50k. Posting synchronously would break the UI confirm at the size CI tests. The scale test does not catch this, because it calls the function after `SET ROLE`, which does not apply role settings.
   - So the RPC checks rights and the mandate, then enqueues a job. The worker posts the openings, updates the accounts and confirms, all in one queue transaction.
3. **Grain.**
   - `debtor_receivable` (1100): one ledger account per **(claim_item, component)**; currency = the account's currency.
     - This follows founder decision #4 (invoices are items): Code civil 1342-10 allocation between debts, the €40 per invoice (OQ-6) and M3 per-item accrual all need it.
     - EU loans use their single `loan_principal` item, which stands for "the loan".
   - `owner_claim` (3100): **pooled** per (servicer, client, owner, portfolio, component, currency).
     - Per claim it would only ever be −1100 (no information) and would double `ledger_account` rows.
     - The pooled form gives a meaningful "amount owed to the owner" per portfolio.
     - Every entry must move 1100 and 3100 by opposite amounts per (component, currency): the per-entry mirror check.
     - This departs from ARCH §8's "account × component" and is recorded in ADR-0012.
   - **One opening entry per account.** Lines in order: Dr 1100 per (item, component), then one Cr 3100 per component.
4. **Integrity model.**
   - Structural invariants: ALWAYS triggers, so they also hold for the owner (`postgres`, the worker's login) and in replica mode.
   - Business-state rules (no posting on a staged account, no future date, the batch must be `confirming`): checked in the writing functions. Only these functions write the tables.
   - Residual risk: the owner can still use DDL (disable a trigger, drop a table). The catalog test asserts `tgenabled = 'A'`; follow-up: a non-owner login role for the worker (the intent of ADR-0011).
5. **FK policy for performance.**
   - High-volume tables (`ledger_account`, `ledger_posting`): declarative FKs only towards *mutable/deletable parents outside the ledger* (`account`, `claim_item`). These FKs make rollback unable to delete ledger history and freeze the account's tenant and currency.
   - Every other reference and coherence rule: one set-based ALWAYS statement trigger per table.
   - Measured by the panel: posting FKs cost 3.9 s of 5.8 s at 50k.
   - Ledger parents are append-only, so an FK's delete protection and row lock add nothing for references inside the ledger.
   - `ledger_entry` (one row per event) keeps ordinary FKs.
6. **Ids are uuid** (DOMAIN convention), so the web never handles bigint ids. `ledger_posting` has no surrogate key: primary key `(entry_id, line_no)`.
7. **No change_log triggers on the three ledger tables.** They are immutable and record their own actor, `posted_at` and idempotency key; logging them would double write volume. This is a documented exception to the DoD in ADR-0012. The reference tables do get change_log.
8. **Reversal of a reversal is refused.** To undo a correction, post a new entry. "In force" then simply means "not reversed".

---

## 4. DDL plan

Two forward-only migrations, after `20261108160000`.

### 4.1 `supabase/migrations/20261108170000_ledger.sql` (M2-01 … M2-03)

```sql
-- Reference data ---------------------------------------------------------------------------
create table public.currency (
  code char(3) primary key check (code ~ '^[A-Z]{3}$'),
  minor_exponent smallint not null check (minor_exponent between 0 and 4),
  label_fr text not null);
insert into public.currency values
  ('EUR', 2, 'Euro'), ('USD', 2, 'Dollar des États-Unis'), ('GBP', 2, 'Livre sterling'), ('CHF', 2, 'Franc suisse');
-- Boarding converts with ×100: only exponent-2 currencies are accepted (validation `unsupported_currency`).

create table public.ledger_book (
  code text primary key,
  account_number text not null unique,                                   -- ARCHITECTURE §8
  label_fr text not null,
  dimension text not null check (dimension in ('claim', 'owner', 'client', 'pooled')),
  money_of text not null check (money_of in ('owner', 'client', 'servicer')),   -- R124-2 segregation
  normal_side smallint not null check (normal_side in (1, -1)),
  client_visible boolean not null);
insert into public.ledger_book values
  ('debtor_receivable',   '1100', 'Créance sur le débiteur',          'claim',  'owner',    1,  true),
  ('owner_claim',         '3100', 'Créance du titulaire',             'owner',  'owner',   -1,  true),
  ('unallocated_payment', '4710', 'Encaissements à imputer',          'client', 'client',  -1,  true),
  ('client_payable',      '4670', 'Sommes dues au mandant',           'client', 'client',  -1,  true),
  ('servicer_revenue',    '7060', 'Commissions',                      'client', 'servicer',-1,  true);
-- M2b inserts client_money_cash 5120 / psp_clearing 5121 / own_cash 5122 / psp_fees 6270
-- together with their bank_account_id dimension (fail closed: not seeded now).

create table public.ledger_component (
  code text primary key,
  family text not null check (family in ('principal', 'interest', 'indemnity', 'charge', 'cost', 'unclassified')),
  eba_field text,
  sort_order smallint not null unique,
  label_fr text not null,
  reference text not null);
insert into public.ledger_component values
  ('principal',        'principal',    '3.09', 10, 'Principal',                                  'claim_item amount; EU template 3.09'),
  ('accrued_interest', 'interest',     '3.10', 20, 'Intérêts échus déclarés par le cédant',      'EU template 3.10'),
  ('other_balances',   'unclassified', '3.11', 30, 'Autres sommes déclarées par le cédant',      'EU template 3.11'),
  ('balancing_line',   'unclassified', '3.12', 90, 'Écart au solde légal déclaré',               'EU template 3.12; founder decision 2026-11-07 #6');
-- late_interest, b2b_flat_indemnity, statutory_indemnity, recovery_fee … arrive with M3 and their guards (CPCE-09, INT-05).

create table public.ledger_entry_type (
  code text primary key,
  label_fr text not null,
  allowed_books text[],                 -- null = reversal: same books as the reversed entry
  requires_reason boolean not null);
insert into public.ledger_entry_type values
  ('opening',    'Solde d''ouverture', array['debtor_receivable', 'owner_claim'], false),
  ('adjustment', 'Correction',         array['debtor_receivable', 'owner_claim', 'unallocated_payment', 'client_payable'], true),
  ('reversal',   'Contre-passation',   null, true);
-- servicer_revenue is only reachable by M2c 'commission' entries (CPCE-02 / M2-12); M2b adds receipt/allocation/...

-- Keys the ledger needs on existing tables -----------------------------------------------------
alter table public.account add constraint account_ledger_key
  unique (id, organization_id, client_organization_id, portfolio_id, currency);
alter table public.claim_item add constraint claim_item_account_key unique (id, account_id);

-- Ledger accounts ------------------------------------------------------------------------------
create table public.ledger_account (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,                     -- servicer tenant
  book text not null,
  currency char(3) not null,
  client_organization_id uuid,
  owner_organization_id uuid,                        -- owner_claim only (phase C ready)
  portfolio_id uuid,
  account_id uuid,
  claim_item_id uuid,
  component text,
  created_at timestamptz not null default now(),
  -- declarative: tenant/currency of a claim ledger account = its account's, forever (freezes them);
  -- an account or item with ledger history can never be deleted (rollback safety). MATCH SIMPLE is
  -- enforced because the shape check makes every column non-null for debtor_receivable.
  constraint ledger_account_claim_fk foreign key (account_id, organization_id, client_organization_id, portfolio_id, currency)
    references public.account (id, organization_id, client_organization_id, portfolio_id, currency),
  constraint ledger_account_item_fk foreign key (claim_item_id, account_id) references public.claim_item (id, account_id),
  constraint ledger_account_shape check (case book
    when 'debtor_receivable' then account_id is not null and claim_item_id is not null and component is not null
      and client_organization_id is not null and portfolio_id is not null and owner_organization_id is null
    when 'owner_claim' then account_id is null and claim_item_id is null and component is not null
      and client_organization_id is not null and owner_organization_id is not null and portfolio_id is not null
    when 'client_payable' then client_organization_id is not null and portfolio_id is null and account_id is null
      and claim_item_id is null and component is null and owner_organization_id is null
    when 'unallocated_payment' then portfolio_id is null and account_id is null and claim_item_id is null
      and component is null and owner_organization_id is null              -- client null = not yet identified
    when 'servicer_revenue' then client_organization_id is not null and portfolio_id is null and account_id is null
      and claim_item_id is null and component is null and owner_organization_id is null
    else false end));                                                     -- unknown/unseeded book: refused
create unique index ledger_account_receivable_uq on public.ledger_account (claim_item_id, component);
  -- only 1100 rows have claim_item_id (nulls distinct): the 1100 key; also serves claim_item delete RI checks
create unique index ledger_account_pooled_uq on public.ledger_account
  (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component)
  nulls not distinct where claim_item_id is null;
create index ledger_account_account_idx on public.ledger_account (account_id);   -- account delete RI + queries
create index ledger_account_client_idx on public.ledger_account (client_organization_id, book) where portfolio_id is null;

-- Entries -------------------------------------------------------------------------------------
create table public.ledger_entry (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  client_organization_id uuid,                       -- an entry concerns at most one client
  portfolio_id uuid,
  account_id uuid references public.account (id),   -- the one claim account its claim lines touch
  entry_type text not null references public.ledger_entry_type (code),
  effective_date date not null,                      -- business date, Europe/Paris
  posted_at timestamptz not null default now(),
  line_count integer not null check (line_count between 2 and 100000),
  idempotency_key text not null check (idempotency_key ~ '^[A-Za-z0-9:._#-]{8,200}$'),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  reverses_entry_id uuid references public.ledger_entry (id),
  boarding_batch_id uuid references public.boarding_batch (id),
  source_type text, source_id text,
  reason text check (reason is null or length(btrim(reason)) between 1 and 2000),
  engine_version text, rule_pack_version_id uuid,    -- FK to rule_pack_version added in M3
  inputs_hash text check (inputs_hash ~ '^[0-9a-f]{64}$'),
  actor_id uuid default auth.uid(),
  actor_label text default nullif(current_setting('app.actor', true), ''),
  constraint ledger_entry_idempotency_uq unique (organization_id, idempotency_key),
  constraint ledger_entry_reversal_shape check ((entry_type = 'reversal') = (reverses_entry_id is not null)),
  constraint ledger_entry_reason check (entry_type not in ('adjustment', 'reversal') or reason is not null),
  constraint ledger_entry_opening_shape check (entry_type <> 'opening' or (account_id is not null and boarding_batch_id is not null)),
  constraint ledger_entry_scope check ((account_id is null or portfolio_id is not null)
                                       and (portfolio_id is null or client_organization_id is not null)),
  constraint ledger_entry_engine check ((engine_version is null) = (inputs_hash is null)));
create unique index ledger_entry_reversed_once_uq on public.ledger_entry (reverses_entry_id) where reverses_entry_id is not null;
create unique index ledger_entry_one_opening_uq on public.ledger_entry (account_id) where entry_type = 'opening';
create index ledger_entry_account_idx on public.ledger_entry (account_id, effective_date);
create index ledger_entry_batch_idx on public.ledger_entry (boarding_batch_id) where boarding_batch_id is not null;
create index ledger_entry_client_idx on public.ledger_entry (client_organization_id, effective_date);

-- Postings (no FKs: the ALWAYS guard verifies the references set-based; parents are append-only) ---
create table public.ledger_posting (
  entry_id uuid not null,
  line_no integer not null check (line_no between 1 and 100000),
  ledger_account_id uuid not null,
  amount_minor bigint not null check (amount_minor <> 0
    and amount_minor between -1000000000000000 and 1000000000000000),   -- + debit / − credit
  currency char(3) not null,                         -- = ledger_account.currency (guard)
  effective_date date not null,                      -- = entry.effective_date (guard); index-only as_of scans
  primary key (entry_id, line_no));
create index ledger_posting_balance_idx on public.ledger_posting (ledger_account_id, effective_date) include (amount_minor);
```

**Triggers.** All use `language plpgsql set search_path = ''` and are invoker, not definer. Every guard and the append-only triggers are `ENABLE ALWAYS`.

```sql
-- (a) Append-only. Statement-level: one firing per statement (zero cost per row), and it also
-- fires for ON CONFLICT DO UPDATE and TRUNCATE ... CASCADE.
create function private.ledger_append_only() returns trigger ... raise exception
  'ledger: % on % refused (append-only; correct with a reversal)', tg_op, tg_table_name using errcode = 'LG000';
-- for t in ledger_account, ledger_entry, ledger_posting:
create trigger <t>_append_only before update or delete or truncate on public.<t>
  for each statement execute function private.ledger_append_only();
alter table public.<t> enable always trigger <t>_append_only;
-- reference tables (currency, ledger_book, ledger_component, ledger_entry_type): labels may change by migration
create trigger <r>_keys_frozen before delete or truncate or update of code on public.<r>
  for each statement execute function private.ledger_append_only();   -- ENABLE ALWAYS too

-- (b) Statement guards over transition tables (AFTER INSERT ... REFERENCING NEW TABLE AS new_rows)
-- private.ledger_account_guard(): book exists; component exists for claim/owner books; currency in public.currency;
--   debtor_receivable: claim_item.currency = account.currency;
--   owner_claim/client books: client is a client of organization_id (organization.servicer_organization_id),
--   portfolio belongs to (organization_id, client_organization_id); owner organization exists.   -> LG002
-- private.ledger_entry_guard(): client belongs to the servicer; portfolio belongs to (org, client); account belongs to
--   portfolio; reversal: target exists, same org/client/portfolio/account, same line_count, is not itself a reversal,
--   effective_date >= target.effective_date.                                                       -> LG002 / LG003
-- private.ledger_posting_guard(): one join of new_rows -> ledger_entry e, ledger_account la, ledger_entry_type t:
--   entry exists; line_no <= e.line_count (CLOSURE); account exists; n.currency = la.currency;
--   n.effective_date = e.effective_date; la.organization_id = e.organization_id;
--   la.client_organization_id is null or = e.client_organization_id;
--   la.portfolio_id is null or = e.portfolio_id; la.account_id is null or = e.account_id;
--   t.allowed_books is null or la.book = any(t.allowed_books).                                     -> LG002

-- (c) Balance check: ONE deferred event per entry (not per line), ALWAYS
create constraint trigger ledger_entry_balanced after insert on public.ledger_entry
  deferrable initially deferred for each row execute function private.ledger_entry_verify();
alter table public.ledger_entry enable always trigger ledger_entry_balanced;
```

`private.ledger_entry_verify()`:
```sql
  select coalesce(sum(n), 0), min(currency) filter (where s <> 0) into v_lines, v_cur
  from (select currency, count(*) n, sum(amount_minor) s from public.ledger_posting
        where entry_id = new.id group by currency) x;
  if v_lines <> new.line_count then raise 'ledger: entry % has % of its % lines' using errcode = 'LG001'; end if;
  if v_cur is not null then raise 'ledger: entry % is not balanced in %' using errcode = 'LG001'; end if;
  -- receivable/owner-claim mirror: 1100 and 3100 move by opposite amounts per (component, currency)
  select la.component || ' ' || p.currency into v_bad from public.ledger_posting p
    join public.ledger_account la on la.id = p.ledger_account_id
    where p.entry_id = new.id and la.book in ('debtor_receivable', 'owner_claim')
    group by la.component, p.currency having sum(p.amount_minor) <> 0 limit 1;
  if found then raise 'ledger: entry % breaks the receivable/owner-claim mirror (%)' using errcode = 'LG001'; end if;
  -- reversal: line by line, same ledger account, amount negated
  if new.reverses_entry_id is not null and exists (
     select 1 from (select line_no, ledger_account_id, amount_minor from public.ledger_posting where entry_id = new.id) r
     full join (select line_no, ledger_account_id, amount_minor from public.ledger_posting where entry_id = new.reverses_entry_id) o
       using (line_no)
     where r.ledger_account_id is distinct from o.ledger_account_id or r.amount_minor is distinct from -o.amount_minor)
  then raise 'ledger: reversal % does not mirror entry %' using errcode = 'LG003'; end if;
  return null;
```

**Why closure is airtight:**
- Lines can never be updated or deleted.
- The guard keeps every `line_no` within `1..line_count`, and the primary key `(entry_id, line_no)` keeps them distinct.
- The check requires the number of lines to equal `line_count`.
- So once the check has passed (at COMMIT, or after `SET CONSTRAINTS … IMMEDIATE`), every slot is taken and any new line conflicts on the primary key. This holds even for the owner and in replica mode.
- A deferred event fired inside a savepoint that is rolled back fires again at COMMIT (verified by D1).

**Error codes.** All carry the stable prefix `ledger:`. Custom SQLSTATEs are verified catchable in plpgsql and exposed as `.sqlstate` in psycopg.

| SQLSTATE | Meaning |
|---|---|
| LG000 | append-only |
| LG001 | unbalanced, incomplete, or mirror broken |
| LG002 | scope or coherence (tenant, client, account, book not allowed for the entry type) |
| LG003 | reversal (mismatch, already reversed, reversing a reversal, date) |
| LG004 | idempotency key reused for a different request |
| LG005 | opening ≠ DQ |
| LG006 | invalid request (amount format, future date, staged account, reserved type, missing owner period) |

### 4.2 `supabase/migrations/20261108180000_ledger_opening.sql` (M2-05 + boarding integration)

```sql
alter table public.boarding_batch
  add column opening_plan jsonb,             -- set at commit: {"EUR": {"accounts": n, "outstanding_minor": "…", "components": {...}}}
  add column opening_summary jsonb,          -- set at posting: entries, postings, totals (amounts as text)
  add column confirm_requested_by uuid references public.app_user (id),
  add column confirm_requested_at timestamptz;
alter table public.boarding_batch drop constraint boarding_batch_status_check;   -- + 'confirming'
alter table public.boarding_batch add constraint boarding_batch_status_check check (status in (
  'draft', 'uploaded', 'profiled', 'mapping_proposed', 'mapping_approved', 'transformed', 'needs_fix',
  'validated', 'staged', 'committed', 'confirming', 'confirmed', 'rolled_back', 'abandoned'));
-- private.boarding_transition_allowed(): + ('committed','confirming'), ('confirming','confirmed'),
--   ('confirming','committed'); remove ('committed','confirmed').
-- private.queue_transform_after_approval(): + status 'confirming' -> pgmq.send('boarding', {type:'confirm', batch_id}).

-- Opening source amounts are frozen once the account is workable (the ledger opening derives from them).
create trigger claim_item_frozen before update of account_id, kind, ref, original_minor, seller_paid_minor, currency
  on public.claim_item for each row execute function private.claim_item_frozen();   -- LG002 unless account.status = 'staged'
-- (account tenant columns and currency are frozen by ledger_account_claim_fk.)
```

Functions in this migration: see §5.3. Replacements: `commit_boarding_batch`, `confirm_boarding_batch`, `rollback_boarding_batch`, `boarding_transition_allowed`, `queue_transform_after_approval`.

---

## 5. Functions and their security

Shared rules:
- `set search_path = ''`; every name is schema-qualified.
- SECURITY DEFINER functions are owned by `postgres`.
- `private.*` functions are gated by their EXECUTE grant, as `private.transition_batch` is today.
- `public.*` RPCs run an explicit check first (ADR-0011).

### 5.1 Write path (`private`, SECURITY DEFINER, EXECUTE to `service_role` only)

**`private.ledger_post(p_organization_id uuid, p_entry_type text, p_effective_date date, p_idempotency_key text, p_lines jsonb, p_meta jsonb default '{}') returns table (entry_id uuid, created boolean)`**

Inputs:
- `p_entry_type`: `'adjustment'` only in M2a. `opening` and `reversal` are reserved and refused with LG006. M2b/M3 add more types.
- `p_lines`: an array of 2…100000 objects of the form `{book, amount_minor, currency, claim_item_id?, component?, client_organization_id?}`.
  - `amount_minor` must be `jsonb_typeof = 'number'` with text matching `^-?[0-9]{1,16}$` and be non-zero. This refuses `1.0` and `1e2`.
- `p_meta`: `{account_id?, reason?, source_type?, source_id?, engine_version?, rule_pack_version_id?, inputs_hash?}`.

Steps:
1. **Derive the scope; never trust the caller's tenant columns.** For claim lines, `p_meta.account_id` is required, and the account gives org, client, portfolio and currency.
   - Each `debtor_receivable` line names a `claim_item_id` of that account, and its currency must equal the account's.
   - `owner_claim` lines give only `component`. Owner and portfolio come from the `claim_ownership_period` that covers `effective_date`; there must be exactly one, otherwise LG006.
   - Client lines: `client_organization_id` must be a client of the servicer.
   - The entry's client is the account's client, or the single client found in the lines. More than one → LG002.
2. **Business-state rules (LG006):**
   - `effective_date <= (now() at time zone 'Europe/Paris')::date`;
   - claim lines are refused while `account.status = 'staged'`;
   - claim lines must have `effective_date >=` the account's servicing start (min `claim_ownership_period.valid_from`, which is the cut-off).
3. **Fail-fast pre-checks** (the deferred trigger is the backstop): per-currency sum, mirror, reason when the type requires one.
4. **Get or create ledger accounts:**
   - 1100: `insert … on conflict (claim_item_id, component) do nothing`.
   - Others: `on conflict (organization_id, book, currency, client_organization_id, owner_organization_id, portfolio_id, component) where claim_item_id is null do nothing`.
   - Then select the ids.
   - Verify early that ON CONFLICT inference works with the NULLS NOT DISTINCT partial index on PG17. Fallback: one full NULLS NOT DISTINCT unique constraint over all dimension columns (D1).
5. **Request hash:** `request_hash = encode(sha256(convert_to(jsonb_build_object('type', …, 'effective_date', …, 'account_id', …, 'source', [type,id], 'reason', …, 'engine', […], 'lines', jsonb_agg(jsonb_build_array(ledger_account_id, currency, amount_minor) order by ledger_account_id, amount_minor))::text, 'UTF8')), 'hex')`. Lines are sorted, so line order does not change the hash. The jsonb text form is canonical.
6. **Insert the entry:** `insert into ledger_entry … on conflict (organization_id, idempotency_key) do nothing returning id`.
   - No row returned → read the existing entry. Same hash → return `(id, false)`. Different hash → LG004.
   - Under READ COMMITTED, a concurrent insert with the same key waits, then sees the winner's row.
7. **Insert all postings in ONE statement** (`line_no` = ordinality). Return `(id, true)`.

**`private.ledger_reverse(p_entry_id uuid, p_idempotency_key text, p_reason text, p_effective_date date default null) returns table (entry_id uuid, created boolean)`**

- An existing key that targets the same entry → `(id, false)`. Otherwise:
  - target missing → LG003;
  - target is a reversal → LG003;
  - reason missing → LG006;
  - `effective_date` = `coalesce(p_effective_date, target.effective_date)`; it must be ≥ the target's date (LG003) and ≤ Paris today. The default nets the pair to zero in every as-of view; `posted_at` keeps the knowledge history.
- Insert the header: type `reversal`, `reverses_entry_id` = target, same scope, same `line_count`, `request_hash = sha256('reversal|'||target||'|'||effective_date)`.
- Then insert `ledger_posting` rows `select line_no, ledger_account_id, -amount_minor, currency, effective_date from target`.
- A second reversal under another key hits `ledger_entry_reversed_once_uq` → caught and raised as LG003 `ledger: entry % is already reversed by %`.
- No `FOR UPDATE`: the unique index serialises concurrent reversals.

### 5.2 Read path (M2-03)

**Private versions** (`language sql stable`, EXECUTE to `service_role`; the worker uses these):
- `private.ledger_balance(p_ledger_account_id uuid, p_as_of date, p_known_at timestamptz default null) returns bigint`
- `private.account_balances(p_account_id uuid, p_as_of date, p_known_at timestamptz default null) returns table (claim_item_id uuid, component text, currency char(3), balance_minor bigint)`. Book `debtor_receivable`.
- `private.client_money_balances(p_client_organization_id uuid, p_as_of date, p_known_at timestamptz default null) returns table (currency char(3), unallocated_minor bigint, payable_minor bigint, held_minor bigint)`.
  - Books with `money_of = 'client'` and `client_organization_id = p`.
  - Credit-normal liabilities are shown as positive money held: `−Σ`.
  - M2b property: Σ held over clients + unidentified 4710 = Σ 5120 + Σ 5121.

Common semantics:
- Postings with `effective_date <= p_as_of` are included.
- With `p_known_at` set, only postings whose entry has `posted_at <= p_known_at` count: "the books as they looked on day T", needed for reproducible M2c statements.
- Sums are cast `::bigint`. `sum(bigint)` returns numeric, so an overflow raises instead of wrapping.
- Without `p_known_at`, the queries are index-only scans on `ledger_posting_balance_idx`.

**Public versions** (same names and signatures; `p_as_of date default null` → `(now() at time zone 'Europe/Paris')::date`). SECURITY DEFINER, explicit check first, EXECUTE to `authenticated`:
- `public.account_balances`: `private.can_read_portfolio(account.portfolio_id)`, otherwise 42501.
- `public.ledger_balance`: the same predicate as the `ledger_account_read` policy, applied to that row, otherwise 42501.
- `public.client_money_balances`: `private.can_read_client_data(org.servicer_organization_id, p_client)`, otherwise 42501.
- The web reads amounts as text (`select=…,balance_minor::text`), following the M1e rule that cents never pass through a JS number.

### 5.3 Opening balances and boarding commands

**`private.opening_lines(p_batch_id uuid) returns table (account_id uuid, claim_item_id uuid, component text, currency char(3), amount_minor bigint, sort_key text)`**

- `language sql stable`, invoker, no grant. It is the single SQL definition of the opening, used by commit (plan) and by posting.
- Civil and commercial items (`kind <> 'loan_principal'`): one `principal` line per item.
  - `amount = (case when kind = 'credit_note' then -original_minor else original_minor end) - seller_paid_minor`
  - `sort_key = coalesce(due_date::text, '9999-12-31') || ':' || ref`
- EU loans: `account ⋈ claim_item(kind='loan_principal') ⋈ eba.t3_loan (boarding_batch_id = p, f3_01_loan_identifier = external_ref)`, as a hash join. `cross join lateral (values …)` only expands columns of the joined row; it is not a correlated lookup.

| Component | Amount (minor units) |
|---|---|
| `principal` | `coalesce(f3_09,0)*100` |
| `accrued_interest` | `coalesce(f3_10,0)*100` |
| `other_balances` | `coalesce(f3_11,0)*100` |
| `balancing_line` | `claim_item.original_minor - (coalesce(f3_09,0)+coalesce(f3_10,0)+coalesce(f3_11,0))*100`, signed |

- `numeric(20,2) × 100` is integral, so the bigint cast is exact.
- Callers filter out zero lines.

**`private.check_opening_sources(p_batch_id uuid)`** raises LG006 when:
- an EU account has a number of `t3_loan` rows other than 1;
- `loan_principal.original_minor ≠ f3_12 × 100`;
- a claim_item's currency ≠ its account's currency;
- a currency is not in `public.currency` with exponent 2;
- a credit note has `seller_paid_minor > 0`.

**`private.opening_plan_totals(p_batch_id uuid) returns jsonb`** → `{"EUR": {"accounts": n, "outstanding_minor": "…", "components": {"principal": "…", …}}}`. Amounts are text, as in the DQ report. Accounts with only zero lines are counted under `"accounts_without_balance"`.

**`private.assert_opening_matches(p_batch_id uuid, p_totals jsonb)`** raises LG005 `ledger: opening balances do not reconcile with the data-quality report (EUR: … vs …)` when:
- the totals differ from `dq_report #> '{staging,opening,currencies}'`, per currency and per component;
- or that key is missing: the batch was staged before M2a, so abandon and re-board it.

**`private.post_opening_balances(p_batch_id uuid) returns jsonb`** (definer, no grant; called only from `complete_batch_confirmation`):
1. Batch `for update`; checks:
   - status = `confirming`;
   - `cut_off_date` not null and ≤ Paris today;
   - no `ledger_entry` with this `boarding_batch_id` yet.
2. `set constraints public.ledger_entry_balanced deferred`. Headers are inserted before lines.
3. `create temp table _open on commit drop as` = `opening_lines` (non-zero lines) joined with:
   - `account`, for org, client, portfolio and currency;
   - the `claim_ownership_period` covering the cut-off, for the owner (exactly one per account, else LG006).

   Then `analyze _open` (temp table only: no locks on shared statistics).
4. Insert the 1100 ledger accounts (distinct item × component) and the pooled 3100 accounts (distinct org, client, owner, portfolio, component, currency), each with `on conflict do nothing`, then map their ids into temp tables.
5. Insert one `ledger_entry` per account with lines:
   - type `opening`, `effective_date = cut_off_date`;
   - `idempotency_key = 'opening:'||batch||':'||account`;
   - `line_count` = number of 1100 lines + number of components;
   - `request_hash` (the same canonical form, set-based);
   - `boarding_batch_id`, `source_type = 'boarding_batch'`, `source_id = batch`;
   - `actor_id = batch.confirm_requested_by`, `actor_label = 'worker:boarding'`.
6. ONE `insert into ledger_posting … union all …`:
   - 1100 lines: `line_no = row_number() over (partition by account order by sort_key, component.sort_order)`, amount `+a`;
   - then one 3100 line per component, `line_no` continuing, amount `−Σ`.
7. Recompute Σ of the posted 1100 lines per currency and component. Call `assert_opening_matches` against `staging.opening`, and check equality with `boarding_batch.opening_plan`.
8. `set constraints public.ledger_entry_balanced immediate; … deferred` so a failure surfaces here, with its message, instead of at COMMIT.
9. Write `opening_summary`: `{effective_date, entries, postings, accounts_without_balance, currencies: {EUR: {outstanding_minor, components}}}`. Return it.
10. Above 200k accounts, steps 4–6 run in chunks of 100k accounts per statement inside the same transaction. This bounds the per-statement FK and trigger event queues.

**`public.commit_boarding_batch(uuid, text)`** (replaced; existing checks kept, plus):
- `cut_off_date` must be not null and ≤ Paris today (23514).
- The claim_item insert **loses `on conflict … do nothing`**: a duplicate (account, kind, ref) now raises 23505 loudly instead of dropping a row silently.
- At the end:
  - `perform private.check_opening_sources(batch)`;
  - `v := private.opening_plan_totals(batch)`;
  - `perform private.assert_opening_matches(batch, v)`;
  - `update boarding_batch set opening_plan = v`.
- No ledger rows are written at commit.

**`public.confirm_boarding_batch(uuid)`** (same signature):
- Existing checks unchanged: `has_role(admin, ops_manager)` at aal2, status `committed`, active mandate. The mandate date is switched to the Paris date.
- Then `confirm_requested_by = auth.uid()`, `confirm_requested_at = now()`, `transition_batch(…, 'confirming', 'confirmation requested')`. The status trigger enqueues `{type: 'confirm'}`.
- Returns in milliseconds.

**`private.complete_batch_confirmation(p_batch_id uuid) returns text`** (definer, EXECUTE to `service_role`; runs inside the worker's queue transaction, so it happens exactly once):
- Batch `for update`. Status ≠ `confirming` → return `'skipped'` (safe on redelivery, including two concurrent deliveries).
- Mandate no longer active at Paris today → `transition_batch(…, 'committed', 'mandat inactif (CPCE R124-3)')`, return.
- Otherwise:
  - `perform private.post_opening_balances(batch)`;
  - `update account set status = 'awaiting_first_letter' where boarding_batch_id = batch and status = 'staged'`;
  - `transition_batch(…, 'confirmed', 'confirmed', 'worker:boarding')`;
  - return `'confirmed'`.

**`public.rollback_boarding_batch(uuid, text)`**:
- Deletes unchanged. It still requires `committed`, so it is refused while `confirming`.
- New first check: `if exists (select 1 from public.ledger_entry where boarding_batch_id = p) then raise LG002`.
- Backstop: the FKs from `ledger_account`/`ledger_entry` to `account`/`claim_item` (NO ACTION, indexed) make deleting anything with ledger history fail with 23503.

### 5.4 Grants and privileges

```sql
revoke all on public.currency, public.ledger_book, public.ledger_component, public.ledger_entry_type,
  public.ledger_account, public.ledger_entry, public.ledger_posting from public, anon, authenticated, service_role;
  -- foundations only revoke anon/authenticated by default; Supabase also grants ALL to service_role
grant select on (the 7 tables) to authenticated, service_role;
revoke delete, truncate on public.ledger_account, public.ledger_entry, public.ledger_posting from postgres;
-- NOT revoked from the owner: UPDATE (FK row locks FOR KEY SHARE need it: posting/rollback RI checks run as the
-- child table's owner; verified by D2 and D3). The ALWAYS trigger refuses every UPDATE. INSERT stays: the definer
-- functions are owned by postgres. Documented in ADR-0012 so nobody "hardens" it and breaks FKs.
grant execute on function private.ledger_post(...), private.ledger_reverse(...), private.complete_batch_confirmation(uuid),
  private.ledger_balance(...), private.account_balances(...), private.client_money_balances(...) to service_role;
grant execute on function public.ledger_balance(...), public.account_balances(...), public.client_money_balances(...)
  to authenticated;
-- opening_lines / opening_plan_totals / assert_opening_matches / check_opening_sources / post_opening_balances: no grants.
```

### 5.5 RLS (read only; no insert/update/delete policies)

```sql
alter table <all 7> enable row level security;
create policy <ref>_read on public.<currency|ledger_book|ledger_component|ledger_entry_type> for select to authenticated
  using ((select auth.uid()) is not null);

-- One init-plan per query instead of a per-row SECURITY DEFINER call (300k-row tables):
create function private.readable_portfolio_ids() returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(p.id), '{}') from public.portfolio p
  where (p.organization_id = any (private.staff_org_ids()) or p.client_organization_id = any (private.client_org_ids()))
    and private.can_read_portfolio(p.id) $$;          -- equivalent by construction (+ pgTAP equivalence test)
grant execute on function private.readable_portfolio_ids() to authenticated;

create policy ledger_account_read on public.ledger_account for select to authenticated using (
  portfolio_id = any ((select private.readable_portfolio_ids()))
  or (portfolio_id is null and organization_id = any ((select private.staff_org_ids())))
  or (portfolio_id is null and client_organization_id = any ((select private.client_org_ids()))
      and book in (select b.code from public.ledger_book b where b.client_visible)));
create policy ledger_entry_read on public.ledger_entry for select to authenticated using (
  portfolio_id = any ((select private.readable_portfolio_ids()))
  or (portfolio_id is null and organization_id = any ((select private.staff_org_ids())))
  or (portfolio_id is null and client_organization_id = any ((select private.client_org_ids()))));
create policy ledger_posting_read on public.ledger_posting for select to authenticated using (
  exists (select 1 from public.ledger_account la where la.id = ledger_posting.ledger_account_id));  -- inherits account RLS
-- Debtor scope (account_party -> debtor_party_ids) comes with the portal (M5).
```

Catalog test 001 stays green: RLS on every table, SELECT-only grants, no `true` policy, pinned search_path.

---

## 6. Python API (`worker/src/collectoo_worker/ledger/`, mypy --strict, no floats)

**`model.py`** (pure, no I/O)
- Enums:
  - `class Book(StrEnum)`: the 5 seeded books.
  - `class Component(StrEnum)`: principal, accrued_interest, other_balances, balancing_line.
  - `class EntryType(StrEnum)`: OPENING, ADJUSTMENT, REVERSAL.
- `BOOKS: Mapping[Book, BookSpec(dimension, money_of)]`. A pytest compares it with `public.ledger_book` (same drift pattern as `targets.json`).
- `@dataclass(frozen=True, slots=True) class Line`:
  - Fields: `book`, `amount_minor: int`, `currency: str`, `claim_item_id: UUID | None = None`, `component: Component | None = None`, `client_organization_id: UUID | None = None`.
  - `__post_init__` checks:
    - `type(amount_minor) is int`, which refuses bool, float, Decimal and numpy ints;
    - amount ≠ 0 and |amount| ≤ 10**15;
    - currency matches `^[A-Z]{3}$`;
    - dimension shape per `BOOKS`.
- `@dataclass(frozen=True, slots=True) class EntryDraft`:
  - Fields: `organization_id`, `entry_type`, `effective_date: date`, `idempotency_key`, `lines: tuple[Line, ...]`, `account_id: UUID | None = None`, `reason`, `source_type`, `source_id`, `engine_version`, `rule_pack_version_id`, `inputs_hash`.
  - `validate()` checks:
    - 2 ≤ number of lines ≤ 100 000;
    - key matches `^[A-Za-z0-9:._#-]{8,200}$`;
    - balanced per currency (`UnbalancedEntry`);
    - mirror per (component, currency) over the claim books (`MirrorBroken`);
    - `account_id` present when there are claim lines;
    - reason present for ADJUSTMENT.
- Helpers: `mirror(lines)` returns the lines negated, in the same order; `balance_by_currency(lines)`.
- `PostResult(entry_id: UUID, created: bool)`. `Balance(claim_item_id, component, currency, balance_minor: int)`.
- Errors: `LedgerError` is the base class.

  | Exception | SQLSTATE |
  |---|---|
  | `AppendOnlyViolation` | LG000 |
  | `UnbalancedEntry`, `MirrorBroken` | LG001 |
  | `ScopeError` | LG002 |
  | `ReversalError` (incl. `AlreadyReversed`) | LG003 |
  | `IdempotencyConflict` | LG004 |
  | `OpeningMismatch` | LG005 |
  | `InvalidRequest` | LG006 |

  `from_db_error(exc)` maps them by `exc.sqlstate`.

**`db.py`** (psycopg 3). It never commits: everything runs inside the caller's transaction, such as the queue job's, so ledger effects are exactly-once together with `job_run`.
- `post(conn, draft) -> PostResult`: calls `draft.validate()`, then `select entry_id, created from private.ledger_post(%s,%s,%s,%s,%s,%s)`. Lines are passed as `Jsonb`; Python ints stay JSON integers, which is exact.
- `reverse(conn, entry_id, *, idempotency_key, reason, effective_date=None) -> PostResult`. This is ROADMAP's `ledger.reverse`.
- `account_balances(conn, account_id, *, as_of=None, known_at=None) -> list[Balance]`.
- `ledger_balance(...) -> int`.
- `client_money_balances(conn, client_id, *, as_of=None, known_at=None) -> dict[str, ClientMoney]`.
- `verify_pending(conn)`: runs `set constraints public.ledger_entry_balanced immediate`, then `deferred`. It fails fast inside a handler or test.

**`opening.py`** (pure; the single Python formula, mirrored by `private.opening_lines`)
- `item_outstanding(kind, original_minor, seller_paid_minor) -> int`.
- `eba_components(p309, p310, p311, p312: Decimal | None) -> dict[Component, int]`:
  - `money.to_minor_units` (ROUND_HALF_UP = ties away from zero = Postgres `numeric` rounding);
  - nulls count as 0;
  - the balancing line is signed;
  - zeros are dropped.
- `expected_opening(staged) -> {currency: {accounts, outstanding_minor, components}}`, computed from the staged claim_item frames and the T3 frame after deduplication and the re-boarding skip.

**Static guard.** `tests/test_no_raw_ledger_dml.py` fails if any module under `worker/src` contains `insert into public.ledger_`, `update public.ledger_` or `delete from public.ledger_`. The worker's login role owns the tables, so this is its only DML barrier short of triggers.

**Jobs** (`jobs/boarding.py`):
- New message type `confirm` → `select private.complete_batch_confirmation(%s)`.
- `record_dead_job` for `confirm`:
  - sets `failed_job`;
  - `transition_batch(batch, 'committed', 'échec de la confirmation: …')` when the batch is still `confirming`.
- Redelivery is safe: the batch row lock is taken first and the status check makes the job a no-op.

---

## 7. Opening balances: mapping, timing, reconciliation

### 7.1 Mapping

| Claim | Ledger account (1100) | Component | Amount |
|---|---|---|---|
| invoice / rent_period / instalment / judgment_head | per claim_item | `principal` | `original − seller_paid` (may be negative if overpaid: debtor in credit, posted signed) |
| credit_note | its own claim_item | `principal` | `−original` (negative; not netted against an invoice, which M2b allocation decides). `seller_paid > 0` on a credit note → blocking `credit_note_paid` |
| EU loan (one dossier per loan) | the loan's `loan_principal` item | `principal` | 3.09 |
| | | `accrued_interest` (family interest, kept apart from the principal base so 1343-1 and INT-06 still apply) | 3.10 |
| | | `other_balances` (unclassified) | 3.11 |
| | | `balancing_line` (unclassified, signed) | 3.12 − (3.09 + 3.10 + 3.11), with missing components counted as 0 |

- The counterpart is one Cr `owner_claim` line per component (pooled ledger account per owner × portfolio × component × currency).
- The sum of an EU loan's components is exactly 3.12 (founder decision #6).
- If a tape gives only 3.12, the whole balance shows as `balancing_line`, visibly flagged.
- Not boarded: late penalties, the €40 indemnity and legal interest. M3 accrues them from the cut-off, each with its legal reference.
- T5 collection history is not posted: it is already reflected in 3.12, and it stays in Layer 1 for re-export.

### 7.2 Timing and dates
- `effective_date = boarding_batch.cut_off_date`, the same date as `claim_ownership_period.valid_from`. Commit requires it and refuses a future date; the upload form already requires it.
- `posted_at` = confirmation time. `actor_id` = the staff member who requested the confirmation.
- Accounts whose opening is zero on every component get no entry. They are counted as `accounts_without_balance` in `opening_plan` and `opening_summary` (M4 guardrail: no letter when the balance is ≤ 0).

### 7.3 Reconciliation chain (M2-05 as an invariant)

```
DQ report (transform)          reconciliation.computed.currencies[c].outstanding_minor   (tape as delivered)
   │  stage_batch (Python) asserts:  computed = staging.opening + staging.skipped          (fails the job → failed_job)
   ▼
dq_report.staging.opening      {currencies: {c: {accounts, outstanding_minor, components}}}, skipped: {c: {...}}
   │  commit (SQL) asserts:  opening_plan_totals(committed rows) = staging.opening        (LG005, nothing committed)
   ▼
boarding_batch.opening_plan
   │  confirmation (SQL) asserts:  Σ posted 1100 per currency/component = opening_plan = staging.opening   (LG005)
   ▼
ledger (opening entries)
```

- There are two independent implementations (Polars at staging, SQL over Layer 1/Layer 2 at commit and confirmation), and they must agree to the cent.
- On a clean tape (nothing skipped), Σ opening per currency equals the DQ reconciled total literally.
- A mismatch is a bug, never a seller discrepancy, so there is no override. The existing override of the seller's control total is unchanged.

### 7.4 M1 fixes required in this slice (each one makes the equality false today, verified in the code)

1. **One definition of item identity, sign and deduplication**, shared by DQ, validation and staging: a new `boarding/items.py`.
   - Kind precedence: `credit_note` before `rent_period`. Today `stage._civil` turns a credit note that has a period into a positive `rent_period`.
   - Sign: credit notes count −|amount| in DQ. Today DQ sums the raw tape sign, while staging uses `abs()` plus the kind.
   - Item identity: (account, kind, ref).
2. **Conflicting documents are blocking.**
   - New code `conflicting_document`: the same (account, kind, document ref) with a different amount, paid, currency or due date, **across all files of the batch**.
   - Today `duplicate_document` is a per-file warning, and commit's `on conflict (account_id, kind, ref) do nothing` keeps an arbitrary row.
   - The same identity with identical amounts is counted and staged once (warning `duplicate_document`, as today).
   - Commit drops the `on conflict`.
3. **Derived refs that collide** (no document number: `coalesce(doc_ref, period, due_date)`, e.g. rent and charges on two lines for the same month) get a suffix `#2`, `#3`, … in batch order (file order, then row order), across files: rent in one file and the same month's charges in another are two items too. Both are boarded and both are counted (founder question 7). Only a row identical in every mapped value to a row of an earlier file (the same file sent twice) gets the same ref: it is boarded once, with the warning `duplicate_document`.
   - An item with no document number, period or due date has no ref: blocking `missing_required` (target `claim_item.ref`). `private_loan` and `judgment_debt` also require the account reference.
4. **Duplicate EU loan id** (3.01) with different content → blocking `duplicate_loan`. Today DQ counts both rows and staging keeps the first.
5. **One money parser for EU amounts:** `money.to_minor_units` (half-up) in DQ (today `Decimal.to_integral_value`, which is half-even) and in staging (today an unverified Polars `cast(Decimal(38,2))*100`). Values with more than 2 decimals raise the warning `sub_cent_amount` (founder question 4).
6. **Re-boarded accounts:** they are skipped at staging but counted in DQ. Staging now records `staging.skipped` per currency, and the bridge above holds.

Plus:
- `credit_note_paid` (blocking).
- `mixed_currency_account` (blocking; one currency per debtor account). The DB checks it again in `check_opening_sources`.
- `unsupported_currency` (blocking; the worker reads `public.currency` at validation).
- A civil account's currency is the currency of its first staged item (EUR when it has none), so a row without an amount never sets it.
- `duplicate_eba_table` (blocking): two files of a batch for the same EU template table (staging and the cross-file references read one file per table).
- `negative_amount` (blocking) also covers a negative amount paid and a negative legal balance 3.12 (both rejected by `claim_item` checks at commit).
- Every NOT NULL value the commit writes is required at validation: the debtor's name (`private_loan`, `judgment_debt`; EU 1.03 in every conformance mode), 3.01 and 3.12 for every EU loan whatever its claim type, and the T5 `month_offset` column (missing → `missing_required`, not a whole number ≥ 1 → `bad_month_offset`).
- `validation.v1.yaml` → **v2** (spec version recorded in `dq_report.spec_versions`).
- DQ adds `balancing` per currency for EU tapes: Σ 3.09 / 3.10 / 3.11 / balancing, the number of loans with a non-zero balancing line, the number negative, and the number with missing components. A negative balancing line also raises the warning `components_exceed_legal_balance`. This is the "flagged in the DQ report" part of founder decision #6.

### 7.5 Rollback and confirmation interplay

| Batch state | Ledger rows | Rollback | Corrections |
|---|---|---|---|
| committed | none (the posting functions refuse claim lines on `staged` accounts; openings only run while `confirming`) | existing hard delete, guarded (LG002) + FK backstop (23503) | re-board |
| confirming | none until the job commits (one transaction) | refused (status) | wait; on failure the job returns the batch to `committed` with `failed_job` |
| confirmed | openings + later entries | refused (state machine) | `ledger_reverse(opening)` + an `adjustment` entry (a second `opening` is impossible: unique per account) |

Once an account is workable:
- claim_item source amounts are frozen by the `claim_item_frozen` trigger;
- the account's tenant and currency are frozen by `ledger_account_claim_fk`;

so the source of an opening can never drift silently. A portfolio transfer in phase C will be transfer-out / transfer-in entries.

---

## 8. Performance budget

Estimates use the panel's measurements on PG16 with a 4 vCPU VM, applied to this design. Verify them in the scale test.

| Step at 50k EU loans (~145k 1100 accounts, ~290k postings) | Estimate |
|---|---|
| commit: `check_opening_sources` + `opening_plan_totals` (hash joins) | ~0.3–0.5 s extra |
| 1100 ledger accounts (2 composite FKs + unique index + guard) | ~1.5–2.5 s |
| 3100 pooled accounts | negligible |
| 50k entries (4 FKs + guard) | ~0.6–1 s |
| 290k postings (no FKs, one set-based guard) | ~1.5–2 s |
| 50k deferred checks | ~0.8–1.1 s |
| account status update (existing, change_log) | ~1.7 s |
| **confirm job total** | **~6–9 s in the worker; the RPC itself takes milliseconds** |

At 1M loans, expect roughly 2–3 minutes in one worker transaction, chunked in 100k-account statements. The pgmq visibility timeout of 300 s is enough, and a concurrent redelivery blocks on the batch row lock and then exits as a no-op. CI cost: about +10 s on the 50k scale test, keeping the total under 300 s.

---

## 9. Tests per acceptance criterion

pgTAP runs as `postgres`, the owner and the worker's login role; each test asserts it with `is(tableowner, current_user)`. A pgTAP file never commits, so "fails at commit" is shown with `set constraints public.ledger_entry_balanced immediate`. The pytest suite also tests a real COMMIT.

### M2-01: schema and deferred balance check
`supabase/tests/007_ledger.test.sql`, part 1:
- Structure: tables, primary keys, `amount_minor bigint`, `currency char(3)`. The constraint trigger is `tgdeferrable` and `tginitdeferred`. Every guard, append-only, key-frozen and balance trigger has `tgenabled = 'A'`.
- Balanced 4-line entry (1100 + 3100 in EUR) inserted directly as the owner → passes `set constraints immediate`.
- Unbalanced entry (+100 / −99): the inserts `lives_ok`, then `throws_ok(set constraints … immediate, 'LG001')`.
- Balanced in total but not per currency (+100 EUR / −100 USD) → LG001.
- `line_count` 3 with 2 lines → LG001 (`has 2 of its 3 lines`).
- Closure: a balanced entry passes `immediate`; then a 3rd line with `line_no ≤ line_count` → 23505, and with `line_no > line_count` → LG002.
- `amount_minor = 0` → 23514.
- Posting currency ≠ its ledger account's → LG002.
- Posting `effective_date` ≠ its entry's → LG002.
- Ledger account of client B inside an entry of client A → LG002. Claim lines of two accounts in one entry → LG002.
- 1100 moves without the matching 3100 (mirror broken) → LG001.
- Opening entry with a `client_payable` line → LG002 (book not allowed).
- Ledger account shape:
  - 1100 without an item → 23514;
  - unknown or unseeded book (`client_money_cash`) → 23514;
  - 1100 currency ≠ the account's → 23503.
- Under `session_replication_role = replica` (only when `has_parameter_privilege('session_replication_role','SET')`, otherwise `skip`), the unbalanced insert and the orphan posting are still refused.

`worker/tests/test_ledger_integration.py::test_unbalanced_fails_at_commit`: a raw SQL unbalanced insert, then `conn.commit()` raises with `sqlstate == 'LG001'`. This is the literal "fails at commit".

### M2-02: append-only and reversal
`007_ledger.test.sql`, part 2:
- **As `postgres`** (the role the worker uses):
  - `UPDATE` on each of the three tables → LG000.
  - `DELETE` and `TRUNCATE` → 42501 (revoked). The assertion takes the SQLSTATE from a DO block and accepts 42501 or LG000, in case the role is a superuser.
  - Then `grant delete, truncate … to postgres` inside the test, and `DELETE`/`TRUNCATE` → LG000: the trigger holds on its own.
  - `insert … on conflict do update` on `ledger_posting` → LG000.
  - `truncate public.account cascade` → LG000.
  - Replica mode (guarded as above): `UPDATE` → LG000.
- **As `service_role` and as `authenticated`:** insert, update and delete → 42501.
- Reference tables: `delete` and `update … set code` → LG000. A label update is allowed.
- **`private.ledger_reverse`:**
  - Builds the mirror: same `line_count`, each `line_no` on the same ledger account with the amount negated, `reverses_entry_id` set, type `reversal`, reason stored.
  - The pair nets to 0 for every `as_of ≥` the date.
  - Same key again → same id, `created = false`. A new key → LG003 (already reversed).
  - Reversing a reversal → LG003. Effective date before the original's → LG003. No reason → LG006.
  - A hand-inserted "reversal" with a wrong amount → LG003 at `immediate`.
- **`private.ledger_post`:**
  - Same key and same payload → same id, count unchanged.
  - Same key with a different amount → LG004.
  - Lines given in a different order → same hash, same id.
  - `opening` or `reversal` type → LG006.
  - JSON `1.0` → LG006.
  - Claim line on a `staged` account → LG006. Future date → LG006.
- **Catalog:** the ledger write functions are `prosecdef`, pin `search_path`, and are executable by `service_role` only (not by anon, authenticated or public). `has_table_privilege('postgres', 'ledger_posting', 'DELETE')` is false.
- **pytest:** an entry committed in one transaction, then `UPDATE` in another → LG000.

### M2-03: balances
`supabase/tests/008_ledger_balances.test.sql`:
- Entries effective D1 < D2 < D3 plus a reversal effective D2. For every D in `generate_series(D1−1, D3+1)`:
  - `ledger_balance` and `account_balances` equal an independent `select sum(amount_minor) … where effective_date <= D`, per ledger account and per (item, component);
  - this is the acceptance definition.
- The default `as_of` is the Paris date: an entry dated Paris-today is included.
- `p_known_at` earlier than the reversal's `posted_at` → shows the balance before the reversal.
- Client money: an `adjustment` Dr `unallocated_payment` (no client) / Cr `client_payable(A)` of 100 at date D gives `client_money_balances(A, D).held = 100`, `(A, D−1) = 0`, and `(B, D)` no rows.
- Access to the public RPCs:
  - client B's admin on A's account → 42501;
  - staff at aal1 → 42501;
  - a collector restricted to another portfolio → 42501;
  - anon → no EXECUTE.
- RLS isolation:
  - A's admin sees A's rows in `ledger_account`, `ledger_entry` and `ledger_posting`, and none of B's;
  - staff at aal2 see both clients;
  - staff at aal1 see none;
  - the restricted collector sees only its portfolio;
  - a client never sees `unallocated_payment` rows with a null client;
  - anon sees nothing.
- `private.readable_portfolio_ids()` equals `{p | can_read_portfolio(p)}` for every fixture user.

### M2-04: Python API (Hypothesis)
- **`worker/tests/test_ledger_model.py`** (pure, `py` job):
  - Strategies: `balanced_drafts()` (1100/3100 pairs over 1–3 items × components, plus balanced client lines, in 1–3 currencies).
  - Properties:
    - `validate` accepts every generated draft;
    - changing any amount by k ≠ 0, or one line's currency → `UnbalancedEntry`;
    - changing one 3100 component → `MirrorBroken`;
    - bool, float and Decimal amounts are refused;
    - `mirror(mirror(x)) == x`;
    - `balance_by_currency(x + mirror(x))` is all zeros.
  - `RuleBasedStateMachine LedgerMachine` against `tests/ledger_oracle.py` (`InMemoryLedger` with the same rules: (org, key) + hash idempotency, one reversal per entry, no reversal of a reversal, reversal date ≥ original).
    - Rules: `post(key=sampled_from(8 keys))` (forced collisions), `replay_post`, `reverse(random entry, fresh or reused key)`, `replay_reverse`.
    - Invariants after every step:
      - every entry balanced per currency;
      - Σ of all postings per currency = 0;
      - number of entries = number of distinct successful keys (same key ⇒ single entry; different payload ⇒ `IdempotencyConflict`, no new row);
      - for every reversed pair, the net per ledger account is 0 at every `as_of ≥` the date;
      - a double reversal ⇒ `AlreadyReversed`;
      - reversing a reversal ⇒ `ReversalError`.
- **`worker/tests/test_ledger_integration.py`** (integration, `db` job):
  - The same machine against the database: a fresh tenant per example, one transaction rolled back per example, `verify_pending` after every step, and database balances (`account_balances`, `ledger_balance`, `client_money_balances`) = the oracle's. Settings: `max_examples=25`, `stateful_step_count=15`, `deadline=None`.
  - Two connections post the same key at the same time → one row, the same id returned twice.
  - The real-COMMIT tests above.
- **`worker/tests/test_ledger_books_drift.py`:** `BOOKS` = `public.ledger_book`.
- **`worker/tests/test_no_raw_ledger_dml.py`:** the static guard from §6.

### M2-05: opening balances
**`supabase/tests/009_opening_balances.test.sql`.**

Fixture: a batch walked to `staged` with a cut-off date, a mandate and terms, and:
- civil staging rows: invoice 125000 with paid 25000, invoice 50000, credit note 10000, and an invoice paid in full;
- an EU account with a `t3_loan` row (3.09/3.10/3.11, and a 3.12 off by +7 cents);
- `dq_report.staging.opening`.

Checks:
- **Commit:**
  - `opening_plan` = expected per currency and component; 0 ledger rows;
  - tampered `staging.opening` → LG005, nothing committed; missing `staging.opening` → LG005;
  - null or future cut-off → 23514;
  - duplicate (account, kind, ref) in staging → 23505;
  - EU item ≠ 3.12×100 → LG006.
- **Rollback after commit:** accounts deleted, 0 ledger rows.
- **Confirm a second batch:**
  - the RPC → status `confirming`, one `confirm` message in pgmq;
  - `private.complete_batch_confirmation` → `confirmed`, accounts `awaiting_first_letter`;
  - one opening per account with a balance, none for the fully paid account; `effective_date` = cut-off; key `opening:<batch>:<account>`;
  - Σ 1100 per currency and component = `opening_plan` = `staging.opening`;
  - the credit-note line is −10000 on its own item;
  - EU: principal / accrued_interest / other_balances = 3.09 / 3.10 / 3.11, balancing = +7, Σ = 3.12;
  - 3100 = −Σ 1100 per component;
  - `actor_id = confirm_requested_by`;
  - every opening passes `set constraints immediate`;
  - running `complete_batch_confirmation` again → `'skipped'`, counts unchanged.
- **Mandate expired between request and completion:** back to `committed`, 0 ledger rows.
- **`staging.opening` tampered before completion:** LG005, transaction aborted, nothing posted.
- **After confirmation:**
  - rollback refused;
  - `delete from account` → 23503;
  - `update claim_item set original_minor` → LG002;
  - `update account set currency` → 23503;
  - a second opening for the account → 23505;
  - `ledger_post` on an account of another, still-staged batch → LG006.
- Update the fixtures of 005 and 006 (cut-off, `staging.opening`, and the confirm path through `confirming`).

**pytest:**
- `test_opening.py` (unit):
  - `item_outstanding` table cases;
  - `eba_components`: nulls, negative balancing, adjustment only, 4-decimal inputs (half-up);
  - Hypothesis over random civil frames (credit notes, paid, overpaid, exact duplicates, colliding derived refs): `expected_opening + skipped == build_report(...).reconciliation.computed`, per currency.
- `test_validation.py` / `test_stage.py`:
  - `conflicting_document` within a file and across files;
  - `duplicate_loan`, `credit_note_paid`, `mixed_currency_account`, `unsupported_currency`;
  - `sub_cent_amount` warning;
  - a credit note with a period stays a credit note;
  - colliding derived refs → `#2`.
- `test_opening_integration.py` (integration). A synthetic civil b2b tape (credit notes, partly paid, overpaid, rent with two lines per period) and a synthetic EU tape (balancing lines of both signs) go through board → stage → commit → confirm → drain. Then:
  - Σ 1100 opening per currency == `dq_report.reconciliation.computed.currencies[c].outstanding_minor` (the literal acceptance);
  - per component == `staging.opening`;
  - each EU account sums to 3.12;
  - re-boarding the same tape plus new accounts: Σ = computed − skipped;
  - rollback before confirmation leaves 0 ledger rows;
  - a confirm job forced to fail until dead-lettered → `committed` + `failed_job`.
- `test_scale_integration.py` (M1-21 extended):
  - the tenant gets a mandate, terms and an aal2 staff user;
  - the confirm RPC runs under `set local statement_timeout = '8s'`, mimicking PostgREST;
  - drain, then assert: `status = confirmed`, opening entries == LOANS, Σ 1100 == computed outstanding;
  - print the commit and confirm-job seconds; the total stays < 300 s.

**Web** (`apps/web`):
- Status label `confirming` → « Confirmation en cours… », polled like the other worker steps; action buttons are hidden meanwhile.
- French messages for LG005 and LG006 in `actions.ts`.
- Optional « Solde d'ouverture prévu » from `opening_plan` on the review page.
- Playwright E2E updated (confirm → confirmed). Screenshots mobile and desktop under `docs/screenshots/`.
- Regenerate `database.types.ts`.

**Catalog** (`001`): add checks for:
- ALWAYS triggers on the ledger tables;
- `service_role` without INSERT, UPDATE or DELETE on ledger tables;
- `postgres` without DELETE or TRUNCATE on them.

---

## 10. Implementation order and docs

1. Migration `…170000_ledger.sql`, then pgTAP 007 and 008 (plan → tests → code, per the DoD).
2. Python `ledger/model.py`, `db.py`, the oracle and the property tests.
3. M1 fixes (`boarding/items.py`, dq, validate v2, stage, `opening.py`) and their unit tests.
4. Migration `…180000_ledger_opening.sql` + pgTAP 009 + updates to 005 and 006.
5. Worker `confirm` job + integration tests + scale test.
6. Web `confirming` state + E2E + screenshots.
7. Docs:
   - **ADR-0012** (amends ADR-0006): naming, opening at confirmation, async confirm, grain (per-item 1100, pooled 3100), FK/guard policy, ALWAYS triggers, owner keeps UPDATE, no change_log on ledger tables, LG SQLSTATEs, no reversal of a reversal.
   - **ARCHITECTURE** §6 (sequence: commit without ledger; confirming job posts), §8 (tables, books, mirror invariant), §15 (restore runbook: physical backup/PITR; a data-only logical restore must use `--single-transaction`, because the ALWAYS balance check needs an entry and its lines in one transaction).
   - **DOMAIN** §2.1 (books), §3.5 (ER: new components, `adjustment`), §4.4 (`confirming`; Commit, Rollback and Confirm rows).
   - **ROADMAP:** M2-01 names; M2-02 `private.ledger_reverse` / `collectoo_worker.ledger.reverse`; M2-05 "confirmed batches".
   - **COMPLIANCE:** CPCE-03 (check at request and at completion), CPCE-02 (client-money books, `servicer_revenue` only via commission entries), CPCE-09 (`recovery_fee` not seeded until M3-05), the new OQ for founder question 5.
   - **PROGRESS.**

---

## 11. Open questions for the founder (each with a default)

Short form for the chat: "1 ok, 2 ok, …". Question 5 also goes to COMPLIANCE.md as a counsel open question.

1. **Post opening balances when a batch is confirmed**, not when it is committed. Rollback stays a clean delete; ROADMAP M2-05 wording is amended. *Default: yes.*
2. **Confirmation runs in the background.** The batch shows « Confirmation en cours… » for a few seconds (minutes for 1M loans); this avoids the 8 s API limit. *Default: yes.*
3. **New blocking tape anomalies:**
   - the same document number twice for one debtor with different amounts (also across files);
   - the same EU loan id twice with different content;
   - a paid amount on a credit note;
   - several currencies in one debtor account;
   - a currency other than EUR/USD/GBP/CHF.

   *Default: all blocking.*
4. **EU amounts with more than 2 decimals:** rounded half-up to the cent (the ADR-0006 rule), with a DQ warning, rather than refused. *Default: round + warning.*
5. **Consumer credit:** the seller's 3.11 "other balances" and the balancing line are booked as declared and flagged, and kept out of the R124-4 first letter until ops reclassify them. INT-05 allows only listed charges, and R124-4 3° requires the "fondement" of each amount (counsel). *Default: yes.*
6. **Credit notes and overpaid invoices** stay as negative items; netting against invoices is decided with allocation in M2b. Accounts with a zero or credit balance are confirmed but flagged (no letter, M4). *Default: yes.*
7. **Rent tapes with several lines for the same month and no document number** (rent + charges): kept as separate items, not summed. *Default: separate items.*

Accounting choices recorded in ADR-0012, for the founder's information (no decision needed):
- the owner's counterpart (3100) is kept per owner × portfolio × component rather than per claim;
- the ledger tables carry their own audit fields instead of change_log.

---

## 12. Risks and follow-ups (not in M2a)

1. **Commit through PostgREST at 50k+** can already exceed the 8 s `statement_timeout` (latent since M1d; the scale test bypasses it with `SET ROLE`). Follow-up: an async commit job using the same pattern. The scale test prints the commit time.
2. **The worker logs in as the table owner.** DDL (`DISABLE TRIGGER`, `DROP`) cannot be stopped by triggers. Mitigations: catalog `tgenabled = 'A'` checks, the static DML guard, migration review. Follow-up: a dedicated non-owner worker login role with EXECUTE on `private.ledger_*` only (the intent of ADR-0011).
3. **The per-entry mirror invariant** forces M2b allocation to post its cash and claim legs in one entry (as in ARCH §8). This is intended; document it in ADR-0012.
4. **Negative item balances** (credit notes, overpaid, negative balancing): the M2-09 waterfall must skip items at or below zero and decide netting. M3 per-item interest bases must ignore negative items.
5. **Pooled 3100** must be moved explicitly on a phase-C ownership transfer (transfer-out / transfer-in entries). An invariant query `3100(owner, portfolio, component) = −Σ 1100 of the claims owned` belongs in a nightly check (M2b).
6. **Restricted collectors and client-money rows:** staff at aal2 see client-dimension ledger rows of their servicer. Decide in M2b, when real client-money postings start, whether to restrict them to admin and ops_manager.
7. **GDPR:** ledger rows can never be deleted, so they must hold ids only (no personal data). Erasure pseudonymises parties. The retention period for ledger and client-money records goes to counsel.
8. **Reversal default date** = the original's date, so past as-of balances change after a correction. M2c statements and receipts must use `known_at` or frozen snapshots so issued documents stay reproducible.
