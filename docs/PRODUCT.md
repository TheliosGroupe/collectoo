# Product

_Phase 0 draft, 2026-11-07. Source of truth for scope: `docs/BRIEF.md`. Legal constraints: `docs/COMPLIANCE.md`._

Collectoo is a cloud- and AI-native receivables and NPL servicing platform. We start as a third-party amicable collection agency (*recouvrement amiable pour compte de tiers*) for **SMBs with unpaid B2B invoices**. Then come BNPL providers, then banks. Later we become an ACPR-licensed *gestionnaire de crédits* servicing FCTs.

The promise: **a debtor can settle without talking to anyone, a client can hand over invoices in minutes, and every euro shown can be explained line by line.**

---

## 1. Personas and jobs-to-be-done

### P1 — Debtor, consumer
*Camille, 34. Owes a telecom or energy bill, or is behind on a consumer instalment loan. Is embarrassed, busy, and suspicious of "collection" messages because of SMS scams.*

| When… | I want to… | So that… |
|---|---|---|
| I receive a message about a debt | check that it is genuine (known creditor, official sender, secure portal) | I don't get scammed |
| I open the portal | see exactly what I owe and why (principal, interest, fees, each with its basis) | I can trust the amount |
| I can't pay everything now | set up a plan that fits my budget, alone, on my phone | I avoid calls and escalation |
| I think the debt is wrong | dispute it and upload proof | collection pauses while it's checked |
| I pay | get a receipt immediately | I have proof that I paid |
| I'm in *surendettement* or facing hardship | say so once and have it respected | I'm not harassed |

### P2 — Debtor, professional / SME
*Karim, manager of a 6-person company. Has three unpaid supplier invoices; cash is tight.*

| When… | I want to… | So that… |
|---|---|---|
| I receive a reminder for an invoice | see the invoice, PO and delivery proof | I can check it with my team |
| I agree I owe it | pay by transfer with the right reference, or agree a short plan | the supplier relationship survives |
| I disagree (delivery issue, credit note pending) | raise a dispute with documents | the amount is corrected and not escalated |
| Penalties and the €40 indemnity appear | understand how they were computed | I don't feel cheated |

### P3 — SMB client admin (first segment)
*Sophie, CFO of a 40-person B2B services company. 180 overdue invoices, 2 % of revenue. No collection team.*

| When… | I want to… | So that… |
|---|---|---|
| I sign up | accept a clear mandate online (fees, remittance terms) | I can start the same day |
| I hand over claims | upload my accounting export (CSV/XLSX) or fill a form, without reformatting | I don't spend a day on it |
| Collection is running | see each case's status and the next action, without calling anyone | I can answer my CEO |
| A customer is strategic | set a softer tone, a plan envelope or pause the case | I keep my customer |
| Money comes in | receive remittances and a statement net of commission, with an invoice | my accounting reconciles |

### P4 — Bank / BNPL client operations
*Head of recoveries at a BNPL provider or a bank's collection department.*

| When… | I want to… | So that… |
|---|---|---|
| I outsource a portfolio | send a tape (EU NPL template or my own format) and have it live in hours | we don't lose weeks in onboarding |
| Regulators or auditors ask | show that every message, amount and decision was compliant and traceable | we pass audits |
| Every month | get performance reports (liquidation, curves by cohort, cost-to-collect) and data via API | I can compare servicers |
| A debtor complains | find the full timeline and evidence in minutes | I can answer within the deadline |

### P5 — Internal collector
*Works exceptions only: disputes, hardship, broken plans, callbacks.*

| When… | I want to… | So that… |
|---|---|---|
| I start my day | see a prioritised queue of tasks | I work on what matters |
| I open a case | see the account 360°: amounts, timeline across channels, documents, AI summary and suggested next step | I don't read 40 messages |
| I act | log the outcome, offer a plan within the envelope, place a hold | the system follows up automatically |

### P6 — Ops manager
*Runs boarding, flows, channels and remittances.*

| When… | I want to… | So that… |
|---|---|---|
| A new tape arrives | review the proposed mapping, the data-quality report and the reconciliation with the seller's totals | I commit with confidence (and can roll back) |
| I design a strategy | build and simulate a flow per portfolio/claim type | I know its cost and timeline before publishing |
| A channel is restricted | be alerted and see flows fall back automatically | no debtor communication is lost |
| Month-end | run remittances and client statements | clients are paid on time (R124-6) |

### P7 — Admin
Manages tenants, users, roles, MFA, rule packs, locked templates, retention policies and data-subject requests.

### P8 — Later: fund / *société de gestion* / *dépositaire* (phase C, modelled now, built later)
Wants portfolio pricing from historical curves, a servicing report, the collections waterfall, fee and co-investment accounting, and an EU-template data tape at any date.

---

## 2. MVP scope at a glance

The **MVP** is what we need to service real SMB B2B invoice clients compliantly: **M0–M7**. Bank-specific depth (rule packs beyond the first four, EU-template exports, FCT reporting) comes after.

| Milestone | What a user can do at the end | First-segment (SMB B2B invoices) relevance |
|---|---|---|
| **M0 Foundations** | Staff log in (MFA), tenants are isolated, synthetic portfolios exist | Base |
| **M1 Boarding** | Ops upload a tape (EU template, invoice export, multi-file), review the AI mapping, see a data-quality report, commit a reversible batch | **High**: SMB accounting exports are messy |
| **M2 Servicing core** | Payments imported and reconciled (CAMT.053), allocated, receipted; remittance runs and client statements | **High**: R124-2/R124-6 obligations |
| **M3 Calculation engine** | Balance and *décompte* at any date for 4 claim types | **High** for B2B invoice (penalties + €40); others for BNPL/bank later |
| **M4 Flows + channels** | Visual flows, email/SMS/WhatsApp/letter via sandboxes, guardrails, holds, fallback, simulation | High |
| **M5 Debtor portal** | Debtor sees the *décompte*, pays (Stripe test), sets a plan, disputes, chats | **High**: self-service is the product |
| **M6 Legal-grade comms** | R124-4 first letter (locked), LRAR/LRE, bailiff escalation package | **Go-live gate** (see below) |
| **M7 Back-office + client portal** | Collector workspace, unified inbox, SMB self-serve onboarding, client reporting, API/webhooks | **High**: SMB self-serve |
| M8 Analytics | Dashboards, bandit send-time/channel optimisation | After first clients |
| M9 More channels | One adapter per PR (voice/IVR, RCS, push…) | After first clients |

**Go-live gate for real debtors.** No outbound collection message may reach a real debtor before the R124-4 first letter exists (CPCE-04/05 in `COMPLIANCE.md`). The brief places the letter in M6 but sending in M4, so we either pull the locked first-letter template and its validator into M4, or treat M6 as the go-live gate. **Recommendation: pull it into M4** (see `ROADMAP.md`).

**First SMB client before M7.** Until self-serve onboarding ships, ops boards the first SMB clients through the M1 UI, and the mandate is signed outside the platform but stored in it (R124-3).

---

## 3. Non-goals for the MVP

- **Phase B (ACPR):** credit-servicer governance, internal control, LCB-FT, regulatory reporting. The data model stays compatible.
- **Phase C (FCT/fund):** pricing, waterfall, investor reporting and the co-investment ledger are *modelled* (ownership history, servicer ≠ owner) but not built.
- **Credit scoring of natural persons**, or any AI Act high-risk system (AI-01). Decisioning stays limited to channel/timing/message choice.
- **Automated decisions with legal effect** (GDPR-06): AI suggests; rules or humans decide settlements and escalations.
- **Call tooling** (dialer, IVR, voicebot) before M7/M9.
- **Channels beyond wave 1** (email, SMS, WhatsApp, letters/LRE, portal chat) before M9.
- **Judicial tools:** *injonction de payer* filing, BODACC monitoring and *déclarations de créances*. M6 only exports a bailiff package.
- **Full OCR and structured extraction of documents.** M1 links documents by reference; extraction comes later.
- **Email open-tracking pixels** (default off, GDPR-08), and any analytics that need consent we don't have.
- **Rule packs beyond the first four** (revolving, overdraft, BNPL, mortgage, rents, private loans, judgments).
- **Languages:** debtor copy is French only. **Currency:** EUR only (the currency is stored on every amount anyway).
- **Native mobile apps.** The portal is a mobile-first web app.
- **Certifications and voluntary frameworks** (ISO 27001, SOC 2, codes of conduct).
- **Real LLM calls** until the founder provides a key (mock provider meanwhile).

---

## 4. MVP success metrics (proposed targets — founder to confirm)

| Metric | Definition | Proposed target |
|---|---|---|
| Time-to-board (SMB) | Upload of an invoice export → accounts live in flows | ≤ 30 min, including human review |
| Time-to-board (bank tape) | 50k-account EU-template tape → committed batch | ≤ 4 h, including review |
| Mapping accuracy | % of source columns correctly mapped by the proposal on the eval set | ≥ 90 % top-1; 100 % after review |
| Self-service resolution rate | Accounts resolved (paid / plan agreed) with no human touch ÷ accounts resolved | ≥ 70 % |
| Liquidation rate | € collected ÷ € boarded, at 30/90/180 days, by cohort and claim type | Baseline from first clients, then +X % vs client's previous agency |
| Contact rate | Accounts with ≥ 1 first-party engagement signal (portal visit, reply, payment) ÷ accounts contacted | Baseline first |
| Promise-kept rate | Instalments paid on time ÷ instalments due | ≥ 75 % |
| Cost-to-collect | (Channel + PSP + provider costs) ÷ € collected | Track per channel; ≤ 5 % for SMB B2B |
| Remittance timeliness | % of collected funds remitted within the contractual deadline (default: 1 month, R124-6) | 100 % |
| **Compliance invariants** (hard, tested) | Messages sent without passing guardrails; *décompte* that doesn't match the recomputation from ledger + rule pack | **0** |

---

## 5. Key risks

| Risk | Impact | Mitigation |
|---|---|---|
| A channel provider restricts our account (Brevo's anti-spam policy flags debt collection; WhatsApp policy) | Debtors stop being reached | Declare the use case to Brevo in writing; keep a standby email/SMS provider; separate sender identity per client brand; automatic fallback (`CHANNELS.md` §4) |
| Legal interpretation errors (OQ-1…OQ-17) | Unlawful fees or messages, client liability | Engine enforces only verified rules; open questions go to counsel before the related rule pack ships |
| Calculation errors | Wrong amounts in letters and *décomptes* | Deterministic engine, property-based tests, founder-validated golden cases |
| Debtors distrust digital messages (phishing) | Low engagement | Verified sender domain, consistent portal domain, creditor name in every message, no amount-only SMS, RCS verified sender later |
| Messy SMB data (no emails or phones, inconsistent references) | Low contactability, slow boarding | Data-quality report with contactability %; mapping profiles reused per client; BAN address normalisation |
| LLM mapping or triage mistakes | Bad boarding, misrouted disputes | Mock-first, eval suites in CI, confidence thresholds, human review; LLM never produces amounts |
| Personal-data breach / tenant leakage | Legal and commercial | RLS on every exposed table, pgTAP isolation tests, service role only in the worker, staff MFA |
| GDPR role unclear (processor vs controller, OQ-11) | Wrong art. 14 notice, wrong contracts | Counsel decision before the first real debtor contact |
| Jurisdiction of US-owned hosts (Vercel) | Bank clients may object | Worker and DB in the EU on Scaleway and Supabase Paris; keep the frontend thin; portability ADR |
| Scope creep from the full brief | Slow time to first client | Strict milestone order and go-live gate; one PR per slice |
