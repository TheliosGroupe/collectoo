# ADR-0006: Double-entry, append-only ledger in integer minor units

- Status: Accepted; implemented and amended by ADR-0012 (names `ledger_entry` / `ledger_posting` / `ledger_account`, grain, enforcement)
- Date: 2026-11-07

## Context
Every number shown to debtors, clients and bailiffs must be explainable. Client money must be kept separate (CPCE R124-2), and disputes need a full history.

## Decision
- `ledger_entry` (header) and `ledger_line` (signed `bigint` minor units + currency). The lines of an entry sum to zero per currency, enforced by a deferred constraint trigger.
- **Append-only:** no UPDATE/DELETE (trigger and revoked privileges). Corrections are reversal entries (`reverses_entry_id`) followed by new entries.
- Idempotency key unique per entry. Engine entries carry `engine_version`, `rule_pack_version` and `inputs_hash`.
- Minimal chart of accounts:
  - claim side: debtor receivable per account × component, mirrored by a claim-counterpart account
  - cash side: client-funds bank, PSP clearing, unallocated receipts, client payable, own bank, commission revenue
- Details in `docs/ARCHITECTURE.md` §8.
- Rates are `numeric` / `Decimal`; rounding happens only when posting (half-up to the cent unless the pack says otherwise). No floats anywhere.
- Balances are sums over lines. Any cached balance must be rebuildable and is checked against the lines.

## Consequences
- More rows than a "balance column" design, but every balance is explainable and reproducible.
- Back-dated events become reversal + repost, never edits.
- Writes go only through the worker's posting service or `SECURITY DEFINER` functions (ADR-0011).
