# Progress

_Updated at every commit. New sessions: read `CLAUDE.md`, `docs/BRIEF.md`, then this file._

## Done
- **M1 complete 2026-11-08.** PR #11 M1e merged (back-office boarding review UI; three multi-agent review rounds addressed; CI falls back to a retried Supabase CLI download).
- PR #10 M1d merged 2026-11-08 (staging, commit/rollback/confirm, documents zip, 50k-loan CI run, 1M benchmark: 57 s, 2.9 GB peak). CI was delayed ~1.5 h by GitHub release-download 504s; CI now falls back to a curl install with longer retries.
- PR #9 M1c merged 2026-11-08 (transformation DSL, validators, BAN adapter, claim types, validation rules, DQ report).
- PR #8 M1b merged 2026-11-08 (mapping proposals, LLM gateway + mock, eval 167/167, mapping profiles).
- PR #7 M1a merged 2026-11-08 (boarding upload, queue runtime, readers, profiling).
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
- PR "M2a-1 — ledger core" (M2-01 … M2-04, ADR-0012, design `docs/design/m2a-ledger.md`): `ledger_entry` / `ledger_posting` / `ledger_account` + chart of accounts, components, entry types, currencies; deferred per-entry check at commit (balanced per currency, line count, receivable/owner-claim mirror, reversal mirror); append-only and coherence guards as `ENABLE ALWAYS` triggers (hold for the owner role); `private.ledger_post` (idempotency key + request hash, scope derived from the account and ownership history) and `private.ledger_reverse`; balances as of a date (and as known at a time) with access-checked public twins; read-only RLS. Python `collectoo_worker.ledger` (model, db API, error mapping) with Hypothesis properties and a state machine run against an in-memory oracle and against Postgres.

## Next
- M2a-2: opening balances at batch confirmation (background `confirming` job), the six boarding fixes that make Σ opening = DQ reconciled total, review-screen state, E2E.

## Decisions
- 2026-11-08 ledger (founder: all defaults accepted, ADR-0012): openings posted at confirmation, in the background; blocking anomalies (conflicting duplicate documents, duplicate EU loan ids, paid credit notes, several currencies in one account, unsupported currencies); EU amounts with more than 2 decimals rounded half-up with a warning; consumer credit 3.11 and balancing line booked, flagged, kept out of the first letter (counsel OQ-18); credit notes and overpaid invoices stay negative items; same-month rent lines without a number stay separate.
- M1e reconciliation (founder confirmed 2026-11-08: sellers always stop the portfolio at a cut-off date): the seller's control total is the **outstanding balance at cut-off** (invoice/loan amounts minus what the seller reports as already paid), compared to the cent, plus the number of data rows in the claim files. Totals are kept per currency; a tape with non-euro amounts cannot be reconciled against a euro total (mismatch, reason required to commit). Batches can be abandoned at any step before commit. The upload form requires the cut-off date.
- M1e: back-office copy in French; mapping targets offered in the review come from the worker's registry (`apps/web/src/lib/boarding/targets.json`, a pytest fails if it drifts). Batch amounts are read from the DQ report as text (`->>`) so integer cents never pass through a JS number.
- M1d: the R124-3 mandate check sits on batch confirmation (accounts become workable), not on commit (data loaded for review, reversible); COMPLIANCE CPCE-03 aligned with DOMAIN §4.4. Re-boarding an account reference already in the portfolio is skipped at staging (listed in the DQ report); updates of existing accounts come with M2 reconciliation.
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
- When a real LLM key is provided: the mapping prompt (v1) must ask for the rationale in French (back-office copy); bump it to v2 then.
- Hosted Supabase: enable the custom access token hook, TOTP MFA and the French code-only `magic_link` email template (`supabase/templates/magic_link.html`) in the dashboard, or `supabase config push`; migrations alone don't set Auth config.
- Counsel: `docs/COMPLIANCE.md` §9 (OQ-1…17), `docs/CHANNELS.md` §8, `docs/ARCHITECTURE.md` §17; domain questions at the end of `docs/DOMAIN.md`.
- GitHub default branch is still `claude/loving-clarke-u1b205`: switch it to `main` in Settings → Branches.
