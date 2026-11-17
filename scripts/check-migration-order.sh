#!/usr/bin/env bash
# M2c-6b-2a (plan docs/design/m2c-6b-2-plan.md §2.6; critic2 CSO2-5): production applies migrations in the order they
# merge, and `supabase db push` refuses a migration older than the last one applied (« Found local migration files to be
# inserted before the last migration on remote database »). Fails when a migration file this branch adds sorts before
# the latest migration file of the base (default origin/main), compared by name.
#
#   scripts/check-migration-order.sh [base-ref]
set -euo pipefail

base="${1:-origin/main}"
dir="supabase/migrations"

latest="$(git ls-tree --name-only "$base" "$dir/" | sed "s|^$dir/||" | grep '\.sql$' | sort | tail -n 1)"
if [ -z "$latest" ]; then
  echo "no migration on $base: nothing to compare" >&2
  exit 0
fi
# the files present here and not on the base (two-dot: no merge base needed, a shallow clone suffices)
added="$(git diff --name-only --diff-filter=A "$base" HEAD -- "$dir/" | sed "s|^$dir/||" | grep '\.sql$' | sort || true)"
status=0
for f in $added; do
  if [[ "$f" < "$latest" || "$f" == "$latest" ]]; then
    echo "migration $f sorts before $latest, the latest on $base: rename it with a later timestamp" >&2
    status=1
  fi
done
if [ "$status" -eq 0 ]; then
  echo "new migrations sort after $latest (${added:-none added})"
fi
exit "$status"
