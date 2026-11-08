#!/bin/bash
# SessionStart hook for Claude Code cloud sessions (see docs/CLOUD_ENV.md).
# Idempotent: each install runs only when a file that decides it has changed.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}"

SUPABASE_CLI_VERSION=2.122.1

# --- Global tools (only what is missing) -------------------------------------
if [ "$(supabase --version 2>/dev/null || true)" != "$SUPABASE_CLI_VERSION" ]; then
  curl -fsSL --retry 4 -o /tmp/supabase.tgz \
    "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_linux_amd64.tar.gz"
  tar -xzf /tmp/supabase.tgz -C /usr/local/bin supabase
  rm -f /tmp/supabase.tgz
fi

# Docker daemon (`service docker start` is not permitted in this container).
if ! docker info >/dev/null 2>&1; then
  (nohup dockerd >/var/log/dockerd.log 2>&1 &)
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi

# --- Web (apps/web) -----------------------------------------------------------
web_hashes=apps/web/node_modules/.session-start.sha256
if ! sha256sum --check --status "$web_hashes" 2>/dev/null; then
  rm -f "$web_hashes"
  (cd apps/web && npm install --no-audit --no-fund)
  sha256sum scripts/session-start.sh apps/web/package.json apps/web/package-lock.json > "$web_hashes"
fi

# --- Worker (worker/) ---------------------------------------------------------
py_hashes=worker/.venv/.session-start.sha256
if ! sha256sum --check --status "$py_hashes" 2>/dev/null; then
  rm -f "$py_hashes"
  (cd worker && uv sync --frozen)
  sha256sum scripts/session-start.sh worker/pyproject.toml worker/uv.lock > "$py_hashes"
fi

# --- Session environment ------------------------------------------------------
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo 'export SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io'
    echo 'export UV_SYSTEM_CERTS=1'
  } >> "$CLAUDE_ENV_FILE"
fi

echo "session-start: deps ready. Run 'make up' to start the local Supabase stack."
