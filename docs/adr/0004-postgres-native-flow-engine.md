# ADR-0004: Postgres-native flow engine (pg_cron + pgmq), no Temporal for the MVP

- Status: Accepted
- Date: 2026-11-07

## Context
Collection flows are long-running (days to months): mostly waits, conditions and one outbound action per step. We need durability, idempotency and visibility, not complex orchestration.

## Decision
- Each account in a flow has a persisted state row `private.flow_run` (current node, `next_run_at`, `step_seq`, context).
- A **pg_cron** tick every minute selects due rows (`FOR UPDATE SKIP LOCKED`), marks them queued, and sends a message to the **pgmq** queue `flow_steps`. It then wakes the worker through `pg_net` (`POST /v1/drain`).
- The worker reads messages with a visibility timeout and runs the node handler through the guardrail gate. The idempotency key is `run_id:node_id:step_seq`. It logs to `private.flow_step_log`, advances the run and archives the message. After N failed reads, the message goes to a dead-letter queue and an ops task is created.
- Waits are just `next_run_at`. Event waits (payment, reply) are resolved by the event handler updating `next_run_at = now()`.

## When to revisit (any one is enough)
- More than ~1M active flow runs, or sustained more than ~100 steps/s, with tick latency over a minute.
- Flows need sub-minute timers, sagas across many external systems with compensation, or long-lived human workflows with complex branching.
- Operating the queue and cron ourselves costs more time than adopting Temporal, Restate or similar.

## Consequences
- No new infrastructure; state is queryable with SQL; simulation reuses the same handlers with a virtual clock.
- One-minute granularity. Throughput is bounded by Postgres; acceptable for the MVP.
