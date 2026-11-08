# ADR-0003: Python worker service, hosted on Scaleway (Paris)

- Status: Accepted (hosting confirmed by the founder on 2026-11-07)
- Date: 2026-11-07

## Context
Heavy and sensitive work (tape ingestion of up to 1M rows, document processing, the calculation engine, the flow executor, channel adapters, provider webhooks, the AI gateway) doesn't fit Edge Functions (memory, CPU and duration limits) and must stay portable. The worker holds all debtor data and the service-role key.

## Decision
- **Python 3.12** with **uv**, one package `collectoo_worker`, one Docker image.
  - Polars/DuckDB for streaming ingestion; `Decimal` for money maths; Hypothesis for property tests; Pydantic for schemas.
- **Hosting: Scaleway fr-par** (French company, EU jurisdiction only, Paris data centres):
  - **Serverless Containers** for `worker-api`: webhooks, privileged commands and the `/v1/drain` executor endpoint. Scale-to-zero.
  - **Serverless Jobs** for long batch work: large tapes, bulk documents, purge, benchmarks.
- The executor is woken over HTTP: pg_cron + pg_net, and provider webhooks. There is no long-running poller, so scale-to-zero works and nothing in the code depends on Scaleway.
- Alternatives considered:
  - TypeScript worker: one language with the web app, but weaker data tooling.
  - Edge Functions: limits, and the brief excludes core logic there.
  - Fly.io: US company.
  - Clever Cloud: French, but more expensive.

## Consequences
- Two languages in the repo (TS for the web app, Python for the worker). Types are shared through generated artefacts (Supabase types, JSON Schemas).
- Avoids US CLOUD Act exposure for the component holding all debtor data, which helps with bank clients.
- Scaleway limits (request timeout, job duration, memory) must be checked before M1. Fallback: a small Scaleway instance running the same image.
