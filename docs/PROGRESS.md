# Progress

_Updated at every commit. New sessions: read `CLAUDE.md`, `docs/BRIEF.md`, then this file._

## Done
- Phase 0 step 0: brief saved verbatim in `docs/BRIEF.md`.
- `main` created from the brief commit (founder approval). Personal cloud environment `collectoo` created with EU/BAN hosts allowed.
- Step 2: EU NPL sources downloaded (EUR-Lex EN/FR HTML+PDF, EBA Excel annexes + final report), see `docs/reference/SOURCES.md`.
- Field catalogue: 135 fields (`docs/reference/eba_field_catalogue.csv`), JSON Schema model, Excel-vs-EUR-Lex diff; builder `tools/eba_catalogue/build_catalogue.py`.
- Drafts: `docs/CHANNELS.md`, `docs/COMPLIANCE.md`, `docs/CALCULATION_RULES.md`.

## In progress
- Step 3: gap analysis, PRODUCT, DOMAIN, ARCHITECTURE, ADRs, CLAUDE.md, ROADMAP, CLOUD_ENV.

## Next
- Step 4: flag contradictions/over-scope. Step 5: PR "Phase 0 — design docs".

## Decisions
- Work branch is `claude/loving-clarke-u1b205` (the branch this cloud session is allowed to push to) instead of `phase-0`.
- Kickoff answers (2026-11-07): frontend on Vercel (EU region); first segment SMB B2B invoices; M3 rule packs = consumer instalment loan, professional loan, B2B invoice, B2C invoice; MVP digital-first with minimal collector workspace; PSP = Stripe (test mode); email/SMS via Brevo (cheaper than Twilio for FR SMS: ~EUR 0.045 vs ~USD 0.08); pace = as fast as possible; worker on Scaleway (Paris); golden examples later (engine examples marked TO VALIDATE meanwhile).

## Open questions
- Default branch on GitHub is still `claude/loving-clarke-u1b205`; founder to switch it to `main` in Settings.
- Brevo/Mailjet/Viber policies flag debt collection (see CHANNELS.md): declare use case to Brevo + standby provider?
- 17 legal open questions in COMPLIANCE.md / CALCULATION_RULES.md.
