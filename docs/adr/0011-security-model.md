# ADR-0011: Security model — RLS everywhere, writes via the worker or SECURITY DEFINER functions

- Status: Accepted
- Date: 2026-11-07

## Context
Supabase exposes tables through an auto-generated API. One missing policy could leak another tenant's debtors or let a browser write ledger rows.

## Decision
- **RLS enabled on every table in exposed schemas.** Non-exposed schemas (`private`, `eba`, `pgmq`) hold runtime and internal data.
- Policies use helpers in `private`: `can_read_portfolio`, `is_internal`, `has_role`, `is_aal2`, `debtor_party_ids`. They read membership tables (not only JWT claims), so revocation is immediate.
- **Write paths:**
  - Ledger, payments, communications, boarding, flow runtime, holds and mandates: written only by the worker (service role) or `SECURITY DEFINER` RPCs. No insert/update/delete policies for `authenticated`.
  - Direct RLS writes are allowed only on an explicit allow-list of low-risk tables (notes, tasks, user preferences, flow drafts), each with a policy and a pgTAP test.
- `SECURITY DEFINER` functions: `search_path = ''`, an explicit role check first, execute granted only to the intended role.
- The service-role key lives only in the worker and CI. The web app forwards user JWTs to the worker, which verifies them.
- Staff must be at MFA level `aal2` (TOTP) to read anything.
- **pgTAP tests** cover:
  - catalog: every exposed table has RLS and no permissive `true` policy
  - cross-tenant isolation for every table
  - the role matrix
  - forbidden direct writes
  - debtor scoping

## Consequences
- More RPCs to write, but write rules live in one auditable place.
- CI fails if a new table is added without RLS.
