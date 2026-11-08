# EU NPL template → Collectoo: gap analysis and Layer-2 design

> **Status:** Phase 0 draft. Layer 1 = the 135 fields of Implementing Regulation (EU) 2023/2083, Annex II, as catalogued in `eba_field_catalogue.csv` (source of truth). Field IDs below (e.g. `3.12`) refer to that file. Layer 2 = the operational model the platform runs on (entities in `docs/DOMAIN.md`). Legal IDs (CPCE-04, INT-05…) refer to `docs/COMPLIANCE.md`.
> Questions for the founder are marked **❓ founder** and listed in §7.

## 1. What the template is, and is not

| Property of the template | Consequence for Collectoo |
|---|---|
| A **snapshot at a cut-off date** (`3.00`), built for a **sale** of bank NPEs (Art. 1). | Boarding turns the snapshot into an *opening position*. Everything after cut-off is Layer-2 history. |
| Scope: **credit institutions' non-performing credit agreements** only (Art. 1). | Civil and commercial claims (invoices, rents, private loans, judgments) never pass through Layer 1 (§5). |
| Balances are **aggregates** (`3.09` principal, `3.10` accrued interest, `3.11` other balances, `3.12` legal balance). | No component detail (unpaid instalments vs capital outstanding, indemnity vs fees vs insurance). Opening balances need a breakdown file or a documented split rule. |
| Repayment history = **monthly totals**, 36 months min. (`5.03`, `5.04`). | Usable for collection curves and pricing, not to re-run interest before cut-off. |
| **No contact data.** Only Booleans `1.18` e-mail available, `1.19` phone available; full address only for corporates (`1.14`, `1.15` are *Corporate*); individuals get postal code + country only (`1.16`, `1.17`). | Contact points must come from extra files in the same tape. Contactability is a DQ metric (§3.2). |
| Data minimisation (Art. 6(2)(b)): personal data shared only insofar as necessary. | Export needs a **pseudonymised mode** for pre-contract data rooms (§4.4). |
| Extension rows allowed: `1.xx.1`, `3.xx`, `4.xx`, `5.xx` (Annex III Part 1 §4). | Collectoo extensions (claim type, legal regime…) can travel in a compliant tape as extension rows. |

## 2. Gaps per module (BRIEF §3) and Layer-2 extensions

Legend: **Partial** = the template has a related field, cited. Table names are Layer-2 (`public` unless noted `private.` or `eba.`).

### 2.1 Tenancy, parties and roles (§3.1)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Tenants, users, roles, portfolio permissions, MFA | — | Everything | `organization(kind)`, `membership(user_id, organization_id, role)`, `portfolio_access(user_id, portfolio_id, role)`; MFA (`aal2`) required by RLS for internal roles |
| Counterparty identity | Partial: `1.02`, `1.03`, `1.06` (Households / NFC-SME / NFC-other), `1.07` DOB, `1.10`–`1.13` identifiers | No first/last name split; no birth place; no **consumer vs professional capacity per contract** (FINREP sector `1.06` puts sole traders under *Households*) | `party(kind: natural_person \| legal_entity)`, `party_identifier(scheme: siren \| siret \| lei \| national_id \| seller_ref, value, source)`; `account_party.capacity(consumer \| professional \| legal_entity)` because capacity is per contract, not per person |
| Groups | `1.00`, `1.01` | — | `party_group`, `party.party_group_id` |
| Roles on a claim | Partial: `1.05` (Borrower / Protection provider), `3.04` count of joint counterparties | No liability type (joint and several, guarantor cap), no co-borrower vs borrower | `account_party(role: borrower \| co_borrower \| guarantor \| protection_provider, liability: joint_several \| several \| capped, cap_minor)` |
| Deceased | `1.09` (optional, individuals) | Date of death, estate/heirs, notary | `party_life_event(kind: deceased, date, evidence_document_id)` → stops outbound to the deceased party and opens an estate task (identify heirs/notary); collection continues against heirs (founder 2026-11-07) |

### 2.2 Data model and portfolio boarding (§3.2)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Transaction-level history after cut-off | — | Everything | Ledger (§2.4) |
| History before cut-off | Partial: `5.03`, `5.04` monthly; `3.21`/`3.22` last payment | Event detail | `eba.t5_collection_month` kept as-is + ledger entries `entry_type = pre_boarding_aggregate` (one per loan × month, informational, excluded from interest recomputation) |
| Contact points | Booleans `1.18`, `1.19`; corporate address `1.14`–`1.17` | Values, source, validity, verification, consent | `contact_point`, `contact_consent` (§2.6) |
| Multi-file tapes, mapping, transformations, validation, DQ, staging, versioned commit | — | Everything | `boarding_batch`, `boarding_file`, `file_profile`, `mapping_profile` (+`_version`), `mapping_proposal`, `transformation_spec`, `validation_issue`, `dq_report`, `private.staging_*`; every Layer-2 row created by boarding carries `boarding_batch_id` |
| Seller cut-off totals for reconciliation | — | Not in the template | `boarding_batch.seller_control_totals` (JSON: count, Σ`3.09`, Σ`3.12`…), reconciled in the DQ report |
| Documents | — (data rooms are out of template, Art. 6(3)) | Everything | `document`, `document_link(entity, entity_id)`, `document_extraction` (OCR + structured fields, confidence) |

### 2.3 Claim types and calculation engine (§3.3)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Claim type | Partial: `3.05` asset class, `3.06` type of instrument | Not granular enough (no BNPL, no B2C invoice, no judgment debt); no link to a rule pack | `claim_type` (config), `account.claim_type_id`; boarding proposes it from `3.05`×`3.06`×capacity (§3.1) |
| Rule pack and its history | — | Everything | `rule_pack`, `rule_pack_version` (effective dates, legal refs, YAML hash), `account_rule_pack(account_id, rule_pack_version_id, valid_from)` |
| Applicable legal regime | Partial: `3.02` inception date, `3.03` governing law | Regime (`pre_ccd2` / `ccd2`, consumer mortgage, commercial…) | `account.legal_regime`, computed at boarding from contract date + capacity + claim type, stored with the rule that produced it |
| Contract terms | Partial: `3.07` maturity, `3.14`–`3.20` rate, type, margin, reference rate, reset, payment frequency | Day-count convention; rate **history**; index fixings; insurance premium; initial amount and term | `contract_terms` (versioned `valid_from`/`valid_to`: rate, index, margin_bp, day_count, payment_frequency, maturity, insurance), `rate_index`, `rate_value` (also holds legal rate and ECB MRO tables, CALCULATION_RULES §4) |
| Amortisation schedule | — | Everything | `schedule_line(account_id, seq, due_date, capital_minor, interest_minor, insurance_minor, source: imported \| rebuilt)` |
| Balance components | Aggregates `3.09`–`3.12` | Unpaid instalments vs capital outstanding; indemnity vs fees vs insurance vs costs; off-balance amounts inside `3.12` | Opening ledger entry with one posting per component (§3.3); split rule documented per mapping profile when the seller gives no breakdown |
| Start events | Partial: `3.23` default status date; `3.25` initiation of legal proceedings | *Déchéance du terme*, *mise en demeure*, judgment date, date enforceable (for L313-3 +5 pts), service date | `account_event(kind: due \| acceleration \| formal_notice \| judgment \| judgment_served \| judgment_enforceable \| default_status \| collective_proceeding_opened…, event_date, evidence_document_id, source)` |
| Prescription / forclusion | Partial: `3.29` statute of limitations date (seller-declared) | Rule-based computation, interruptions/suspensions (acknowledgement, payment, procedure) | Engine computes; `limitation_event(kind: interruption \| suspension, date, legal_ref)`; seller's `3.29` stored for comparison (DQ warning on mismatch) |
| Items inside a claim (invoices, rent periods, judgment heads) | — | Bank template is one loan = one row | `claim_item(account_id, kind: instalment \| invoice \| rent_period \| judgment_head \| loan_principal, ref, issue_date, due_date, original_minor)`; interest and the €40 indemnity run per item |

### 2.4 Servicing core: accounts, ledger, payments (§3.4)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Account | Partial: `3.01` loan id, `3.08` currency | Status, portfolio, client, collection lifecycle | `account` (state machine in DOMAIN §4.1) |
| Double-entry append-only ledger | — | Everything | `ledger_account(book, component, account_id?)`, `ledger_entry(entry_type, effective_date, posted_at, reverses_entry_id, idempotency_key, rule_pack_version_id?)`, `ledger_posting(amount_minor signed, currency)`; bitemporal by design (effective date + posted_at) |
| Client money separation (R124-2, CPCE-02) | — | — | `bank_account(purpose: client_money \| own)`; book `client_money_cash` |
| Payments, allocation, receipts | Partial: `3.21`, `3.22`, `5.03` | Everything else | `payment(method, psp_ref, value_date, status)`, allocation as `ledger_entry(entry_type = allocation, payment_id)`, `receipt` (R124-6, CPCE-07) |
| Bank reconciliation | — | — | `bank_statement`, `bank_statement_line` (CAMT.053), `reconciliation_match` |
| Remittance and commission | — | — | `remittance_run`, `remittance_line`, `commission_invoice`; terms in `mandate_terms` |
| Ownership / servicing history | — (seller implicit; `3.32` securitised flag only) | Owner ≠ servicer, transfers, mandate type | `claim_ownership_period(account_id, owner_organization_id, servicer_organization_id, mandate_type: mandate_amicable \| servicing_agreement \| owned, valid_from, valid_to, portfolio_transfer_id?)` |
| Client mandate (R124-3, CPCE-03) | — | — | `mandate` (signed document, scope, insurance terms), `mandate_terms` (versioned: commission %, remittance_max_days, plan envelope, discount authority) |
| Holds | Partial: `1.09` deceased; `1.31`–`1.33` insolvency name/status | Dispute, surendettement, wrong party, recalled; legal basis; evidence; scope | `account_hold(kind, legal_basis, scope: outbound \| payment_requests \| accruals, evidence_document_id, started_at, ended_at, decided_by)` |

### 2.5 Collection flows (§3.5)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Flow definitions, versions, in-flight state, simulation, metrics | — | Everything | `flow`, `flow_version(graph jsonb, status: draft \| published \| retired)`, `private.flow_run(account_id, flow_version_id, node_id, next_run_at, state)`, `private.flow_step_execution(idempotency_key, outcome)`, `segment`, `experiment`, `experiment_assignment` (incl. holdout) |

### 2.6 Omnichannel communications (§3.6)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Contact points with source, validity, consent | Booleans `1.18`, `1.19` | Everything | `contact_point(type: postal \| email \| phone \| messaging, value_normalised, source: seller \| debtor \| enrichment, valid_from, valid_to, status: unverified \| valid \| invalid \| opted_out)`, `contact_consent(contact_point_id, channel, purpose, basis, evidence, given_at, withdrawn_at)` incl. LRE consent (LRE-01) |
| Last contact | `1.20` date of last contact (requires a reply) | Channel, content, outcome, proof | Derived from `communication` + inbound (export rule §4.2) |
| Communication log with evidence | — | Everything | `communication(channel, provider, direction, template_version_id, content_sha256, storage_path, status, idempotency_key, cost_minor, first_letter bool, fallback_of_id)`, `communication_event` (webhooks), `delivery_proof`, `conversation`, `inbound_message` |
| Templates with locked legal blocks | — | Everything | `template`, `template_version`, `template_block(locked bool, legal_ref)` |
| Channel config and health | — | — | `channel_descriptor` (versioned, CHANNELS §5), `private.channel_health` |

### 2.7 Debtor portal (§3.7)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Portal access, identity check, sessions, analytics | — | Everything | `portal_identity(party_id, access_token_hash, otp_channel, verification_method, verified_at)`, portal actions emit `engagement_event` |

### 2.8 Legal and bailiff (§3.8)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Legal status and stage | `3.24` legal status, `3.25` initiation date, `3.26` stage (free text), `3.27` court country, `3.28` order for possession | Procedure type (injonction de payer, référé, fond, small claims), court, case number, bailiff, title, costs | `legal_procedure(kind, court, case_ref, status, stage)`, `legal_procedure_event` |
| Collateral enforcement | `4.29`–`4.42` (enforcement status, court appraisal, auctions) | — (well covered for bank mortgages) | `legal_procedure(kind = collateral_enforcement, protection_id)` + `auction` events carrying `4.34`–`4.42` |
| Enforceable title | — | Title type, decision date, service date, enforceability date, amounts awarded per head | `enforceable_title(kind: judgment \| injonction_de_payer \| notarial_deed…, decision_date, served_at, enforceable_at, court)`, heads as `claim_item(kind = judgment_head)` |
| Procedure costs | — | Amount, recoverability (title or not, CPCE-09), invoice | `procedure_cost(amount_minor, debtor_chargeable bool, legal_ref)` posted to ledger |
| Bailiff partners and packages | — | — | `bailiff_partner`, `escalation_package(status, approved_by)` (human approval, GDPR-06) |
| Insolvency of counterparty | `1.31` name, `1.32` status, `1.33` description | Opening date, court, mandataire, claim-filing deadline, proof of claim | `insolvency_proceeding(party_id, kind, opened_at, court, administrator, claim_deadline)`, `claim_filing` (déclaration de créance) |

### 2.9 Engagement analytics and decisioning (§3.9)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Event store | Partial: `5.03` monthly collections; `1.20` | Event-level touches and outcomes | `engagement_event` (append-only, monthly partitions), `private.decision_log` (bandit arm, context, reward) |
| Collection curves by cohort | `5.03`, `5.04` (≥ 36 months) | Post-boarding months | Computed from ledger + `eba.t5_collection_month` for pre-boarding months |

### 2.10 Back-office and client portal (§3.10)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Work queues, tasks, notes, complaints, DSR, client API | — | Everything | `task`, `work_queue`, `note`, `complaint`, `dsr_request` (GDPR-04), `api_key`, `webhook_subscription`, `client_report` |
| Promises, plans, disputes | Partial: `3.38`–`3.43` forbearance granted **by the bank before sale** | Post-boarding plans, promises, disputes | `payment_plan`, `plan_instalment`, `promise_to_pay`, `dispute`; seller forbearance kept in `forbearance_measure` |

### 2.11 Fund / FCT (§3.11)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| Portfolio purchase and transfer | Whole template = sale disclosure; `3.00` cut-off; `3.32` securitised | Transfer date ≠ cut-off date, price, buyer/seller, collections between cut-off and transfer | `portfolio_transfer(seller_org, buyer_org, cut_off_date, transfer_date, price_minor)`, new `claim_ownership_period` rows; collections in the interim tagged for the price adjustment |
| Fund structure | — | — | `organization.kind ∈ {fund, fct, management_company, depositary}`, `fund_share(fct_id, holder_org, share_pct)` (co-investment) |
| Servicing fees, waterfall, investor reports | — | — | `servicing_fee_terms`, `investor_report`; ERC from ledger curves |
| Data-room export | The template itself | — | §4 export |

### 2.12 Cross-cutting (§4, §7)

| Need | Template | Gap | Layer-2 extension |
|---|---|---|---|
| GDPR legal basis, retention, rights | — | Everything | `processing_purpose`, `retention_policy`, purge job, `dsr_request` |
| Change history | — | — | `private.change_log` (trigger-based, row before/after, actor, txid) |
| AI call log | — | — | `private.llm_call_log(prompt_version, model, input_hash, output, confidence)` |

## 3. Template → operational mapping (boarding)

### 3.1 Per template

| Template | Layer-1 staging (`eba.`) | Layer-2 target | Key transformations |
|---|---|---|---|
| **T1 Counterparty** (`1.00`–`1.33`) | `eba.t1_counterparty` | `party`, `party_group`, `party_identifier`, `contact_point` (postal, corporates; individuals only postal code/country), `party_financials` (dated by `1.21`), `insolvency_proceeding`, `party_life_event` | `1.06` → `party.kind` (Households → natural person, NFC → legal entity); `1.10`/`1.12` → SIREN/SIRET validation (Luhn); `1.13` LEI check digits; address via BAN; `1.09 = Yes` → proposed `deceased` hold (human confirm); `1.31`/`1.32` → `insolvency_proceeding` + proposed hold (`procédure collective` or `surendettement`) (human confirm) |
| **T2.1** Borrower ↔ loan (`2.00`, `2.01`) | `eba.t2_1_counterparty_loan` | `account_party` | Role from `1.05`; cross-check count with `3.04` (DQ warning) |
| **T2.2** Loan ↔ mortgage ↔ protection (`2.01`–`2.03`) | `eba.t2_2_loan_mortgage_protection` | `account_protection(mortgage_id)` | Many-to-many kept |
| **T2.3** Loan ↔ protection (`2.01`, `2.03`) | `eba.t2_3_loan_protection` | `account_protection` | — |
| **T2.4** Counterparty ↔ protection (`2.00`, `2.03`) | `eba.t2_4_counterparty_protection` | `protection.provider_party_id` + `account_party(role = guarantor \| protection_provider)` on the linked loans | — |
| **T3 Loan** (`3.00`–`3.43`) | `eba.t3_loan` | `account`, `contract_terms` (v1 valid from `3.02`), `account_event`, opening `ledger_entry`, `legal_procedure`, `forbearance_measure`, `claim_ownership_period` | See §3.2 field rules |
| **T4.1 Collateral, guarantee, enforcement** (`4.00`–`4.42`) | `eba.t4_1_protection` | `protection`, `collateral_property`, `valuation` (internal `4.19`–`4.22`, external `4.23`–`4.26`), `legal_procedure(kind = collateral_enforcement)` + auction events (`4.33`–`4.42`) | Amounts → minor units; `4.04` UN/LOCODE; EPC `4.16` |
| **T4.2 Mortgage** (`4.43`–`4.47`) | `eba.t4_2_mortgage` | `mortgage` | — |
| **T5 Historical collections** (`5.00`–`5.04` × months) | `eba.t5_collection_month(loan_id, month_offset, total, from_collateral)` | ledger `pre_boarding_aggregate` entries (one per loan × month, value date = month end); `collection_agent_history` from `5.01`/`5.02` | Never allocated to components; never used by the engine; used by curves/pricing |

### 3.2 Field rules for the opening position (T3)

| Field(s) | Rule |
|---|---|
| `3.00` cut-off date | `boarding_batch.cut_off_date`; opening ledger entry `effective_date = cut-off`; engine accrues **forward from cut-off only** |
| `3.01` loan id | `account.external_ref` + `party_identifier(scheme = seller_ref)` uniqueness per seller |
| `3.02` inception, `3.03` governing law | `contract_terms.contract_date`; with capacity and claim type → `account.legal_regime` (CCD-01) |
| `3.05` × `3.06` (+ capacity) | Proposed `claim_type` (e.g. Consumer × Other loans → consumer instalment loan; Credit card / Revolving → revolving; Overdraft → overdraft; Residential RE → mortgage; Corporate → professional loan; Trade receivables → B2B invoice). Reviewed in the mapping UI |
| `3.09`–`3.12` balances | Opening entry: one posting per component. Default split: `3.09` → principal (capital outstanding + capital in unpaid instalments if no breakdown), `3.10` → contractual interest accrued, `3.11` → `other_balances` (to be re-split from a breakdown file if provided). `3.12 − (3.09+3.10+3.11)` → `off_balance_legal_claim` component if positive. **❓ founder (Q1):** which figure is the collectible opening balance |
| `3.13` days past due | Stored as boarding snapshot only; re-derived afterwards |
| `3.14`–`3.20` | `contract_terms` v1; `3.18` reference rate → `rate_index` lookup (DQ warning if unknown) |
| `3.21`, `3.22` | `pre_boarding_aggregate` marker on `account` (last payment), not a ledger allocation |
| `3.23` | `account_event(kind = default_status)` |
| `3.24`–`3.28` | `legal_procedure`; `3.26` free text → stage enum proposed by the LLM mapper, human-reviewed |
| `3.29` | `account.seller_limitation_date`; engine's own date wins, mismatch = DQ warning |
| `3.30`, `3.31`, `3.32` | `account` attributes (`3.30 = Yes` → Art. 4(1)(b) exemption flag on the batch) |
| `3.33`–`3.37` lease | `contract_terms.lease` (jsonb; rare for collection) |
| `3.38`–`3.43` | `forbearance_measure` rows (seller history) |

### 3.3 Validation tied to the catalogue

- **Blocking:** a field marked `mandatory = Y` is empty **and** applies to the row (`borrower_type` matches T1 `1.06`-derived kind, `loan_type` = Secured only when the loan has a protection) **and** the batch is not flagged with an Art. 4(1)(a)–(f) exemption. ⚖️ Blocking only applies when the client asks for a *regulatory-grade* tape; for servicing we downgrade most of these to warnings (boarding must not stall on, e.g., `1.30` EBIT). Per-batch setting `tape_conformance: regulatory | servicing`.
- **Type checks** from `eba_template.schema.json`: Number/Percentage 2 dp, Date `DD/MM/YYYY`, Choice = full label, Boolean `Yes`/`No`.
- **Referential:** every `2.00`/`2.01`/`2.02`/`2.03` resolves to a T1/T3/T4.2/T4.1 row.

## 4. Operational → template export (regenerate a tape at any date)

### 4.1 Principle

`export_tape(portfolio, as_of_date D, knowledge_time K = now(), mode: full | pseudonymised)`:

- **As-of D** = business date of the snapshot (becomes `3.00`).
- **Knowledge time K** = what the system knew at K. Ledger entries carry `effective_date` and `posted_at`; temporal tables carry `valid_from`/`valid_to` and `recorded_at`; `private.change_log` covers the rest. With the same (D, K, rule-pack versions, catalogue hash), the export is byte-identical.
- Each run is stored: `tape_export(as_of_date, knowledge_time, catalogue_sha256, rule_pack_versions, file_sha256, mode)`.

### 4.2 Derivation classes

| Class | Fields | Source at (D, K) |
|---|---|---|
| **A. Stored attributes** (versioned where they change) | `1.00`–`1.08`, `1.10`–`1.17`, `1.21`–`1.30` (`party_financials` dated ≤ D), `3.01`–`3.08`, `3.14`–`3.20` (`contract_terms` valid at D), `3.30`–`3.37`, `4.00`–`4.28` (`valuation` latest ≤ D), `4.43`–`4.47`, `2.xx` links (`account_party`/`account_protection` valid at D) | Row versions valid at D, as recorded at K |
| **B. Ledger / engine at D** | `3.09` principal, `3.10` accrued interest, `3.11` other balances, `3.12` legal balance, `3.42` debt forgiveness, `5.03`, `5.04` | Engine statement of account at D using postings with `effective_date ≤ D` and `posted_at ≤ K`. `3.09` = principal components; `3.10` = contractual + late interest accrued unpaid; `3.11` = fees, indemnities, insurance, debtor-chargeable costs; `3.12` = total legally claimable (engine) excluding forgiveness; `5.03` = Σ payments per month for the 36 (or more) months before D, pre-boarding months from `eba.t5_collection_month`; `5.04` = payments with `source = collateral_sale` |
| **C. Event-derived at D** | `1.09` (deceased event ≤ D), `1.18`/`1.19` (any `valid` e-mail/phone `contact_point` at D), `1.20` (latest communication ≤ D **with a debtor reply**), `1.31`–`1.33` (`insolvency_proceeding` open at D), `3.13` (D − oldest unpaid due date ⚖️ FINREP §96 materiality), `3.21`/`3.22` (last payment ≤ D), `3.23`, `3.24`–`3.28` (`legal_procedure` state at D), `3.29` (engine limitation date at D), `3.38`–`3.41`, `3.43` (`forbearance_measure` + Collectoo plans ⚖️ Q4), `4.29`–`4.42` (enforcement/auction events ≤ D) | Event tables filtered on event date ≤ D and recorded ≤ K |

### 4.3 Formatting and checks (Annex III Part 1 §3–4)

- Number: two decimals, positive unless the glossary says otherwise, own currency; Percentage: ratio, two decimals (**❓ founder Q5:** 5 % as `0.05` or `5.00`; the text says "ratio"); Date `DD/MM/YYYY`; Choice = full label of the option; Boolean `Yes`/`No`.
- Mandatory check per row as in §3.3, using the batch's Art. 4(1) flags.
- Collectoo extras (claim type, legal regime, rule-pack version, last contact channel) go in **extension rows** `1.xx.1`, `3.xx`, `4.xx`, `5.xx` only when the buyer agrees; avoid extra personal data (Annex III §4).

### 4.4 Pseudonymised mode (Art. 6(2)(b))

Tokens replace `1.03` name, `1.07` date of birth (→ year only), `1.10`/`1.11` national identifiers, `1.14` address; `1.02` becomes a stable per-export pseudonym. Mapping kept server-side, released only after the sale contract.

## 5. Non-bank claims: straight into Layer 2

The generic mapper (same pipeline: profile → LLM mapping → review → transform → validate → DQ → stage → commit) targets Layer-2 entities directly.

| Claim type | Account grain (proposed, **❓ Q2**) | Minimum fields (blocking) | Useful fields (warning if missing) | Engine-relevant events |
|---|---|---|---|---|
| B2B invoice | One account per (client, debtor company); each invoice = `claim_item` | Debtor name + SIREN/SIRET, invoice no., issue date, due date, amount incl. VAT, currency, amount already paid | Contractual penalty rate, payment terms, PO/contract ref, contact e-mail/phone, disputes | `due` per invoice (penalties from D+1 without reminder, INT-08); €40 per invoice (OQ-6) |
| B2C invoice / subscription | One account per (client, debtor, contract) | Debtor name, postal address or e-mail/phone, contract ref, invoice no., issue/due dates, amount | Service type, prior reminders, existing *mise en demeure* date + proof | `formal_notice` (legal rate from mise en demeure, INT-01; OQ-3) |
| Rent and charges | One account per lease | Tenant(s), property address, lease ref and start date, arrears lines (period, rent, charges) | Guarantor (caution), deposit, *commandement de payer* date | `due` per period; `formal_notice` |
| Private loan between individuals | One account per loan | Lender (natural person → legal rate "particulier" when creditor is non-professional, INT-02), borrower, loan date, amount, written evidence | Contractual rate, schedule, payments received | Contract terms; `formal_notice` |
| Judgment debt | One account per title | Title kind, court, decision date, service date, amounts per head (principal, interest base/rate/start, art. 700, costs) | Date enforceable, prior enforcement recoveries | `judgment`, `judgment_served`, `judgment_enforceable` (+5 pts after 2 months, INT-03) |

Export of non-bank claims to the template is **not a regulatory obligation** (Art. 1 scope). For FCT data rooms we can still produce a best-effort tape (`3.05` Corporate/Consumer/Other, `3.06` *Trade receivables* for B2B invoices, non-applicable fields empty), flagged `non_regulatory`.

## 6. Layer-1 storage

- Schema `eba` (not exposed through the API). One table per template, one column per field, named `f<id>` (`f3_09`), typed (`text` raw value + parsed typed column where useful), plus `tape_id`, `boarding_batch_id`, `row_no`, and the resolved Layer-2 ids (`party_id`, `account_id`, `protection_id`, `mortgage_id`).
- `eba.field_catalogue` loaded from `eba_field_catalogue.csv` (with its SHA-256); `eba.extension_field` for `x.xx` rows agreed with a buyer.
- Raw tapes are kept immutable for the boarding batch's life (evidence of what the seller sent), subject to retention (GDPR-03).

## 7. Open questions for the founder

1. **Opening balance:** for a bank tape, is the collectible opening balance `3.12` legal balance, or `3.09 + 3.10 + 3.11`? Default proposed: post components, add the positive difference to `3.12` as `off_balance_legal_claim`, collect on `3.12`.
2. **Account grain for invoices:** one account per (client, debtor) with invoices as items (proposed), or one account per invoice? It drives letters, plans and the €40 per invoice.
3. **Seller breakdown files:** do sellers usually provide a component breakdown (unpaid instalments vs capital outstanding, fees vs indemnity) beyond the template? If not, which split rule do you use today?
4. **Seller forbearance vs our plans:** should our payment plans appear in `3.38`–`3.43` of a future export (they are forbearance from the owner's point of view), or only the seller's?
5. **Percentage format:** export `5 %` as `0.05` or `5.00`?
6. **Regulatory-grade vs servicing-grade boarding:** OK to treat template mandatory fields as warnings unless the client asks for a regulatory-grade tape?
