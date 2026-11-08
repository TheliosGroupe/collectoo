# ADR-0012: Ledger implementation (amends ADR-0006)

- Status: Accepted
- Date: 2026-11-08
- Design: `docs/design/m2a-ledger.md` (three-design panel and judge). Founder answers on 2026-11-08: all defaults accepted (see "Founder decisions" below).

## Context
ADR-0006 fixed the principles: double-entry, append-only, integer minor units, corrections by reversal. Implementing them raised naming conflicts between ROADMAP, ARCHITECTURE and DOMAIN, a performance question (opening balances for 50k–1M accounts), and when boarded claims enter the books.

## Decision

### Names
- Tables: `ledger_entry` (header), `ledger_posting` (line), `ledger_account`.
- Dates: `effective_date` (business date, Europe/Paris) and `posted_at` (booking time).
- Books use the DOMAIN codes, with the ARCHITECTURE numbers kept as `account_number`:
  - `debtor_receivable` 1100, `owner_claim` 3100;
  - `unallocated_payment` 4710, `client_payable` 4670;
  - `servicer_revenue` 7060.
  - The cash books (5120/5121/5122, 6270) are seeded with M2b payments. Until then they are refused: fail closed.
- ROADMAP's `ledger.reverse(entry_id)` is the Python `collectoo_worker.ledger.reverse`, over SQL `private.ledger_reverse`.
- `private` stays the internal schema; no new `ledger` schema.

### Grain
- `debtor_receivable` has one ledger account per **(claim item, component)**. This serves per-invoice allocation (Code civil 1342-10), the €40 per invoice and per-item interest in M3.
- `owner_claim` is **pooled** per (servicer, client, owner, portfolio, component, currency). Per claim it would only ever mirror 1100.
- Every entry moves 1100 and 3100 by opposite amounts per (component, currency): the **mirror invariant**, checked at commit. M2b allocation therefore posts its cash and claim legs in one entry, as in ARCHITECTURE §8.

### Integrity (in the database)
- **Append-only:** statement-level `BEFORE UPDATE OR DELETE OR TRUNCATE` triggers on the three ledger tables raise `LG000`.
  - They are `ENABLE ALWAYS`, so they also fire for the table owner (the worker's login role) and under `session_replication_role = replica`.
  - DELETE and TRUNCATE are also revoked from the owner.
  - The owner **keeps UPDATE**: foreign-key row locks (`FOR KEY SHARE`) need it, and the trigger refuses every UPDATE anyway. Do not revoke it.
- **Balance check:** one deferred `ENABLE ALWAYS` constraint trigger per entry checks, at commit:
  - the line count equals `line_count`;
  - the lines sum to zero per currency;
  - the mirror invariant;
  - for a reversal, line-by-line negation of the reversed entry.
- **Closure:** a guard keeps every `line_no` within `1..line_count`, and the primary key `(entry_id, line_no)` keeps them distinct. So once an entry has passed its check, it cannot take another line.
- **Set-based guards:** `AFTER INSERT … FOR EACH STATEMENT` triggers over the transition table, also `ALWAYS`, check references and coherence:
  - book, component and currency;
  - tenant, client, portfolio and account;
  - the books allowed for the entry type;
  - each line's currency and date against its entry.
- **No foreign keys on `ledger_posting`**, for performance: the set-based guard replaces them. `ledger_account` has composite FKs to `account` and `claim_item`. These freeze a claim account's tenant and currency, and make an account with ledger history impossible to delete.
- **Idempotency:** `unique (organization_id, idempotency_key)` plus a canonical `request_hash` (lines sorted). The same key with another request raises `LG004`.
- **Reversals:**
  - an entry is reversed at most once (unique index);
  - a reversal is never reversed (post a new entry);
  - a reversal is never dated before the entry it reverses.
- **Errors:** custom SQLSTATEs, mapped to Python exceptions by `collectoo_worker.ledger.from_db_error`:
  - `LG000` append-only;
  - `LG001` unbalanced, incomplete or mirror broken;
  - `LG002` scope;
  - `LG003` reversal;
  - `LG004` idempotency;
  - `LG005` opening ≠ DQ report;
  - `LG006` invalid request.

### Writes and reads
- **Writes:**
  - `private.ledger_post` and `private.ledger_reverse` are SECURITY DEFINER, with a pinned `search_path`, executable by `service_role` only.
  - `ledger_post` derives the scope itself and never trusts the caller's tenant columns: client and portfolio come from the account, the owner from the ownership history at the effective date.
  - Posting is refused on staged accounts, in the future (Paris date), and before servicing started.
  - `opening` and `reversal` entries cannot be posted through it.
- **Reads:**
  - `private.ledger_balance`, `account_balances` and `client_money_balances` (`as_of`, optional `known_at` for "the books as known at a time").
  - Their `public` twins check access explicitly (ADR-0011).
  - RLS on every ledger table is read-only. It uses one init-plan per query (`private.readable_portfolio_ids()`).
- **No change_log triggers on the three ledger tables:** they are immutable and record their own actor, `posted_at` and idempotency key. The reference tables do have change_log.

### Opening balances (M2-05, PR M2a-2)
- Posted **at batch confirmation, not at commit**, by a background worker job (new batch state `confirming`). This avoids the 8 s API limit at 50k+ accounts.
- Before confirmation a batch is undone by the existing hard delete, so the books only ever hold claims under an active mandate (CPCE R124-3).
- `effective_date` = the batch cut-off date.
- Σ opening balances = the DQ report's reconciled outstanding total, minus the accounts of the tape already in the portfolio (skipped at staging, shown on the batch page). Checked at staging (DQ outstanding = opening + skipped, per currency), at commit (plan = staged opening) and at posting (posted = plan = staged opening).
- A confirmation refused by the ledger (LG00x or a check) is recorded on the batch at once and the batch goes back to `committed`; it is not retried, since it would fail the same way. Other errors are retried by the queue.

## Founder decisions (2026-11-08, all defaults accepted)
1. Opening balances are posted when a batch is confirmed.
2. Confirmation runs in the background.
3. These tape anomalies are **blocking**:
   - the same document number twice for one debtor with different amounts;
   - the same EU loan id twice with different content;
   - a paid amount on a credit note;
   - several currencies in one debtor account;
   - a currency other than EUR/USD/GBP/CHF.
4. EU amounts with more than 2 decimals are rounded half-up to the cent, with a warning.
5. Consumer credit: the seller's 3.11 "other balances" and the balancing line are booked as declared, flagged, and kept out of the R124-4 first letter until ops classify them. This is also an open question for counsel (COMPLIANCE OQ-18).
6. Credit notes and overpaid invoices stay as negative items; netting is decided with allocation (M2b). Zero or credit balances are confirmed but flagged (no letter).
7. Rent lines for the same month without a document number stay separate items.

## Consequences
- **Correction:** every correction is a reversal plus a new entry, and past "as of" balances can change after it. Issued documents (M2c statements, receipts) must use `known_at` or frozen snapshots.
- **`known_at`:** `posted_at` is the time the entry was written (`clock_timestamp()`), and the entry only becomes visible when its transaction commits. "The books as known at T" is therefore reproducible only for a T earlier than the start of every ledger transaction still running. M2c statements will use a stored knowledge watermark rather than "now".
- **Definer functions and the session's temporary schema:** Postgres resolves unqualified table names in `pg_temp` first, even with `search_path = ''`. `private.ledger_post` therefore drops and recreates its working table `pg_temp._ledger_lines` on every call. Reusing one the caller created could run the caller's triggers with the definer's rights. A pgTAP test covers this.
- **Remaining owner risk:** the worker's login role owns the tables, so DDL (disable a trigger, drop a table) cannot be stopped by triggers. Mitigations:
  - a catalog test asserts `tgenabled = 'A'`;
  - a static test refuses raw ledger DML in the worker;
  - migration review.
  - Follow-up: a non-owner login role for the worker.
- **Restore:** a data-only logical restore must run in a single transaction (`--single-transaction`), because the ALWAYS balance check needs an entry and its lines in the same transaction.
