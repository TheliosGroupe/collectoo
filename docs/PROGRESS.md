# Progress

_Updated at every commit. New sessions: read `CLAUDE.md`, `docs/BRIEF.md`, then this file._

## Done
- M0 complete 2026-11-08: PRs #2–#6 merged (tooling/CI, tenancy/RLS, auth/MFA, two-layer schema, synth + seed).
- PR #4 M0b-auth merged 2026-11-08 (email-code login, TOTP MFA, route gating, E2E vs local stack in CI).
- PR #3 M0b-db merged 2026-11-08 (tenancy, RLS helpers, token hook, command pattern, 42 pgTAP checks).
- PR #2 M0a merged 2026-11-08 (monorepo, tooling, CI 5 jobs green, session hook).
- Phase 0 step 0: brief saved verbatim in `docs/BRIEF.md`.
- `main` created from the brief commit (founder approval). Personal cloud environment `collectoo`: EU/BAN hosts allowed, setup script + `SUPABASE_INTERNAL_IMAGE_REGISTRY=docker.io` saved (unproven until a fresh session starts on it).
- Step 2: EU NPL sources downloaded (EUR-Lex EN/FR HTML+PDF, EBA Excel annexes + final report), see `docs/reference/SOURCES.md`.
- Step 3: field catalogue (135 fields), JSON Schema model, Excel-vs-EUR-Lex diff (`tools/eba_catalogue/build_catalogue.py`); gap analysis; PRODUCT, DOMAIN, CALCULATION_RULES, CHANNELS, ARCHITECTURE, COMPLIANCE, ADRs 0001–0011, CLAUDE.md, ROADMAP, CLOUD_ENV.
- Step 4: flags and over-scope in `docs/PHASE0_REVIEW.md`. All 22 Mermaid diagrams validated with mermaid-cli 11.4.2.
- Local check: Supabase CLI 2.122.1 + local stack start in ~2 min (cold) / ~35 s (cached).

## In progress
- PR "M1a — boarding upload, worker runtime, readers, profiling" (M1-01…M1-05): boarding_batch/file/event + state machine enforced in the DB, upload commands (client admins self-serve, staff ops), Storage upload policy limited to registered paths, `boarding` queue + DLQ; worker: pgmq consumer with exactly-once effects (job + ack in one transaction), retries/backoff/dead-letter, CSV/XLSX/fixed-width readers (encoding + separator sniffing, streaming), column profiling that detects every injected defect pattern; integration tests run in the CI db job.

## Next
- M1b mapping (target registry, LLM gateway + mock, proposals, eval suite, mapping profiles), M1c transformations/validation/DQ report, M1d staging/commit/review UI/scale tests.

## Decisions
- Debtor data is scoped per client organization (party.client_organization_id): no cross-client debtor merge, each client stays controller of its data. Template fields without an operational column live in `source_attributes` so tapes can be regenerated.
- Login = email one-time code only (no magic link) for all users; accounts created by invitation (`shouldCreateUser: false`). Next.js `cacheComponents` turned off (simpler per-user auth pages).
- 2026-11-08: Claude merges its own PRs when all CI jobs are green (founder approval); founder reviews afterwards.
- M0a: Next.js 16.4.3 (system fonts, no Google Fonts fetch), Python 3.12 via uv, Playwright pinned 1.63.0, vitest 4.0.18 (4.1.x hits an npm resolver crash); Supabase local stack with Studio/analytics/edge runtime/realtime disabled; shadcn/ui components added when first needed.
- Work branch is `claude/loving-clarke-u1b205` (the branch this cloud session can push to) instead of `phase-0`.
- Kickoff answers (2026-11-07): frontend Vercel (EU region); worker Scaleway (fr-par); first segment SMB B2B invoices; M3 rule packs = consumer instalment loan, professional loan, B2B invoice, B2C invoice; MVP digital-first with minimal collector workspace; PSP = Stripe (test mode); email/SMS via Brevo (cheaper than Twilio for FR SMS: ~EUR 0.045 vs ~USD 0.08); golden examples later (worked examples TO VALIDATE meanwhile); pace = as fast as possible.
- Founder decisions 2026-11-07 (full list: `docs/PHASE0_REVIEW.md` §D): Stripe main rail (needs Stripe written approval before go-live); R124-4 letter in M4; purchased claims accepted in phase A (counsel to confirm licence); 1 account per (client, debtor) with invoice items; 1 dossier per loan; deceased → collect against heirs; insolvency hold only on proof (BdF admissibility / court judgment); 10-day plan grace; recall → forward payments; template-mandatory = warnings; WABA per brand; Vercel + DPF; Brevo declare + standby; cite art. 82 only; no outbound before batch confirmation; out-of-envelope plan: 5 business days then expires; EU export: seller's forbearance only, percentages as ratios; seller balance breakdown handled per seller mapping profile (default aggregates + balancing line).
- Supabase CLI pinned to 2.122.1 (3.0.0 too new). Images pulled from Docker Hub (ECR/GHCR blob hosts blocked).
- EU template catalogue built from EUR-Lex only; Excel used for the diff.

## Open questions
- Hosted Supabase: enable the custom access token hook, TOTP MFA and the French code-only `magic_link` email template (`supabase/templates/magic_link.html`) in the dashboard, or `supabase config push`; migrations alone don't set Auth config.
- Counsel: `docs/COMPLIANCE.md` §9 (OQ-1…17), `docs/CHANNELS.md` §8, `docs/ARCHITECTURE.md` §17; domain questions at the end of `docs/DOMAIN.md`.
- GitHub default branch is still `claude/loving-clarke-u1b205`: switch it to `main` in Settings → Branches.
