# Phase 0 review: brief flags and founder questions

_2026-11-07. Answers go back into `docs/PROGRESS.md` (decisions) and the relevant doc._

## A. Contradictions and risks in the brief

| # | Flag | Proposal |
|---|---|---|
| A1 | **Stripe lists "debt collection agencies" as prohibited** (restricted, with prior written approval, in some country versions) ([Stripe list](https://stripe.com/legal/restricted-businesses), [summary](https://conductatlas.com/platform/stripe/stripe-restricted-businesses-list/provision/CA-P-065465/debt-collection-agencies-prohibited/)). Same pattern as Brevo, Mailjet and Viber (see `CHANNELS.md` §3). | Keep the payment layer provider-agnostic (ADR-0006/0011). First payment rail in M2 = **SEPA transfer with structured reference straight into the dedicated client-funds account**: no PSP, cheapest, matches R124-2. Stripe stays a test-mode adapter. Before go-live, ask Stripe in writing or pick a PSP that accepts collection agencies. |
| A2 | **First letter vs messaging order:** the R124-4 first letter is in M6, but M4 already sends email/SMS/WhatsApp. Any message sent before a compliant first letter breaks R124-4, and every later message must repeat its reference and date (`COMPLIANCE.md`). | Move the R124-4 locked template + pre-send validator into **M4** as a guardrail. M6 keeps registered mail/LRE and bailiffs. |
| A3 | **Credit servicer licence scope.** Phase A boards bank tapes, but servicing claims owned by a **credit purchaser** (fund, FCT, debt buyer) is credit servicing under Directive 2021/2167 and needs the ACPR licence (phase B). Servicing for the originating bank under a collection mandate is a different case. | In phase A, accept bank/BNPL claims only where the creditor is the originator (or a non-purchaser). Enforce it with `claim_ownership_period.mandate_type`. ⚖️ Confirm with counsel. |
| A4 | **CNIL délibération n° 2026-042 (12 Mar 2026)** cited in §4 was not found in the CNIL corpus. | Send the link. Art. 82 Loi 78-17 already requires consent, so "no pixels by default" stands either way. |
| A5 | **Vercel is a US company** while the stack is otherwise EU-only. The debtor portal goes through Vercel, so it needs a GDPR ch. V basis (DPF/SCCs). | Accept with DPF, as recorded in the sub-processor register (default). Fallback: Next.js on Scaleway. |
| A6 | **"Mandatory/optional per portfolio type"** (§3.2) doesn't exist as such in the regulation. It uses `mandatory` × `borrower_type` × `loan_type`, plus the Art. 4(1) transaction exemptions. | The catalogue models exactly that (`docs/reference/SOURCES.md`). |
| A7 | **Branch `phase-0`**: this cloud session can only push its assigned branch. | Work happens on `claude/loving-clarke-u1b205`. One branch per slice where the session allows it. |

## B. Over-scoped for an MVP (proposed cuts, already in `ROADMAP.md`)

| Item | Proposal |
|---|---|
| OCR + structured extraction of bulk documents in M1 | Later. M1 does zip upload + link by reference only. |
| Flow builder: migrating in-flight accounts between versions | v1: a new version applies to new entrants; in-flight accounts finish on their version. Migration later. |
| 16-channel catalogue | First wave only (email, SMS, WhatsApp, letters/LRE, portal chat). The rest follows the M9 order in `CHANNELS.md`. |
| AI decision node + bandits | M8 as planned; flows v1 use rules + random split. |
| 1M-row benchmark | Keep it, but as a manual benchmark script, not a CI job. |
| Rule packs | M3 order for the first segment: B2B invoice → B2C invoice → professional loan → consumer loan. |

## C. Founder questions (answered, see §D)

1. **PSP (A1):** SEPA transfer to the dedicated account first; Stripe in test mode until it confirms in writing. Default: ok
2. **R124-4 letter in M4 (A2).** Default: ok
3. **Phase A bank scope (A3):** originator-owned claims only until the licence. Default: ok
4. **Invoices:** one account per (client, debtor), with invoices as items, so interest and the €40 run per invoice. Default: ok
5. **Co-debtors:** one dossier per loan, with all parties on it. Default: ok
6. **Bank tape opening balance:** post components (3.09–3.11), plus a balancing "other" component up to the legal balance 3.12. Default: ok
7. **Holds from tape flags** (deceased, insolvency): proposed to ops for confirmation, outbound blocked meanwhile. Default: ok
8. **Broken plan:** 10 days' grace after a missed instalment, configurable per client. Default: ok
9. **Recalled claims:** late payments are received and forwarded to the client. Default: ok
10. **Template-mandatory fields:** warnings, unless the client requests a regulatory-grade tape. Default: ok
11. **WhatsApp:** one business account (WABA) per client brand where possible. Default: ok
12. **Vercel + DPF (A5).** Default: ok

Questions for counsel (no need to answer now; rule packs ship conservative defaults): `COMPLIANCE.md` §9 OQ-1…OQ-17, `CHANNELS.md` §8, `ARCHITECTURE.md` §17. Other domain questions with proposed defaults: end of `DOMAIN.md`.

## D. Founder decisions (2026-11-07)

| # | Question | Decision |
|---|---|---|
| 1 | Payment rail | **Stripe as main rail** (founder's call, despite A1). Before go-live: written approval from Stripe. The payment layer stays provider-agnostic, so a fallback PSP or SEPA transfer can be added without rework. |
| 2 | R124-4 first letter | **Built in M4** as a guardrail. M6 keeps registered mail/LRE and bailiffs. |
| 3 | Phase A bank scope | **Purchased claims accepted too** (founder's call, despite A3). Licence question stays open for counsel; `claim_ownership_period.mandate_type` records the case so it can be restricted later. |
| 4 | Invoices | One account per (client, debtor); invoices are items. |
| 5 | Co-debtors | One dossier per loan, all parties attached. |
| 6 | Bank tape opening balance | Components 3.09–3.11 + balancing line up to 3.12, flagged in the data-quality report. |
| 7 | Holds from tape flags | **Deceased:** collectible against heirs → stop contacting the deceased, open an estate task (heirs/notary); no account hold. **Insolvency:** a hold needs proof: the Banque de France admissibility decision (surendettement, hold starts at admissibility) or the court judgment (procédure collective). A tape flag alone opens an ops task to get the proof. |
| 8 | Broken plan | 10 days' grace, configurable per client. |
| 9 | Recalled claims | Receive late payments, issue a receipt, forward in the next remittance. |
| 10 | Template-mandatory fields | Warnings; blocking only for a regulatory-grade tape. |
| 11 | WhatsApp | One WABA per client brand. |
| 12 | Vercel | Vercel EU region + DPF/SCCs. |
| — | Brevo | Keep; declare the use case in writing; standby email/SMS provider wired. |
| — | CNIL délibération | Cite Loi 78-17 art. 82 only. |
| — | PR #1 | Claude watches the PR. |
| — | Staged accounts | No outbound activity until the boarding batch is **confirmed** (commit stays fully reversible). |
| — | Plan outside envelope | Client has 5 business days (configurable per client); on silence the proposal expires and the debtor gets in-envelope options. |
| — | Forbearance in EU exports | **Seller's measures only**; our payment plans are not exported as forbearance (3.38–3.43). |
| — | Percentages in EU exports | Ratio (5 % → `0.05`), configurable per export. |
