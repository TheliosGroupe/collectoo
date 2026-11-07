# Roadmap

_Phase 0 draft, 2026-11-07. Each task fits in under one day. 🔒 = blocked on founder input; ⚖️ = needs a counsel answer (see `COMPLIANCE.md` §9) before the rule ships._

**Conventions used below**
- Monorepo: `apps/web` (one Next.js app; route groups `(backoffice)`, `(client)`, `(debtor)`), `worker/` (Python 3.12 uv package `collectoo_worker`, with subpackages `boarding`, `engine`, `ledger`, `flows`, `channels`, `ai`, `decisioning`, `synth`), `supabase/` (`migrations/`, `tests/` for pgTAP, `seed.sql`), `tools/`, `docs/`.
- DB schemas: `public` (exposed, RLS on every table), `private` (internal, not exposed), `eba` (Layer 1, EU NPL template).
- "Green CI" means every CI job passes on the PR.
- Every UI task ships Playwright screenshots (mobile and desktop) in `docs/screenshots/`.

---

## PR plan (one branch + one PR per slice)

| PR | Slice | Tasks |
|---|---|---|
| PR-0 | Phase 0 — design docs | (this PR) |
| PR-1 | M0a Repo, tooling, CI, session hook | M0-01 … M0-05 |
| PR-2 | M0b Supabase, auth, tenancy, RLS | M0-06 … M0-11 |
| PR-3 | M0c Two-layer canonical schema | M0-12 … M0-15 |
| PR-4 | M0d Synthetic generator and seed | M0-16 … M0-18 |
| PR-5 | M1a Upload, ingestion, profiling | M1-01 … M1-05 |
| PR-6 | M1b Mapping (mock LLM), eval, profiles | M1-06 … M1-10 |
| PR-7 | M1c Transformations, claim type, validation, DQ report | M1-11 … M1-16 |
| PR-8 | M1d Staging, commit/rollback, review UI, scale tests | M1-17 … M1-22 |
| PR-9 | M2a Ledger | M2-01 … M2-05 |
| PR-10 | M2b Payments, reconciliation, allocation, receipts | M2-06 … M2-11 |
| PR-11 | M2c Remittances, client statements, commission | M2-12 … M2-15 |
| PR-12 | M3a Rate tables, rule-pack format, engine core | M3-01 … M3-06 |
| PR-13 | M3b Rule packs (4 claim types) and golden tests | M3-07 … M3-12 |
| PR-14 | M3c Statement of account (*décompte*) | M3-13 … M3-15 |

---

## M0 — Foundations

| ID | Task | Acceptance criteria | Deps |
|---|---|---|---|
| M0-01 | Monorepo skeleton: `apps/web` (Next.js + TS + Tailwind + shadcn/ui + `@supabase/ssr`), `worker/` (uv project, `collectoo_worker` package), `supabase/`, `tools/`, root `Makefile` (`make setup`, `make up`, `make test`, `make lint`), `.env.example`, `.editorconfig`, `.gitignore` | `make setup` works on a fresh clone; `apps/web` builds; `uv run python -c "import collectoo_worker"` works; no secrets committed | — |
| M0-02 | Python tooling: ruff (lint + format), mypy (strict on `collectoo_worker`), pytest + hypothesis, coverage | `make lint` and `make test` pass on a sample module with one unit test and one property-based test | M0-01 |
| M0-03 | Web tooling: ESLint, `tsc --noEmit`, Vitest, Playwright (Chromium, mobile + desktop projects, `--trace off`), screenshot helper writing to `docs/screenshots/` | `npm run lint`, `npm run typecheck`, `npm test` pass; one Playwright smoke test produces 2 screenshots | M0-01 |
| M0-04 | GitHub Actions CI: jobs `py` (ruff, mypy, pytest), `web` (eslint, tsc, vitest, build), `db` (supabase/setup-cli, `supabase start`, `supabase db reset`, `supabase test db`, check that generated types match), `e2e` (Playwright against the local stack); caching for uv/npm/Docker images | All jobs run on every PR and pass; total wall time ≤ 15 min; failing pgTAP test fails the PR (checked once with a deliberately broken test, then reverted) | M0-02, M0-03, M0-06 |
| M0-05 | SessionStart hook: `.claude/settings.json` → `scripts/session-start.sh`, exits unless `CLAUDE_CODE_REMOTE=true`; idempotently installs the Supabase CLI (pinned version), `uv sync`, `npm ci`; prints `make up` hint. Write `docs/CLOUD_ENV.md` setup script (CLIs + Supabase image pre-pull, < 5 min) | Running the script twice in a row: second run < 30 s and no changes; does nothing locally when the variable is unset | M0-01 |
| M0-06 | Local Supabase stack: `supabase init`, `config.toml` (project id, auth settings, pgmq + pg_cron enabled, Storage buckets declared), `make up` / `make down`, `supabase gen types` → `apps/web/src/lib/database.types.ts` | `make up` starts the stack in the session; `supabase db reset` applies migrations from empty; types generated | M0-01 |
| M0-07 | Tenancy schema: `public.tenant` (kind: `servicer`, `client`, later `fund`), `public.app_user` (profile linked to `auth.users`), `public.membership` (user, tenant, role ∈ admin / ops_manager / collector / client_admin / client_viewer), `public.portfolio` + `public.portfolio_permission` | Forward-only migration; FK and check constraints; RLS enabled on all tables (pgTAP `has_rls`/policy checks) | M0-06 |
| M0-08 | Auth: email OTP / magic link for all users; TOTP MFA enrolment; internal roles require `aal2` (enforced in RLS helper and middleware); Next.js `@supabase/ssr` login, MFA enrol/verify and logout pages | Playwright: staff user can't reach the back-office without MFA; client user can log in with OTP (local Inbucket); screenshots committed | M0-07, M0-03 |
| M0-09 | Custom access token hook (Postgres function) adding `tenant_ids`, `roles` and `is_staff` claims; RLS helper functions in `private` (`private.current_tenant_ids()`, `private.has_role()`, `private.is_staff_aal2()`) | pgTAP: claims present for a seeded user; helpers return the expected sets | M0-07 |
| M0-10 | RLS policies for tenancy tables + **pgTAP tenant isolation suite** (two tenants, users of each role, assert no cross-tenant read/write; client roles read-only where specified; anonymous gets nothing) | `supabase test db` green; at least one test per table per role | M0-09 |
| M0-11 | Write-protection pattern: revoke direct `insert/update/delete` from `anon`/`authenticated` on "worker-owned" tables; `SECURITY DEFINER` command functions with `search_path` pinned; idempotency-key table `private.command_log` | pgTAP: an authenticated user can't insert into a worker-owned table; a command function call is idempotent on the same key | M0-10 |
| M0-12 | Change history: generic trigger `private.log_change()` writing to `private.change_log` (table, row id, op, old/new JSONB diff, actor, txid, at) attached to core tables | pgTAP: update on a core row creates one change_log row with the right diff and actor | M0-07 |
| M0-13 | Layer 1: generator `tools/eba_catalogue/gen_sql.py` producing a migration with `eba.t1_counterparty`, `eba.t2_*`, `eba.t3_loan`, `eba.t4_1_protection`, `eba.t4_2_mortgage`, `eba.t5_collection` (typed columns from the catalogue: text / numeric(20,2) / date / boolean; `boarding_batch_id`, `tenant_id`), plus `eba.field_catalogue` table loaded from the CSV | The migration is generated, never edited by hand (CI re-generates and diffs); every catalogue field has exactly one column; RLS on the tables | M0-06 |
| M0-14 | Layer 2 core, first slice (per `DOMAIN.md`): `client_mandate` (R124-3 terms), `party` (natural / legal person, SIREN), `contact_point` (channel, value, source, validity, per-channel consent), `account` (claim: claim_type, contract terms JSONB, legal_regime, currency, references), `account_party` (debtor, co-debtor, guarantor), `claim_ownership` (original creditor, owner, servicer, mandate type, valid_from/to), `document` index | Migration applies; pgTAP isolation tests extended; change-log triggers attached; ER diagram in `DOMAIN.md` matches the tables | M0-10, M0-12 |
| M0-15 | Mapping Layer 1 → Layer 2 (declarative spec `worker/src/collectoo_worker/boarding/specs/eba_to_core.yaml`) and Layer 2 → Layer 1 export stub; unit tests on a 10-row sample | Round trip on the sample keeps every mapped field; unmapped Layer-1 fields kept in `account.source_attributes` | M0-13, M0-14 |
| M0-16 | Synthetic generator `collectoo_worker.synth` (Faker `fr_FR`, seeded): EU-template bank tape (T1–T5, coherent IDs, consumer + SME loans, schedules, 36-month collection history) | `uv run synth eba --rows 1000 --seed 1` writes CSVs that validate against `eba_template.schema.json`; deterministic for the same seed | M0-13 |
| M0-17 | Synthetic civil-claims files: SMB B2B invoices (SIREN/SIRET with valid Luhn, IBAN, due dates, partial payments, credit notes), B2C invoices, rents; deliberately messy variants (French dates/decimals, missing contacts, duplicates) | Files generated for 3 "accounting export" dialects; a fixture manifest lists the injected defects (used as M1 test oracle) | M0-16 |
| M0-18 | `supabase/seed.sql` + `make seed`: servicer tenant, 2 client tenants, users for every role, 2 portfolios, a few hundred synthetic accounts | `supabase db reset` seeds in < 30 s; the M0-08 Playwright login uses seeded users | M0-14, M0-17 |

---

## M1 — Portfolio boarding

| ID | Task | Acceptance criteria | Deps |
|---|---|---|---|
| M1-01 | Schema: `boarding_batch` (state machine per `DOMAIN.md`: uploaded → profiled → mapped → validated → staged → committed → confirmed / rolled_back), `boarding_file`, `boarding_event`; Storage bucket `boarding` with tenant-scoped RLS | pgTAP: client user sees only own tenant's batches and files; illegal state transitions are rejected by a DB function | M0-14 |
| M1-02 | Upload: signed upload URL via a `SECURITY DEFINER` function; multi-file batch; checksum stored; enqueue `boarding.profile` on pgmq | Uploading 3 files creates 1 batch + 3 files + 1 queue message; re-upload of the same checksum is flagged | M1-01 |
| M1-03 | Worker runtime: pgmq consumer loop (psycopg 3), idempotency per message, retry with backoff, dead-letter queue, structured logs; `make worker` | Killing the worker mid-job and restarting it doesn't double-process (test) | M0-11 |
| M1-04 | Readers: CSV (encoding/separator sniffing, incl. `;` and Latin-1), XLSX (multi-sheet), fixed-width (layout spec); streaming via Polars lazy / DuckDB | The M0-17 messy dialects are all read; a 50k-row CSV is read in streaming mode | M1-03 |
| M1-05 | Profiling: per column type guess, null %, distinct count, top values, regex patterns (date, decimal comma, SIREN, IBAN, phone, email), sample rows → `boarding_file.profile` JSONB | Profile on M0-17 fixtures detects every injected pattern listed in the manifest | M1-04 |
| M1-06 | Canonical target registry: list of mappable targets (Layer 2 fields + EBA catalogue fields) with descriptions, types and examples, generated from the schema and catalogue | Registry exported as JSON; every target has a type and a description | M0-15 |
| M1-07 | LLM gateway (provider-agnostic interface, prompt templates versioned in repo, JSON-schema-validated outputs, every call logged in `private.llm_call` with prompt version, model, input hash, output) + **mock provider** (deterministic heuristics: name similarity, EBA label match, profile patterns) | Gateway rejects outputs that fail the schema; mock is deterministic; call log row written per call | M1-03 |
| M1-08 | Mapping proposal: per source column → target + confidence + rationale; multi-file join keys proposed; result stored as a draft mapping | On M0-16/M0-17 fixtures, proposals are produced for every column; low-confidence (< threshold) fields are flagged for review | M1-05, M1-06, M1-07 |
| M1-09 | Mapping eval suite: golden datasets (`worker/evals/mapping/*.yaml`, built from synthetic dialects), metric = top-1 accuracy; runs in CI with a threshold | CI fails if mock accuracy drops below the threshold set from the first run; the report is printed in the CI log | M1-08 |
| M1-10 | Mapping profiles: save an approved mapping per client/seller, with a version; auto-apply when file headers match | Second upload of the same dialect gets the saved mapping with confidence 1.0 | M1-08 |
| M1-11 | Transformation DSL (declarative YAML, versioned): parse French dates/decimals, trim, case, split/concat, lookup tables, default values, unit conversion to cents | Each transform has unit + property tests; a transformation spec version is stored on the batch | M1-08 |
| M1-12 | Validators/normalisers: SIREN/SIRET (Luhn), IBAN (mod 97), E.164 phones (`phonenumbers`), email syntax, FR postcode | Property tests: generated valid identifiers pass, mutated ones fail | M1-11 |
| M1-13 | Address normalisation adapter: BAN (`api-adresse.data.gouv.fr`) with a cache table and a mock adapter for CI; batch geocoding endpoint for large files | CI uses the mock; a manual run against BAN normalises 100 synthetic addresses; results cached | M1-11 |
| M1-14 | Claim-type assignment rules (declarative: by source dialect, by column values, default per portfolio) + legal regime assignment (`pre_ccd2` / `ccd2` by contract date, CCD-01) | Every staged account has a claim type and a legal regime; unassigned accounts are blocking errors | M1-11 |
| M1-15 | Validation rules (blocking vs warning, declarative): mandatory fields per claim type, EBA mandatory fields per borrower/loan type and Art. 4(1) exemptions, referential integrity across files, duplicate detection | Injected defects from the M0-17 manifest are all reported with the right severity | M1-12, M1-14 |
| M1-16 | Data-quality report: completeness per field, contactability % (valid email / mobile / postal), duplicates, balance reconciliation against the seller's cut-off totals (input in UI or control file) | Report JSON + rendered page; reconciliation shows the difference to the cent | M1-15 |
| M1-17 | Staging: write normalised rows to staging tables keyed by batch; idempotent re-run | Re-running staging gives identical row counts and hashes | M1-15 |
| M1-18 | Commit/rollback: commit staging → Layer 2 (+ Layer 1 for EBA tapes) in a single transaction via a `SECURITY DEFINER` function; batch reversible (`rolled_back`) until `confirmed`; ownership records created | pgTAP + pytest: commit then rollback leaves no trace except the batch audit trail; confirmed batches can't be rolled back | M1-17 |
| M1-19 | Review UI (back-office): batch list, upload, profile view, mapping review (accept/override per field, confidence and rationale shown), DQ report, commit/rollback/confirm | Playwright flow end to end on a synthetic file; mobile + desktop screenshots committed | M1-16, M1-18 |
| M1-20 | Bulk document upload (zip): unpack in the worker, link to accounts by reference found in the file name, store in Storage, index in `document` | 100-file zip links ≥ 99 % by reference; unmatched files listed in the batch. OCR/extraction deferred (see notes) | M1-18 |
| M1-21 | 50k-row CI test: synthetic EU-template tape boarded end to end in CI (mock LLM, mock BAN) | Passes in CI within the time budget (target ≤ 5 min for the job) | M1-18 |
| M1-22 | 1M-row benchmark script (`make bench-boarding`), memory and time measured on the VM; results in `docs/benchmarks/boarding.md` | Peak RSS stays below 4 GB; result table committed | M1-21 |

**M1 demo:** board a 50k-account synthetic bank tape and an SMB invoice export, show the DQ report and commit.

---

## M2 — Servicing core

| ID | Task | Acceptance criteria | Deps |
|---|---|---|---|
| M2-01 | Ledger schema (per `ARCHITECTURE.md`): `ledger_account` (per claim × component, client-money accounts per client, servicer revenue accounts), `journal_entry`, `posting` (bigint cents + currency); deferred constraint: postings of an entry sum to zero per currency | pgTAP: an unbalanced entry fails at commit | M0-14 |
| M2-02 | Append-only enforcement: no `update/delete` on entries/postings (trigger + revoked privileges), corrections only through `ledger.reverse(entry_id)` | pgTAP: update/delete rejected even for the owner role used by the worker; reversal creates the mirror entry | M2-01 |
| M2-03 | Balance views/functions: balance per account, component and date (`as_of`), client-money balance per client | Balance at date D equals the sum of postings with `effective_date ≤ D` (pgTAP) | M2-01 |
| M2-04 | Python ledger API (`collectoo_worker.ledger`): post, reverse, idempotency key per command | Property tests (hypothesis): any sequence of posts/reversals keeps every entry balanced; post + reverse ⇒ zero net effect; same idempotency key ⇒ single entry | M2-02 |
| M2-05 | Opening balances from boarding: committed batches post opening entries per component (principal, interest, fees as provided by the seller) | Sum of opening balances = DQ-report reconciled total for the batch | M2-04, M1-18 |
| M2-06 | Payment model: `payment` (source: bank transfer, SEPA DD, card, manual; status), structured reference per account (RF creditor reference, ISO 11649) | RF references validate (mod 97); one active reference per account | M2-01 |
| M2-07 | CAMT.053 parser + manual CSV payment import; dedup by bank transaction ID | Parses sample CAMT.053 files (synthetic, incl. batch bookings and returns); importing twice creates no duplicates | M2-06 |
| M2-08 | Reconciliation: exact match on RF reference, then rules (amount + name + invoice ref), else exception queue for ops | Synthetic statement: ≥ 95 % auto-matched; others in the exception queue | M2-07 |
| M2-09 | Allocation waterfall (configurable order, default: interest before principal (1343-1), then oldest debt (1342-10)); override per client/portfolio where allowed; debtor-designated allocation supported | Property tests: allocation never exceeds component balances; sum allocated = payment amount (or the remainder is booked as overpayment); ⚖️ OQ-7 for the B2B €40 position | M2-04, M2-08 |
| M2-10 | Receipts (*quittance*, R124-6, CPCE-07): generated on each allocated payment, PDF (French), stored with SHA-256, linked to the payment | Every allocated payment has exactly one receipt; regeneration produces an identical hash | M2-09 |
| M2-11 | Creditor notification of payments (CPCE-06): event + client-visible feed (UI in M7) | Each allocated payment emits one client notification event | M2-09 |
| M2-12 | Client-money segregation (CPCE-02): collected funds post to the client-money account of the client; fees/commission only on remittance | pgTAP/pytest: servicer revenue accounts never receive principal collections directly | M2-09 |
| M2-13 | Commission rules per mandate (rate per claim type/tranche, minimums) and commission computation | Unit tests on mandate examples; commission stored per remittance line | M2-12 |
| M2-14 | Remittance runs (*reversements*): scheduled per mandate (default within 1 month of collection, R124-6, ⚖️ OQ-16), statement per client (CSV + PDF), SEPA credit transfer file (pain.001) generated for ops | Run is idempotent; statement totals = collected − commission; deadline breach raises an alert | M2-13 |
| M2-15 | Commission invoice per remittance (numbering, VAT) | Invoice totals match the remittance statement; numbering is gapless per tenant | M2-14 |

---

## M3 — Calculation engine

| ID | Task | Acceptance criteria | Deps |
|---|---|---|---|
| M3-01 | Rate tables: `rate_table` + `rate_value` (effective-dated, source reference), seeded with the verified French legal rates (both categories) and the ECB MRO rate history | Lookup at any date returns the right rate; values have a source link; 🔒 ECB values to verify (`CALCULATION_RULES.md` §4.2) | M0-14 |
| M3-02 | Rule-pack format: YAML in `worker/src/collectoo_worker/engine/rule_packs/<claim_type>/<effective_from>.yaml`, JSON Schema, loader with load-time validation (legal reference required on each rule), loaded into `rule_pack` / `rule_pack_version` tables | Invalid packs fail CI; a pack version is immutable once used by a posting | M3-01 |
| M3-03 | Engine core: segment builder (split at rate changes, events, payments), day-count conventions (ACT/365 default, ACT/360, 30/360), Decimal arithmetic, half-up rounding to the cent per segment | Property tests: splitting a period anywhere doesn't change the total by more than the rounding bound; zero rate ⇒ zero interest | M3-02 |
| M3-04 | Start events and state: due date, *mise en demeure*, acceleration (*déchéance du terme*), judgment (+5 pts after 2 months, L313-3), insolvency stop (L622-28), holds | Unit tests per event using the `CALCULATION_RULES.md` examples | M3-03 |
| M3-05 | Fees and caps: statutory indemnities (D312-16 8 %, consumer mortgage 7 %), €40 B2B (D441-5), block of recovery fees without an enforceable title (L111-8, CPCE-09) at ledger level | A rule pack that tries to charge a non-allowed fee fails validation; ledger refuses fee postings without a title flag | M3-04, M2-04 |
| M3-06 | Capitalisation (1343-2) with consumer-credit exclusion (INT-06); prescription/forclusion date computation | Property test: capitalisation never applies to consumer-credit claim types; prescription dates match the table | M3-04 |
| M3-07 | Amortisation schedule: import (from tape) or rebuild from contract terms; split unpaid instalments vs capital outstanding | Rebuilt schedule matches a reference schedule to the cent | M3-03 |
| M3-08 | Rule pack: **B2B invoice** (first segment first) + worked example 3 as a golden test | Example reproduced to the cent; 🔒 founder golden cases; ⚖️ OQ-6, OQ-7 | M3-05 |
| M3-09 | Rule pack: **B2C invoice** + worked example 4 | Example reproduced; 🔒 golden cases; ⚖️ OQ-3 | M3-05 |
| M3-10 | Rule pack: **professional loan** + worked example 2 | Example reproduced; 🔒 golden cases | M3-06, M3-07 |
| M3-11 | Rule pack: **consumer instalment loan** (`pre_ccd2` and `ccd2` regimes) + worked example 1 | Example reproduced; regime chosen by contract date; 🔒 golden cases; ⚖️ OQ-4, OQ-5, OQ-10 | M3-06, M3-07 |
| M3-12 | Golden-case harness: `worker/tests/golden/<claim_type>/*.yaml` (inputs, events, expected *décompte* lines), runner, diff output to the cent | Harness fails with a readable line-by-line diff; founder cases drop in without code changes | M3-08 |
| M3-13 | Accrual posting: the engine posts interest accruals to the ledger idempotently (per account, per segment); recompute-at-date compares engine output with the ledger | Recompute of every seeded account = ledger balance (invariant test) | M3-12, M2-04 |
| M3-14 | *Décompte* builder: itemised lines (component, base, rate, period, day count, legal/contract reference, rule-pack version), JSON output + French HTML/PDF rendering | Every line traces to postings; the total equals the ledger balance at the date | M3-13 |
| M3-15 | Allocation from the rule pack: M2 waterfall reads the order from the active rule-pack version | M2 property tests still pass with rule-pack-driven order | M3-02, M2-09 |

**M3 demo:** for one account per claim type, show the *décompte* at three dates and recompute it from scratch.

---

## M4–M9 outline (detailed later)

- **M4 Flows + channels:** flow state table (`next_run_at`), pg_cron tick → pgmq, idempotent step executor; React Flow builder (draft/publish, versions, migration of in-flight accounts, simulation with cost); channel adapter interface + capability descriptors; email/SMS (Brevo + standby), WhatsApp (Meta Cloud API sandbox), simple letter (hybrid-mail sandbox); guardrails (holds, consent, mandatory mentions); fallback on restriction. **Proposed:** pull the R124-4 locked first-letter template and validator (CPCE-04/05) into M4 so flows can't send a later message before it.
- **M5 Debtor portal:** unique link + OTP + light identity check, *décompte*, Stripe test-mode payments, plans inside the envelope, disputes with upload, preferences, portal chat (mock assistant).
- **M6 Legal-grade comms:** R124-4 letter archive and proof, LRAR + LRE (consent check, LRE-01), bailiff escalation package (export), prescription alerts.
- **M7 Back-office + client portal:** collector workspace and queues, unified inbox, client portal (claims submission, statements, reporting), SMB self-serve onboarding with online mandate, API + webhooks.
- **M8 Analytics + decisioning:** event store, dashboards (liquidation, curves, contact rate, promise-kept, cost-to-collect), Thompson-sampling bandits with holdouts (⚖️ OQ-14 before any propensity model).
- **M9 More channels:** one adapter per PR in the `CHANNELS.md` §6 order (voice/IVR, RCS, web push, voicebot, Messenger, Instagram, Apple, Telegram, Viber) — 🔒 founder to confirm the order.

---

## Founder inputs that block tasks

| Input | Blocks | Needed by |
|---|---|---|
| Golden calculation cases (2–3 per claim type) | M3-08 … M3-12 become "validated" instead of "TO VALIDATE" | Before M3 is called done (founder: "later") |
| Counsel answers OQ-3 … OQ-7, OQ-10, OQ-16 | Rule packs ship with conservative defaults until answered | M3 / M2-14 |
| Confirm the ECB MRO rate values for L441-10 | M3-01, M3-08 | M3 |
| Sample anonymised SMB accounting exports (Pennylane, Sage, QuickBooks, Excel…) | Improves M1-09 eval realism (synthetic dialects are used meanwhile) | M1 (nice to have) |
| Brevo use-case declaration + standby provider choice | M4 channel go-live | M4 |
| Hosted Supabase project (Paris) linked via GitHub integration | Deployment of merged migrations | After PR-2 |
| Vercel (EU) and Scaleway projects | Preview deploys of web and worker | Optional before M4 |

## Notes on scope (inputs to Phase 0 step 4)

- **OCR and structured extraction** in M1 (BRIEF §3.2 bulk documents) is heavy for a boarding slice. Proposed: M1 links documents by reference; extraction moves to "Later" with the AI features.
- **Order of M3 rule packs** follows the first segment: B2B invoice, B2C invoice, professional loan, consumer loan.
- **R124-4 first letter** is a precondition for any outbound message to a real debtor; see the M4 proposal above.
