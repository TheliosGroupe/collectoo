# Cloud environment (Claude Code on the web)

The cloud environment for this repo is the personal environment **`collectoo`** (created 2026-11-07).

## Network allowlist

Package registries (npm, PyPI, …) are allowed by default. Extra hosts:

| Host | Why |
|---|---|
| `eur-lex.europa.eu` | Regulation (EU) 2023/2083 (EU NPL template), legal texts |
| `www.eba.europa.eu` | EBA Excel annexes of the NPL ITS |
| `ec.europa.eu` | Commission documents register (fallback only; timed out on 2026-11-07) |
| `api-adresse.data.gouv.fr` | BAN address normalisation (M1 boarding) |
| `www.iso20022.org` | **Not allowed yet** (refused in the M2c-6a session): the pain.001.001.09 and .03 XSDs to vendor in `docs/reference/iso20022/` (its README says which files) |

Already reachable without listing them (checked 2026-11-07): `github.com` release downloads (Supabase CLI), Docker Hub (`registry-1.docker.io`).
**Blocked, and worked around:** image blobs on `public.ecr.aws` (CloudFront) and `ghcr.io` (`pkg-containers.githubusercontent.com`). The Supabase CLI falls back to Docker Hub; we force Docker Hub with `SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io` so no time is lost on retries.

## Setup script (paste into the environment settings)

Runs as root when a fresh container is built. Measured on 2026-11-07: CLI install ≈ 4 s, first image pull ≈ 2 min 15 s (≈ 8.3 GB of images). Total under 3 minutes.

```bash
#!/usr/bin/env bash
set -euo pipefail
SUPABASE_CLI_VERSION=2.122.1
if [ "$(supabase --version 2>/dev/null || true)" != "$SUPABASE_CLI_VERSION" ]; then
  curl -fsSL --retry 4 -o /tmp/supabase.tgz \
    "https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/supabase_linux_amd64.tar.gz"
  tar -xzf /tmp/supabase.tgz -C /usr/local/bin supabase && rm -f /tmp/supabase.tgz
fi
if ! docker info >/dev/null 2>&1; then
  (nohup dockerd >/var/log/dockerd.log 2>&1 &)
  for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
# Pre-pull the Supabase images with a throwaway project.
export SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io
d=$(mktemp -d)
(cd "$d" && supabase init --force >/dev/null && supabase start >/dev/null && supabase stop --no-backup >/dev/null) || true
rm -rf "$d"
```

Notes:
- `service docker start` fails in this container (`ulimit` not permitted), so the script starts `dockerd` directly.
- The Supabase CLI version is pinned. Bump it on purpose, in a PR, after checking the release notes. The 3.x major (released 2026-11-02) is not used yet.
- The image pull is wrapped in `|| true`: a registry hiccup must not stop the session from starting; `supabase start` re-pulls on demand.

## Per-session start (SessionStart hook)

`.claude/settings.json` runs `scripts/session-start.sh` synchronously at every session start/resume. It exits at once unless `CLAUDE_CODE_REMOTE=true`, and:
1. installs the pinned Supabase CLI if missing, and starts `dockerd` if it isn't running;
2. runs `npm install` in `apps/web/` and `uv sync --frozen` in `worker/` **only when** their manifests/lockfiles (or the script) changed: hashes are kept in `apps/web/node_modules/.session-start.sha256` and `worker/.venv/.session-start.sha256`;
3. exports `SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io` and `UV_SYSTEM_CERTS=1` for the session;
4. does **not** start Supabase (≈ 35–60 s from cached images): run `make up` when you need the DB.

Measured 2026-11-08: no-change run ≈ 0.5 s.

## Running services

Nothing survives between sessions. Start what you need:

```bash
export SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io
supabase start          # local stack: API :54321, DB :54322, Studio :54323, Mailpit :54324
supabase db reset       # re-apply migrations + seed
supabase test db        # pgTAP
```
