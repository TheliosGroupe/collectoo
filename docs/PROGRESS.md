# Progress

_Updated at every commit. New sessions: read `CLAUDE.md`, `docs/BRIEF.md`, then this file._

## Done
- Phase 0 step 0: brief saved verbatim in `docs/BRIEF.md`.

## In progress
- Phase 0 step 1: answers received. Pending: worker host (Scaleway proposed, explained), golden examples timing (explained).
- Drafting CHANNELS.md, COMPLIANCE.md, CALCULATION_RULES.md (no dependency on blocked downloads).

## Next
- Step 2: download EU NPL template sources (blocked: network allowlist, see below).
- Step 3: design docs (catalogue, gap analysis, PRODUCT, DOMAIN, CALCULATION_RULES, CHANNELS, ARCHITECTURE, COMPLIANCE, ADRs, CLAUDE.md, ROADMAP, CLOUD_ENV).

## Decisions
- Work branch is `claude/loving-clarke-u1b205` (the branch this cloud session is allowed to push to) instead of `phase-0`.
- Kickoff answers (2026-11-07): frontend on Vercel (EU region); first segment SMB B2B invoices; M3 rule packs = consumer instalment loan, professional loan, B2B invoice, B2C invoice; MVP digital-first with minimal collector workspace; PSP = Stripe (test mode); email/SMS via Brevo (cheaper than Twilio for FR SMS: ~EUR 0.045 vs ~USD 0.08); pace = as fast as possible.

## Open questions
- No `main` branch yet: creating it was blocked by the session safety check; founder asked to create it on GitHub.
- Allowlist: `eur-lex.europa.eu`, `www.eba.europa.eu`, `ec.europa.eu` blocked (HTTP 403 from proxy, 2026-11-07). `api-adresse.data.gouv.fr` (BAN) also blocked, needed in M1.
