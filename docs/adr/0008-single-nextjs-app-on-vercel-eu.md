# ADR-0008: One Next.js app with three surfaces, on Vercel (EU region)

- Status: Accepted (hosting confirmed by the founder on 2026-11-07)
- Date: 2026-11-07

## Context
Three surfaces: back-office (staff), client portal (creditors) and debtor portal (mobile-first). A small team; server functions must run in the EU.

## Decision
- One Next.js (App Router, TypeScript) app in `apps/web` with route groups `(backoffice)`, `(client)`, `(debtor)`.
  - Shared UI kit: Tailwind + shadcn/ui. React Flow for the flow builder.
  - Supabase access through `@supabase/ssr`.
- Hosted on **Vercel**, with functions pinned to **`cdg1` (Paris)**.
- The app uses only the anon key + the user's session. Privileged operations go to the worker with the user's JWT. The service-role key is never in the app.
- Surfaces are separated by middleware (role checks per route group) and by RLS. The debtor portal can move to its own deployment later without code changes.

## Consequences
- One build, one design system, shared types.
- Vercel is a US company. It needs a GDPR chapter V transfer basis in the sub-processor register. If that is refused, the same app can be hosted on Scaleway.
