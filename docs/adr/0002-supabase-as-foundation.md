# ADR-0002: Supabase as the foundation, in Paris, with portability rules

- Status: Accepted
- Date: 2026-11-07

## Context
We need Postgres, auth (with MFA), file storage, queues, cron and row-level security without running infrastructure. Data must stay in the EU. A bank client may later require self-hosting.

## Decision
- Use **Supabase**: Postgres, Auth, Storage, Queues (pgmq), pg_cron, pg_net, Realtime, RLS.
- Hosted project in **`eu-west-3` (Paris)** explicitly, not a generic "Europe" region.
- Dev and CI run the **local Supabase stack** (CLI + Docker). Migrations are forward-only SQL in `supabase/migrations`, applied to production by the Supabase GitHub integration on merge to `main`.
- **Portability rules:** core logic uses plain SQL and standard Postgres extensions (pgmq, pg_cron, pg_net are open source). Supabase-specific parts are limited to Auth (`auth.uid()`, `auth.jwt()`), Storage and Realtime, each wrapped (RLS helpers in `private`, storage access via the worker or signed URLs).
- **Edge Functions:** none in the MVP. Allowed later only for small, short glue tasks, invoked in Paris, with no core business logic.

## Consequences
- One managed dependency for most platform needs; low ops load.
- Moving to self-hosted Supabase or plain Postgres + a separate auth server is possible; the cost sits mainly in Auth and Storage.
- RLS correctness becomes critical and is proven with pgTAP (ADR-0011).
