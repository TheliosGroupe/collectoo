#!/bin/bash
# Runs Playwright against the local Supabase stack (start it first with `make up`).
# Local keys come from `supabase status`; they are the CLI's local defaults, not secrets.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tmp

eval "$(supabase status -o env 2>/dev/null)"
export NEXT_PUBLIC_SUPABASE_URL="$API_URL"
export NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY"
export SUPABASE_SECRET_KEY="$SECRET_KEY"
export MAILPIT_URL="$MAILPIT_URL"
export NEXT_TELEMETRY_DISABLED=1

# The worker consumes the boarding, payments and remittances queues during the run (mock LLM and mock addresses).
(
  eval "$(./scripts/local-env.sh)"
  cd worker
  LLM_PROVIDER=mock ADDRESS_NORMALISER=mock exec uv run collectoo-worker consume boarding payments remittances
) >tmp/e2e-worker.log 2>&1 &
worker_pid=$!
trap 'kill $worker_pid 2>/dev/null || true' EXIT

cd apps/web
npm run build
npm run e2e -- "$@"
