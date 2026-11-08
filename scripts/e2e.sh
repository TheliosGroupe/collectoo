#!/bin/bash
# Runs Playwright against the local Supabase stack (start it first with `make up`).
# Local keys come from `supabase status`; they are the CLI's local defaults, not secrets.
set -euo pipefail
cd "$(dirname "$0")/.."

eval "$(supabase status -o env 2>/dev/null)"
export NEXT_PUBLIC_SUPABASE_URL="$API_URL"
export NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY="$PUBLISHABLE_KEY"
export SUPABASE_SECRET_KEY="$SECRET_KEY"
export MAILPIT_URL="$MAILPIT_URL"
export NEXT_TELEMETRY_DISABLED=1

cd apps/web
npm run build
npm run e2e -- "$@"
