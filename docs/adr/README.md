# Architecture decision records

| ADR | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-supabase-as-foundation.md) | Supabase as the foundation, in Paris, with portability rules | Accepted |
| [0003](0003-python-worker-on-scaleway.md) | Python worker service, hosted on Scaleway (Paris) | Accepted (hosting confirmed by the founder on 2026-11-07) |
| [0004](0004-postgres-native-flow-engine.md) | Postgres-native flow engine (pg_cron + pgmq), no Temporal for the MVP | Accepted |
| [0005](0005-rule-packs-as-versioned-data.md) | Rule packs as versioned data | Accepted |
| [0006](0006-double-entry-append-only-ledger.md) | Double-entry, append-only ledger in integer minor units | Accepted |
| [0007](0007-channel-adapters-cpaas-vs-direct.md) | Channel adapters with capability descriptors; CPaaS vs direct decided per channel | Proposed (provider choices to be confirmed by the founder per channel) |
| [0008](0008-single-nextjs-app-on-vercel-eu.md) | One Next.js app with three surfaces, on Vercel (EU region) | Accepted (hosting confirmed by the founder on 2026-11-07) |
| [0009](0009-two-layer-data-model.md) | Two-layer data model (EU NPL template layer + operational layer) | Accepted |
| [0010](0010-ai-gateway.md) | Provider-agnostic AI gateway with mocks and eval suites | Accepted |
| [0011](0011-security-model.md) | Security model — RLS everywhere, writes via the worker or SECURITY DEFINER functions | Accepted |
| [0012](0012-ledger-implementation.md) | Ledger implementation: names, grain, ALWAYS triggers, openings at confirmation (amends 0006) | Accepted |
