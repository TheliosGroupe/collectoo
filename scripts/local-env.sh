#!/bin/bash
# Prints export lines for the local Supabase stack (CLI defaults, not secrets).
# Usage: eval "$(scripts/local-env.sh)"
set -euo pipefail
eval "$(supabase status -o env 2>/dev/null)"
echo "export SUPABASE_URL=\"$API_URL\""
echo "export SUPABASE_SECRET_KEY=\"$SECRET_KEY\""
echo "export DATABASE_URL=\"$DB_URL\""
echo "export NEXT_PUBLIC_SUPABASE_URL=\"$API_URL\""
echo "export NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=\"$PUBLISHABLE_KEY\""
echo "export MAILPIT_URL=\"$MAILPIT_URL\""
