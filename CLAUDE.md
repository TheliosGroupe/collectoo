# CLAUDE.md — Collectoo

Receivables and NPL servicing platform, France first. The founder steers from a phone.

## Start of every session

1. Read `docs/BRIEF.md` (source of truth), then `docs/PROGRESS.md`, then this file.
2. Work on the branch the session is assigned to. Never push to `main`.
3. Update `docs/PROGRESS.md` in every commit (done / in progress / next / decisions / open questions).

## Working rules (from BRIEF §0)

- **Chat:** ≤ 10 lines. Questions as a numbered list with a default each ("1 ok, 2 b"). Long content goes in repo files; give the path.
- **Git:** one branch + one PR per slice. PR body: what changed, why, how tested, open questions. CI green before asking to merge. The founder merges.
- **Network:** domain allowlist. If something is blocked, don't work around it: name the exact host. See `docs/CLOUD_ENV.md`.
- **Secrets:** none in the repo (`.env.example` only). Never production credentials. No real LLM keys: mock provider.
- **Migrations:** forward-only, in `supabase/migrations`, applied to prod by Supabase's GitHub integration on merge to `main`. They must pass locally and in CI.
- **UI changes:** commit Playwright screenshots (mobile + desktop) under `docs/screenshots/`.
- **Legal:** implement what the law requires, nothing more. Never invent rules. Unsure → "Open questions" in `docs/COMPLIANCE.md`. Platform policies (WhatsApp…) are business risk, tracked in `docs/CHANNELS.md`.
- **AI Act:** anything that could be high-risk (e.g. creditworthiness scoring of natural persons) → flag to the founder before building.

## Non-negotiables

- Every amount comes from the ledger + calculation engine. LLMs never compute or state amounts, dates or legal mentions.
- Money = integer minor units (`bigint`) + `currency char(3)`. Rates = `numeric` / Python `Decimal`. No floats, anywhere.
- Ledger is double-entry and append-only. Corrections by reversal.
- RLS on every table in exposed schemas. Ledger, payments, communications and boarding tables are written only by the worker (service role) or `SECURITY DEFINER` functions. The service-role key never reaches the browser.
- Rule packs are data (versioned YAML with legal references), not code branches.
- Times stored in UTC; business calendar Europe/Paris.
- Idempotency keys on commands and outbound sends.
- Code in English; debtor-facing copy in French. Glossary: `docs/DOMAIN.md`.
- Never commit real personal data. Use the synthetic generator.

## Repository layout

```
apps/web/                  Next.js + TS + @supabase/ssr + Tailwind/shadcn + React Flow
  app/(backoffice) app/(client) app/(debtor)
worker/                    Python 3.12, uv
  src/collectoo_worker/    api boarding engine ledger payments flows guardrails channels ai decisioning synth
  rule_packs/  evals/  tests/
supabase/                  migrations/ (forward-only)  tests/ (pgTAP)  seed.sql  config.toml
tools/                     dev tooling (eba_catalogue/)
scripts/                   session-start.sh, CI helpers
docs/                      BRIEF, PROGRESS, PRODUCT, DOMAIN, ARCHITECTURE, COMPLIANCE,
                           CALCULATION_RULES, CHANNELS, ROADMAP, CLOUD_ENV, adr/, reference/, screenshots/
```

DB schemas: `public` (exposed, RLS), `private` (internal: flow runtime, audit, rule-pack internals), `eba` (Layer-1 EU template staging/export).

## Commands

```bash
# Environment (cloud): see docs/CLOUD_ENV.md
export SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io
supabase start                  # local stack
supabase db reset               # migrations + seed
supabase test db                # pgTAP
supabase gen types typescript --local > apps/web/lib/database.types.ts

# Worker
cd worker && uv sync && uv run ruff check . && uv run ruff format --check . && uv run mypy src && uv run pytest

# Web
cd apps/web && npm ci && npm run lint && npm run typecheck && npm test && npx playwright test --trace off

# EU template catalogue (regenerate)
uv run --with beautifulsoup4 --with lxml --with openpyxl python -I tools/eba_catalogue/build_catalogue.py .
```

(Commands become real as M0 lands; keep this section in sync with CI.)

## Definition of done (per slice / PR)

- [ ] Plan → tests → code → run, in that order. Tests cover the acceptance criteria in `docs/ROADMAP.md`.
- [ ] Ledger/allocation/interest changes: property-based tests (Hypothesis). Rule packs: golden cases.
- [ ] New tables: RLS policies + pgTAP tenant-isolation tests. Change-log trigger on core tables.
- [ ] New channel adapter: capability descriptor + mock + contract tests.
- [ ] Lint, type-check, tests and `supabase test db` green locally and in CI.
- [ ] Migrations forward-only and applied cleanly with `supabase db reset`.
- [ ] UI: Playwright screenshots (mobile + desktop) committed under `docs/screenshots/`.
- [ ] Docs updated (COMPLIANCE enforcement points, DOMAIN, ADR if a decision was made), `docs/PROGRESS.md` updated.
- [ ] PR description: what, why, how tested, open questions. Short report to the founder (≤ 10 lines).
