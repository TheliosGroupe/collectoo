# Calculation rules — claim types and rule packs

> **Status: draft, every legal reading and every number marked TO VALIDATE by the founder and counsel.**
> Legal texts read on 2026-11-07 via LibreJustice (Légifrance mirror). Legal obligations and their enforcement points: `docs/COMPLIANCE.md` (IDs like INT-05 refer there). Open questions: OQ-n in `docs/COMPLIANCE.md`.

## 1. Principles (from BRIEF §3.3)

- One engine, many **rule packs**. A rule pack is versioned **data** (YAML in the repo, loaded into `rule_pack` / `rule_pack_version` tables), never a code branch.
- The balance at any date = f(ledger events, rule-pack version effective at each date, rate tables). Nothing stored that can't be recomputed.
- Money: integer **cents** + currency. Rates: `Decimal`. Never floats.
- Every computed line in a statement of account (*décompte*) carries: component, base, rate, period, day count, legal/contract reference, rule-pack version.

## 2. Engine conventions (proposed defaults — TO VALIDATE)

| Topic | Default | Overridable by |
|---|---|---|
| Day count for late/legal interest | **Actual/365**; a period is `[start, end)`: `days = end − start` | Contract (e.g. 30/360, Actual/360 for some pro loans) |
| Day count for contractual instalment interest | As per the amortisation schedule (imported or rebuilt; monthly rate = annual/12) | Contract |
| Accrual posting | Interest accrued per **segment** (change of base, rate or rule) and posted at segment end | — |
| Rounding | Full `Decimal` precision inside a segment; **round half-up to the cent** when posting a segment | Rule pack (e.g. banker's rounding if a client's system uses it, for reconciliation) |
| Rate change inside a period | Split the period at the change date (legal rate semesters 1 Jan / 1 Jul; B2B ECB reference 1 Jan / 1 Jul; L313-3 +5 pts date) | — |
| Leap years | Actual/365 even in a leap year (French practice "année civile" vs 366 is a known debate) | Rule pack flag `leap_year_basis: 365 \| 366` — TO VALIDATE |
| Time zone | Business dates in Europe/Paris; timestamps stored UTC | — |

## 3. Claim types × rule-pack parameters

Legend: ✅ = text verified; ⚖️ = interpretation to validate; ❓ = not verified yet. "Contract" = taken from the contract data at boarding.

### 3.1 Bank credit

| Parameter | Consumer instalment loan | Revolving credit | Overdraft | BNPL / split payment | Mortgage (consumer) | Professional / SME loan |
|---|---|---|---|---|---|---|
| **Balance components** | capital outstanding, unpaid instalments (capital + interest split), contractual interest, late interest, statutory indemnity, insurance premiums (if financed in instalments), taxable costs (on proof) | drawn capital, accrued interest, late interest, statutory indemnity, taxable costs | debit balance, interest, late interest, indemnity, taxable costs | instalments due, fees allowed by contract and regime ❓ | capital outstanding, accrued interest, late interest, indemnity (cap), taxable costs | capital outstanding, unpaid instalments, contractual interest, late interest (contract), contractual indemnity (penalty clause), insurance, costs |
| **Allowed debtor charges** | **Only** L312-39 items + taxable costs; no flat recovery fees ✅ [L312-38](https://librejustice.fr/norm/fr/code-de-la-consommation/l312-38) | same regime as consumer credit ⚖️ | same ⚖️ | depends on whether in CCD scope (CCD2 widens it) ❓ | only L313-51 items + taxable costs ✅ [L313-52](https://librejustice.fr/norm/fr/code-de-la-consommation/l313-52) | per contract; penalty clauses reducible by the judge (Code civil 1231-5) ⚖️ |
| **Interest basis before acceleration** | contractual rate on schedule; late interest on unpaid instalments per contract ⚖️ OQ-4 | contractual rate | contractual rate | contract ❓ | contractual; or rate increase ≤ +3 pts if not accelerated ✅ [L313-50](https://librejustice.fr/norm/fr/code-de-la-consommation/l313-50), [R313-26](https://librejustice.fr/norm/fr/code-de-la-consommation/r313-26) | contractual + late margin (contract) |
| **Interest basis after acceleration** | late interest **at the loan rate** on sums remaining due ✅ [L312-39](https://librejustice.fr/norm/fr/code-de-la-consommation/l312-39) | same ✅ | same ⚖️ | ❓ | late interest at the loan rate ✅ [L313-51](https://librejustice.fr/norm/fr/code-de-la-consommation/l313-51) | contract (typically loan rate + margin) |
| **Start events** | due date; *déchéance du terme* (acceleration, after formal notice per contract/case law ⚖️); judgment; L313-3 +5 pts | same | same | same | resolution (acceleration); judgment | due date; acceleration; judgment |
| **Indemnity** | 8 % of capital outstanding at default if accelerated ✅ [D312-16](https://librejustice.fr/norm/fr/code-de-la-consommation/d312-16); else 8 % of unpaid instalments, 4 % of deferred ✅ [D312-17](https://librejustice.fr/norm/fr/code-de-la-consommation/d312-17) | same scale ⚖️ | same ⚖️ | ❓ | ≤ 7 % of capital outstanding + accrued unpaid interest ✅ [R313-28](https://librejustice.fr/norm/fr/code-de-la-consommation/r313-28) | contractual penalty clause ⚖️ |
| **Capitalisation** | **forbidden** (case law) ✅⚖️ INT-06 | forbidden ⚖️ | forbidden ⚖️ | ❓ | **forbidden** (case law) ✅⚖️ | allowed if contract/judgment provides, interest due ≥ 1 full year ✅ [1343-2](https://librejustice.fr/norm/fr/code-civil/1343-2) |
| **Limitation** | **2-year forclusion** for payment actions from the first unregularised payment incident (or other listed events) ✅ [R312-35](https://librejustice.fr/norm/fr/code-de-la-consommation/r312-35) | same, incl. unregularised over-limit ✅ | same, incl. unregularised overdraft past the L312-93 period ✅ | ❓ | **2-year prescription** for professionals vs consumers ✅ [L218-2](https://librejustice.fr/norm/fr/code-de-la-consommation/l218-2): each instalment from its due date; capital outstanding from acceleration ✅ [Cass. 1re civ. 11 Feb 2016, 14-22.938](https://librejustice.fr/decision/6D7SQL7uL4qx) | 5 years ✅ [Code de commerce L110-4](https://librejustice.fr/norm/fr/code-de-commerce/l110-4) (commercial) or [Code civil 2224](https://librejustice.fr/norm/fr/code-civil/2224) |
| **Allocation order** | interest before capital ✅ [1343-1](https://librejustice.fr/norm/fr/code-civil/1343-1); between debts ✅ [1342-10](https://librejustice.fr/norm/fr/code-civil/1342-10) | same | same | same | same | same, contract may specify |
| **Legal regime switch** | `pre_ccd2` vs `ccd2` by contract date vs 20 Nov 2026 ✅ [ord. 2025-880 art. 99](https://librejustice.fr/norm/fr/ordonnance-n-2025-880-du-3-septembre-2025-relative-au-credit-a-la-consommation/99) | open-ended contracts running at 20 Nov 2026 get some new articles ✅ (art. 99 III) | same ✅ | CCD2 brings more BNPL into scope ❓ | — | — |

### 3.2 Civil and commercial claims

| Parameter | B2B invoice | B2C invoice / subscription | Rent and charges | Private loan between individuals | Judgment debt (enforceable title) |
|---|---|---|---|---|---|
| **Balance components** | principal (TTC), late-payment penalties, €40 flat indemnity, further costs on proof | principal (TTC), legal-rate late interest, contractual penalty clause if any ⚖️ | rent arrears, charges, legal-rate interest ⚖️ | principal, contractual interest (if written), legal-rate interest | principal, interest per judgment, costs (art. 700 CPC, dépens), enforcement costs |
| **Allowed debtor charges** | €40 ✅ [D441-5](https://librejustice.fr/norm/fr/code-de-commerce/d441-5) + proven extra costs ✅ [L441-10](https://librejustice.fr/norm/fr/code-de-commerce/l441-10); **no** other recovery fees without title ✅ [L111-8](https://librejustice.fr/norm/fr/code-des-procedures-civiles-d-execution/l111-8) ⚖️ OQ-2 | **no** recovery fees without title ✅ L111-8 | **no** recovery fees without title | **no** recovery fees without title | enforcement costs on the debtor (L111-8 al. 1) ✅ |
| **Interest basis** | contract rate (≥ **3 × legal rate**) or ECB MRO **+10 pts** (rate at 1 Jan for H1, 1 Jul for H2) ✅ L441-10 II | **legal rate** "other cases" (creditor is a professional) ✅ [L313-2](https://librejustice.fr/norm/fr/code-monetaire-et-financier/l313-2) | legal rate ⚖️ | contract (written) or legal rate; consumer-creditor rate if the lender is a private individual ✅ L313-2 | legal rate (creditor-status dependent) **+5 pts** from 2 months after enforceability ✅ [L313-3](https://librejustice.fr/norm/fr/code-monetaire-et-financier/l313-3) |
| **Start events** | day after the payment date on the invoice, **no reminder needed** ✅ | **mise en demeure** ✅ [1231-6](https://librejustice.fr/norm/fr/code-civil/1231-6), [1344](https://librejustice.fr/norm/fr/code-civil/1344) | mise en demeure ⚖️ | per contract / mise en demeure | judgment date / date set by the judgment; +5 pts trigger |
| **Capitalisation** | if contract/judgment provides, ≥ 1 year ✅ 1343-2 | same ✅ (consumer-protection limits to check ⚖️) | same ⚖️ | same | if the judgment orders it |
| **Limitation** | 5 years ✅ L110-4 / 2224 | **2 years** ✅ L218-2 | **3 years** ✅ [Loi 89-462 art. 7-1](https://librejustice.fr/norm/fr/loi-n-89-462-du-6-juillet-1989-tendant-a-ameliorer-les-rapports-locatifs-et/7-1) (residential lease) | 5 years ✅ 2224 | **10 years** for execution ✅ [CPCE L111-4](https://librejustice.fr/norm/fr/code-des-procedures-civiles-d-execution/l111-4) |
| **Insolvency of debtor** | interest stops; €40 not claimable when payment barred ✅ [L622-28](https://librejustice.fr/norm/fr/code-de-commerce/l622-28), L441-10 | n/a (consumer → surendettement hold) | surendettement exception for rent with court-granted delays ✅ [L722-5](https://librejustice.fr/norm/fr/code-de-la-consommation/l722-5) al. 3 | — | — |
| **Allocation order** | interest first ✅ 1343-1; €40 position ⚖️ OQ-7 | interest first ✅ | ⚖️ | interest first ✅ | per judgment / 1343-1 |

## 4. Rate tables (verified values only)

### 4.1 Legal interest rate ([CMF L313-2](https://librejustice.fr/norm/fr/code-monetaire-et-financier/l313-2))

| Semester | Creditor = natural person, non-professional | All other cases | Source (arrêté) |
|---|---|---|---|
| 2025 H1 | 7.21 % | 3.71 % | [Arrêté du 17 déc. 2024, art. 1](https://librejustice.fr/norm/fr/arrete-du-17-decembre-2024-relatif-a-la-fixation-du-taux-de-l-interet-legal/1) |
| 2025 H2 | 6.65 % | 2.76 % | [Arrêté du 19 juin 2025, art. 1](https://librejustice.fr/norm/fr/arrete-du-19-juin-2025-relatif-a-la-fixation-du-taux-de-l-interet-legal/1) |
| 2026 H1 | 6.67 % | 2.62 % | [Arrêté du 15 déc. 2025, art. 1](https://librejustice.fr/norm/fr/arrete-du-15-decembre-2025-relatif-a-la-fixation-du-taux-de-l-interet-legal/1) |
| 2026 H2 | 6.84 % | 2.75 % | [Arrêté du 26 juin 2026, art. 1](https://librejustice.fr/norm/fr/arrete-du-26-juin-2026-relatif-a-la-fixation-du-taux-de-l-interet-legal/1) |
| Earlier semesters | *to load from the arrêtés (2015 H1 onward = two-rate system)* | | TODO M3 |

The 2025 H2 "other cases" figure (2.76 %) was read from a search snippet; re-check against the full arrêté when loading the table.

### 4.2 ECB main refinancing operations rate (for L441-10)

**Not verified** (the ECB site is outside the current network allowlist). Values for 1 Jan and 1 Jul of each year must be loaded from the ECB with source links before the B2B rule pack ships. Worked example 3 avoids this by using a contractual rate.

## 5. Rule-pack schema (sketch)

```yaml
# rule_packs/b2b_invoice/2026-09-01.yaml   (illustrative, TO VALIDATE)
id: b2b_invoice
version: 2026-09-01            # = effective_from
effective_from: 2026-09-01
effective_to: null
legal_regime: commercial_b2b
references:
  - {code: "Code de commerce", article: "L441-10", version_from: "2026-09-01",
     url: "https://librejustice.fr/norm/fr/code-de-commerce/l441-10"}
  - {code: "Code de commerce", article: "D441-5",
     url: "https://librejustice.fr/norm/fr/code-de-commerce/d441-5"}
components:
  - id: principal
    kind: principal
  - id: late_penalty
    kind: interest
    base: [principal]                        # interest never on interest unless capitalisation
    rate:
      source: contract_or_default
      contract_floor: {multiplier: 3, of: legal_rate_other}      # L441-10 II
      default: {index: ecb_mro, fixing: semester_start, margin_bp: 1000}
    start: {event: due_date, offset_days: 0}  # accrues from due date; payable from D+1
    day_count: ACT/365
    stops_on: [collective_proceeding_opened]  # L622-28 (debtor loans <1y)
    ref: L441-10
  - id: b2b_flat_indemnity
    kind: statutory_indemnity
    amount_cents: 4000
    per: invoice                              # OQ-6
    blocked_by_holds: [collective_proceeding]
    ref: D441-5
  - id: recovery_fee
    kind: recovery_fee
    debtor_chargeable: requires_enforceable_title   # L111-8 al. 2
capitalisation: {allowed: contract_or_judgment, min_period: P1Y}  # 1343-2
allocation_order: [late_penalty, b2b_flat_indemnity, principal]   # 1343-1; OQ-7
limitation:
  - {type: prescription, period: P5Y, from: due_date, ref: "L110-4"}
rounding: {mode: HALF_UP, at: segment_posting}
```

Validation rules on load (schema + semantic):
- every component has a legal or contract reference;
- `capitalisation.allowed` must be `false` for regimes `consumer_credit_*` and `consumer_mortgage` (INT-06);
- consumer-credit packs may only declare whitelisted component kinds (INT-05);
- no `recovery_fee` with `debtor_chargeable: true` (CPCE-09);
- effective date ranges of versions of one pack never overlap.

## 6. Worked examples (all results TO VALIDATE)

Computed with Python `Decimal`, round half-up to the cent at each posting. Script kept with the engine golden tests in M3.

### Example 1 — Consumer instalment loan (pre-CCD2 regime)

**Inputs**
- Contract signed 2023-03-01 → regime `consumer_credit_pre_ccd2` (before 2026-11-20).
- Principal 10 000.00 €, fixed nominal rate 6.00 %/yr, 48 monthly instalments, first due 2023-04-05. No insurance.
- Instalment = 10 000 × 0.005 / (1 − 1.005⁻⁴⁸) = **234.85 €** (monthly interest = CRD × 0.5 %, rounded to the cent).
- Instalments #1–#29 paid (last paid: #29 due 2025-08-05). Unpaid: #30 (2025-09-05), #31 (2025-10-05), #32 (2025-11-05).
- Acceleration (*déchéance du terme*) effective **2025-12-10**, after a formal notice.
- Statement date **2026-03-10**. No payment since.

**Schedule extract (cents)**

| # | Due | Instalment | Interest | Capital | CRD after |
|---|---|---|---|---|---|
| 29 | 2025-08-05 | 23 485 | 2 230 | 21 255 | 424 666 |
| 30 | 2025-09-05 | 23 485 | 2 123 | 21 362 | 403 304 |
| 31 | 2025-10-05 | 23 485 | 2 017 | 21 468 | 381 836 |
| 32 | 2025-11-05 | 23 485 | 1 909 | 21 576 | 360 260 |

**Computation**
1. Capital due on acceleration = CRD after the last paid instalment (#29) = **4 246.66 €** (= capital inside unpaid #30–#32 644.06 + CRD after #32 3 602.60).
2. Accrued unpaid contractual interest (#30–#32) = 21.23 + 20.17 + 19.09 = **60.49 €** ([L312-39](https://librejustice.fr/norm/fr/code-de-la-consommation/l312-39): "majoré des intérêts échus mais non payés").
3. Late interest at the loan rate, on capital only (no interest on interest, INT-06), from 2025-12-10 to 2026-03-10 = 90 days, ACT/365: 4 246.66 × 6 % × 90/365 = **62.83 €**.
4. Indemnity 8 % of "capital restant dû à la date de la défaillance" ([D312-16](https://librejustice.fr/norm/fr/code-de-la-consommation/d312-16)), read as CRD after the last *due* instalment: 3 602.60 × 8 % = **288.21 €** (alternative reading on 4 246.66 → 339.73 €; OQ-5).
5. Interest on unpaid instalments between their due dates and acceleration: **not included** (OQ-4).

**Statement at 2026-03-10: 4 246.66 + 60.49 + 62.83 + 288.21 = 4 658.19 € — TO VALIDATE**

### Example 2 — Professional / SME loan

**Inputs**
- Borrower: SARL (legal entity). Lender: bank. Contract signed 2022-06-01.
- 50 000.00 €, fixed 4.20 %/yr, 60 monthly instalments, first due 2022-07-10. Instalment **925.35 €**.
- Contract clauses (assumed for the example): late interest = loan rate **+3 pts = 7.20 %** on sums due after acceleration; contractual indemnity **5 %** of sums due at acceleration (penalty clause, reducible by the judge under Code civil 1231-5); **annual capitalisation** clause (1343-2).
- Paid through #38 (2025-08-10). #39 (2025-09-10) unpaid. Acceleration **2025-09-30**. Statement date **2026-10-31**. No payment, no insolvency.

**Schedule extract (cents)**

| # | Due | Instalment | Interest | Capital | CRD after |
|---|---|---|---|---|---|
| 38 | 2025-08-10 | 92 535 | 7 145 | 85 390 | 1 956 047 |
| 39 | 2025-09-10 | 92 535 | 6 846 | 85 689 | 1 870 358 |

**Computation**
1. Capital due on acceleration = CRD after #38 = **19 560.47 €**. Accrued unpaid contractual interest (#39) = **68.46 €**.
2. Contractual indemnity 5 % × (19 560.47 + 68.46) = **981.45 €** (base per assumed clause).
3. Late interest year 1, 2025-09-30 → 2026-09-30 = 365 days, ACT/365: 19 560.47 × 7.20 % × 365/365 = **1 408.35 €**.
4. Capitalisation on 2026-09-30 (interest due for a full year, clause in contract): 1 408.35 + 68.46 (due since 2025-09-10, > 1 year) = 1 476.81 € become capital-like and bear interest.
5. 2026-09-30 → 2026-10-31 = 31 days: on capital 19 560.47 × 7.20 % × 31/365 = **119.61 €**; on capitalised interest 1 476.81 × 7.20 % × 31/365 = **9.03 €**.
6. Late interest on #39 between 2025-09-10 and 2025-09-30: not included (contract-dependent).

**Statement at 2026-10-31: 19 560.47 + 68.46 + 981.45 + 1 408.35 + 119.61 + 9.03 = 22 147.37 € — TO VALIDATE**

### Example 3 — B2B invoice

**Inputs**
- Supplier SAS invoices client SARL **12 000.00 € TTC**, issued 2026-03-02, payment date on invoice **2026-04-01** (30 days).
- Supplier's terms: penalties at **3 × the legal interest rate** (the statutory floor), applied per semester (⚖️ whether the multiplier follows each semester's rate). Legal rate "other cases": 2026 H1 **2.62 %** → 7.86 %; 2026 H2 **2.75 %** → 8.25 % (verified, §4.1).
- Debtor pays **5 000.00 €** on 2026-06-15. Statement date **2026-10-31**.

**Computation**
1. Penalties 2026-04-01 → 2026-06-15 = 75 days: 12 000.00 × 7.86 % × 75/365 = **193.81 €**.
2. €40 flat indemnity due (debtor late, [L441-10](https://librejustice.fr/norm/fr/code-de-commerce/l441-10) II, [D441-5](https://librejustice.fr/norm/fr/code-de-commerce/d441-5)): **40.00 €**.
3. Allocation of 5 000.00 (interest first, [1343-1](https://librejustice.fr/norm/fr/code-civil/1343-1); then indemnity, then principal — OQ-7): 193.81 → penalties, 40.00 → indemnity, **4 766.19 → principal**. Principal left **7 233.81 €**.
4. 2026-06-15 → 2026-07-01 = 16 days at 7.86 %: 7 233.81 × 7.86 % × 16/365 = **24.92 €**.
5. 2026-07-01 → 2026-10-31 = 122 days at 8.25 %: 7 233.81 × 8.25 % × 122/365 = **199.47 €**.

**Statement at 2026-10-31: 7 233.81 + 24.92 + 199.47 = 7 458.20 € — TO VALIDATE** (no collection fees: L111-8).

### Example 4 — B2C invoice (energy subscription)

**Inputs**
- Supplier (professional) → consumer. Invoice **480.00 € TTC**, due 2026-02-10. No contractual penalty clause.
- Formal notice (*mise en demeure*) received **2026-03-20** (OQ-3: who sends it and how).
- Legal rate "other cases" (creditor is a professional): 2.62 % (2026 H1), 2.75 % (2026 H2). Statement date **2026-09-30**. No payment.

**Computation**
1. Legal interest from the formal notice ([1231-6](https://librejustice.fr/norm/fr/code-civil/1231-6)), 2026-03-20 → 2026-07-01 = 103 days: 480.00 × 2.62 % × 103/365 = **3.55 €**.
2. 2026-07-01 → 2026-09-30 = 91 days: 480.00 × 2.75 % × 91/365 = **3.29 €**.
3. No €40 (B2B only), no collection fees (L111-8), no capitalisation (< 1 year).
4. Limitation: 2 years ([L218-2](https://librejustice.fr/norm/fr/code-de-la-consommation/l218-2)), from when the creditor knew or should have known (Code civil 2224 start rule, ⚖️) → indicative deadline **2028-02-10**; interrupting events (acknowledgement, payment) to be tracked.

**Statement at 2026-09-30: 480.00 + 3.55 + 3.29 = 486.84 € — TO VALIDATE**

## 6b. Allocation of payments (imputation) — M2b-4, M2b-6

Implemented by the pure waterfall `worker/src/collectoo_worker/payments/allocation.py` (engine version `alloc-1`), posted by the job `payments.allocate` (ADR-0013, M2b-4 addendum; design `docs/design/m2b-payments.md` §8.5). Texts (read on LibreJustice, quoted in the design §3): C. civ. [1342-10](https://librejustice.fr/norm/fr/code-civil/1342-10), [1343-1](https://librejustice.fr/norm/fr/code-civil/1343-1), [1305-3](https://librejustice.fr/norm/fr/code-civil/1305-3), [1347](https://librejustice.fr/norm/fr/code-civil/1347), [1347-1](https://librejustice.fr/norm/fr/code-civil/1347-1), [1347-4](https://librejustice.fr/norm/fr/code-civil/1347-4) (« S'il y a plusieurs dettes compensables, les règles d'imputation des paiements sont transposables. »).

**Order (not configurable: founder #5, OQ-19).**
1. **Debts** = claim items of the file. First the items the debtor **designated** when paying (invoice numbers in the remittance text, or a document ops filed) — an item not yet due included (1305-3: the term benefits the debtor). Among them the legal order of points 2–4 decides (due before not due, oldest first, equal ones pro rata): a designation names debts, not an order or amounts per debt, so the order it was stored in plays no part. The rest follows the legal order.
2. Then **due items** (due date ≤ the allocation date), **oldest due date first**, then oldest issue date (« la plus ancienne », OQ-21; « plus d'intérêt d'acquitter » is not encoded). An item without a due date counts as due, after the dated ones (a defaulted loan's single item). An unknown issue date sorts last.
3. Equal keys form one **tie group, shared pro rata** to its items' open amounts (« toutes choses égales, elle se fait proportionnellement »).
4. Then **items not yet due**, by due date.
5. **Inside each item**: interest family first (1343-1); then the accessories (indemnity, charge, cost) where the policy ranks them — `before_principal` by default (§6 example 3; OQ-7 for the B2B €40, which does not exist before M3); principal; then the seller's **unclassified** amounts (EU 3.11, balancing line) — **never by allocation for consumer loans** (regimes `consumer_credit_*`, `consumer_mortgage`) until ops classify them (founder #6, OQ-18).

**Pro rata to the cent (largest remainder).** For a group of demand D and an amount R < D: share_i = ⌊R × d_i / D⌋ in exact integers, then one minor unit to each item by decreasing remainder (R × d_i mod D), ties by item id, until Σ shares = R. Each share is spent in its item's family order. Example: 300,01 € on two invoices of 500,00 € due the same day → 150,01 € and 150,00 €.

**Available amount.** On a receivable at the allocation date D: the lowest running balance from D on (an allocation dated D never makes a later date negative). Items or components at or below zero (credit notes, overpaid invoices, a negative balancing line) are not paid. **An item as a whole** is paid at most its net: the lowest running balance from D on of the sum of all its components, held and negative ones included (an EU loan's components add up to the legal balance 3.12 through a signed balancing line; a negative principal nets a positive balancing line). The excess is trimmed from the item's lowest-ranked components first (interest last, 1343-1) and stays unallocated: an overpayment (below; C. civ. [1302-1](https://librejustice.fr/norm/fr/code-civil/1302-1)). Example: principal 5 000,00 €, interest 120,00 €, balancing line −220,00 € (3.12 = 4 900,00 €); 5 120,00 € paid → interest 120,00, principal 4 780,00, overpayment 220,00. Netting inside one item is not compensation (it is one debt); between items it is (credit notes, below). **Allocation date** = the booking date, or the servicing start if later (a payment before the cut-off waits for ops: founder #10).

**What is not allocated stays unallocated.** If every payable slot is exhausted, the rest is an **overpayment**: it stays in pooled 4710 tagged by the payment, is never passed to the client (founder #8), and is refunded to the payer (M2b-6) or, on the debtor's written request, allocated on another file of his (same client).

**Credit notes (1347).** A credit (credit note, overpaid invoice) is compensated only when invoked: proposed per file — the oldest credit against the first group of **due** invoices in the order above (1347-1: « exigibles »; 1347-4: the imputation rules transpose), pro rata on ties — dated when both were due, not before servicing start, principal only — and applied by one ops tap. Payments of a file with a pending proposal wait until it is applied (or ops allocate without it).

**Worked example (design §8.2, test `worker/tests/test_allocation_integration.py`).** M-0042 (B2B): F-101 1 500,00 € due 10/06, F-102 800,00 € due 15/07, F-103 400,00 € due 20/08, F-104 300,00 € due 15/12, AV-105 −200,00 €. AV-105 applied on F-101 at the cut-off (F-101 → 1 300,00 €). P1 2 000,00 € citing F-103 → F-103 400,00, F-101 1 300,00, F-102 300,00; F-104 is not due and not reached. L-9 (consumer credit): interest 120,00, principal 5 000,00, other balances 30,00; P2 5 200,00 € → interest 120,00, principal 5 000,00; the 30,00 are held; 80,00 € overpayment.

**Returns, refunds and payments made to the client directly (M2b-6, design §2 #3, §8.1; founder #8, #13).**
- **A bank return or chargeback undoes the allocation on the return date** (never back-dated: the ledger follows the bank, and a later remittance (M2c) may already have used the money): each live allocation of the payment is reversed at the return date (an allocation dated after it, at its own date), the receivables come back from that date, then the money leaves (`cash_out`) at the return date. Whether interest runs as if the payment had never been made is M3 and OQ-25. Example (design §8.2 variant B): P1 2 000,00 € allocated on 12/10 (F-103 400,00, F-101 1 300,00, F-102 300,00), returned by the bank on 03/11 → three receivables back up by the same amounts **on 03/11**; between 12/10 and 03/11 the ledger shows them paid.
- **A partial return** reverses every allocation of the payment the same way and leaves the rest of it waiting for ops: « Imputer » allocates the rest **from the return date** (the money was allocated until then: an allocation dated earlier would overdraw the payment, `LG007`), in the order above, or ops refund it. Example: 500,00 € allocated on 05/10 (F-1 300,00, F-2 200,00), 200,00 € returned on 03/11 → both reversed on 03/11; « Imputer » → F-1 300,00 on 03/11.
- **A refund** never takes more than what is left of the payment unallocated (`LG007`) and is booked at the date of its debit on the statement; it touches no receivable. A refund that comes back unpaid puts the money back on the payment (its earlier reason: an overpayment again).
- **A payment the debtor made to the client directly** (the client's statement, evidence filed on the file) lowers the receivables at the date the statement gives, by the same waterfall: the invoices it names first (designation), then due invoices oldest first, then not yet due; interest first inside each. It is refused when it exceeds what the file owes at that date (nothing is an overpayment of ours: the client refunds its debtor). No client money moves (an `adjustment`: −1100 / +3100), so no receipt and no notification. Example: F-1 300,00 € due 01/07, F-2 200,00 € due 01/08; 250,00 € paid to the client on 20/10 for F-2 → F-2 200,00, F-1 50,00.

**Re-run by date (M3, founder #16).** The waterfall is a pure function of (amount, slots at D, policy, designation, D); each allocation entry keeps its inputs hash and its plan (policy, designation). M3-13 re-allocates earlier payments by reversing their entries at their dates and posting the waterfall's result on the balances including accrued interest; with nothing changed, a re-run gives the same lines (property and integration tests).

## 7. Commission (M2c-3, M2-13)

The servicer's remuneration, charged to the **client** (never to a debtor: L111-8, CPCE-09), computed by the pure engine `worker/src/collectoo_worker/remittance/commission.py` (engine version `commission-1`) from the mandate's schedule (`mandate_terms.commission_schedule`, schema `commission-1`, clause reference R124-3 3°; ADR-0014 M2c-2, M2c-3; design `docs/design/m2c-remittances.md` §8). No legal rate, cap or minimum exists: the agreement decides (design §3.2 #10). **Every example below is a golden case in `worker/tests/golden/commission/` and is TO VALIDATE until the founder's anonymised clauses replace the synthetic ones (risk R13).**

**What earns commission (founder #4).** What is allocated to the client's claims: the allocation's 1100 credits per component family, limited to the families the schedule names (`basis.families`). Money passed on without allocation (a forward: file recalled, payment before the servicing start, the client's ratification) only when the schedule lists that reason; payments made to the client directly never. A reversal's basis is minus its original's (`on_reversal: credit`, founder #6: a credit note on the invoice that charged the collection). What it gives back is what the collection adds to the file, by the cumulative function below: across tiers and the minimum it is not necessarily what the original line was charged (design §2.2 #8) — it is exactly that when nothing else changed on the file since. Unless the mandate's clause keeps the fee (`keep`, OQ-39): see below. Advances, returned and unplanned payouts never earn anything. An item with no terms in force on its date earns nothing and is remitted gross (an alert in M2c-4).

**Which rule.** Per component family of the line, the first rule that matches the file's claim type, the family and the portfolio; the last rule matches everything. A forward has no family: rules that filter on families skip it. Each rule has a **tier key**, stable across versions, so tiers continue when the terms change.

**Which version.** The one in force on the line's **encaissement date** (E, §9.2 of the design: the earlier of the payment's booking and value dates). New versions start tomorrow at the earliest: never retroactive (founder #5).

**The cumulative function.** Per version v of the terms and per (file, tier key), with `c` a commissionable basis in integer cents:

| Rate kind | g(c) |
|---|---|
| `flat` | r × c |
| `marginal` (tiers on what the file brought in) | Σ rᵢ × (part of c between lᵢ and uᵢ) |
| `bracket` (one rate set at boarding by the boarded amount or the claim's age; a bound is included, « jusqu'à ») | r(attribute) × c |

Inside one version, F(c) = 0 if c = 0, else min(max(m, R(g(c))), ⌊c / (1 + τ)⌋), with m the minimum per file, τ the VAT rate and R the rounding **half-up to the cent, once per value of F** (the sum over the bands is exact before it).

**A function of the live lines (review fixes, 2026-11-10).** The commission of a (file, tier key) depends only on its lines still live, never on how they fell into runs. Take them in order of encaissement date: each is priced by the version in force on its date (new rates only for the future, founder #5), and each version's tiers continue where the earlier versions' net basis ends (the tier key is stable across versions). Versions never overlap, so each version's lines are consecutive in that order. With b_v the net basis brought in under v, C_<v and C_≤v the net basis of the versions before v and up to v, C the file's net basis, and g_v the exact (unrounded) rate function of version v:

K° = Σ_v [g_v(C_≤v) − g_v(C_<v)] — the rates alone, never rounded; K°_≤v the same sum over the versions up to v
top = max(0, the largest m_v − K°_≤v over the versions v with b_v > 0)
K = min( R(K° + top) , ⌊C / (1 + τ)⌋ )

The minimum and the rounding are taken **once, on the file** (second review): no longer per version, where a minimum a new version introduced counted as already used by the collections made before it (1 400,00 € collected across the change earned 40,00 €, and undoing the 400,00 € collected before it then invoiced 260,00 €). **Each version's minimum is a floor on what the collections up to that version earn, and later collections earn their own rates on top** (TO VALIDATE, `minimum-new-version`): a minimum introduced on 16/11 applies to a file collected on both sides of the change exactly as to a file collected after it only (300,00 €), and a minimum dropped on 16/11 stays earned by the collections before the change while those after it add their 10 % (400,00 €; undoing the first gives back its 300,00 €). The review proposed the minimum of the version of the file's latest live collection instead; we did not take it, because a later version without a minimum would then let a payment lower the commission (a credit note because money came in) and its reversal raise it. Inside one version K = F(total collected).

Each run charges what K says, within the rounding reserve below. Hence:
- **However the lines fall into runs**, and in whatever order the runs come, the file ends charged K of its live lines (Hypothesis, `worker/tests/test_commission.py`); inside one version K = F(total collected): a file's commission telescopes.
- **Undoing a collection** removes its basis from its own version (its encaissement date is its original's) and gives back K(with it) − K(without it): exactly its own charge when nothing else changed on the file since; a file undone in full is back to 0. Because later versions' tiers continue from the earlier ones, undoing a collection made before a change can move the later collections down into the new grid's lower tiers (`cross-version-cap`), and a collection dated before a change and booked after it moves them up: a collection can then lower the commission, a reversal raise it. That follows from « tiers on what the file brought in, net of reversals » with new rates only for the future, and happens only across a change of a marginal grid (TO VALIDATE): with flat or bracket rates, minimums included, a reversal never raises the commission and a collection never lowers it (property, with and without VAT). A collection charged in one run and undone in the next gives back exactly its charge, VAT reserve included (property); the one exception is a collection that lowered the commission across a change of marginal grid on a file at its hold, whose undoing gives back at most 1 cent less (it needs an invoice, whose VAT rounding the reserve must cover), released at the file's next collection.
- **The cap** keeps K within ⌊C / (1 + τ)⌋ for the file as a whole, versions included (an 80 % rate followed by a 100 % tier would otherwise charge more than the file brought in).
- **The rounding reserve: the TTC billed never exceeds what the file brought in, across runs.** Each invoice rounds its own VAT (R(HT × τ), 242 nonies A 11°), which can add up to ½ cent to a file's share, and up to 1 cent once the invoice is partly credited. So what the file is charged, V, is also held within ⌊(C − n) / (1 + τ)⌋, n the file's invoices **still open once the run's documents are issued**: the earlier ones its credit note does not take back in full, plus the run's invoice when the file has an amount on it (second review: counting the run's invoice when the file has none on it deepened the hold, so that a kept reversal issued a credit note of 0,01 € and a reversal gave back more than its collection was charged). Since n depends on V (what the run charges decides what it credits and invoices), the engine takes the largest V ≤ K whose own documents' n holds it, simulating the run's documents for the file on what its earlier invoices still charge (the same history the documents are drawn from). The file's open HT plus its share of those invoices' VAT (in proportion to what each still charges it) then never exceeds C. For a file alone on its mandate that is its invoices' TTC net of credit notes, to the cent (property over any partition into runs). The hold binds only near the cap — the minimum per file on a small file — is at most ⌈(n + 1) / 1,2⌉ cents, n the invoices open before the run, and is released only by a run in which the file has a collection, as soon as the basis leaves room. The hold is taken from the file's positive parts of the run, last to first, never below 0 — only what they cannot absorb from its reversals — so a run of collections never issues a credit note (second review: it was taken from one part, which could become −0,01 €).
- **Fees kept by the clause** (`keep`, OQ-39): the undone basis leaves the tier position (net of reversals, design §8.1), so what is collected afterwards is priced in the tier the undone money occupied, not pushed into a lower one; what the reversal would have given back stays charged (κ). The minimum per file is charged once: K = max(R(K° + top), R(K°) + κ) — the rates plus κ, or the minimum, whichever is more — capped on the gross basis (net plus kept). With VAT a kept reversal never issues a credit note (property). Example: 1 % with a minimum of 300,00 €, 1 000,00 € collected (300,00), undone (kept), 1 000,00 € collected again: 10,00 € more, 310,00 € in all.

**Documents (§8.4).** Invoice lines group (claim type, rule, families), with the base that moved in each rate band of the collections' own versions. **A change of terms that re-tiers later collections** (a collection dated before the change booked after them, or one undone) never shows as a negative band (« 5 % sur −5 000,00 € », which is not « la dénomination précise » of 242 nonies A 8°, read on LibreJustice in its version in force since 2025-01-01): the collection's line shows its own band (« 10 % sur 5 000,00 € », 500,00 €) and the re-tiering is a separate line « Régularisation de paliers (changement de conditions) » with its net HT and no bands (750,00 €; `version-change-retiering`, TO VALIDATE). When the re-tiering lowers the commission it is credited like any decrease, and an undone collection's own fee is credited on its invoice even when undoing it re-tiers later collections upward (a credit note for its own fee, an invoice for the regularisation: never netted). Invoice VAT = R(HT × rate) at the rate of the issue date (`public.vat_rate`, rule pack `worker/rule_packs/vat/fr.yaml`; OQ-70). Per (mandate, file, tier key) the parts that raise the commission go to the invoice and the parts that lower it to the credit note — never netted across documents (founder #6; CGI 289 I 5, a document that modifies the initial invoice « fait référence à la facture initiale de façon spécifique et non équivoque »; CGI 272 1, the VAT given back on « la rectification préalable de la facture initiale »). Only what was never invoiced is netted inside the run: a reversal of a collection of the same run, and a credit beyond what earlier invoices charge the key. A reversal's credit (its own fee and what it takes back by re-tiering) goes first to the invoice that charged the collection it undoes, up to what that invoice still charges the key — every reversal of the run on its own original's invoice before any credit is allocated LIFO, so that no other credit takes it — and the rest LIFO; the credit note's VAT on each corrected invoice is R(credited HT after × its rate) − R(credited HT before × its rate): never above the invoice's VAT, exactly it on a full credit. Nothing is issued when every amount of a mandate is 0. Numbering, posting and PDFs are M2c-4 and M2c-5.

**Worked examples (golden cases, all TO VALIDATE).**

| Case | Grid | Collections | Commission HT |
|---|---|---|---|
| `worked-example-7-2` (design §7.2) | Martin 15 % flat | M-0042 2 000,00 € (RV-1); M-0077 3 000,00 € and M-0042 undone (RV-3) | FC-1 300,00 € + 60,00 € VAT; FC-3 450,00 €; FC-4 credit note −300,00 € −60,00 € on FC-1 |
| idem | Lilas 10 % to 5 000,00 € then 6 %, minimum 30,00 € | L-9 5 120,00 € (interest 120,00) | 500,00 + 7,20 = 507,20 € (FC-2, 101,44 € VAT) |
| `claim-type-and-family-rates` | B2B 15 %; interest 20 %; other 10 %; basis principal + interest | B2B file 1 140,00 € (charge 40,00 excluded); loan 570,00 € (interest 50,00, charge 20,00) | 165,00 €; 10,00 + 50,00 € |
| `marginal-tiers-crossed` | 10 % to 5 000,00 €, then 6 % | 4 000,00 €, then 2 000,00 € (crosses), then the first undone, then the second | 400,00; 160,00; −360,00 (on the first invoice, which charged it); −200,00 (160,00 on the second, then 40,00 on the first) |
| `brackets` | boarded ≤ 5 000,00 € 12 %, else 8 %; age ≤ 365 d 15 %, ≤ 1 095 d 20 %, else 25 % | 100,00 € on six files | 12,00 / 12,00 (exactly 5 000,00) / 8,00 / 15,00 / 20,00 (exactly 1 095 d) / 25,00 € |
| `minimum-capped` | 5 %, minimum 30,00 € | 20,00 €, then 80,00 €, then 1 000,00 €, then all undone; a small file collecting 1,00 € in each of three runs | 16,65 € (⌊(20,00 − 0,01) / 1,2⌋, one open invoice); 13,35; 25,00; back to 0; 0,82 + 0,83 + 0,82 (TTC 2,96 € for 3,00 €, never above) |
| `version-change` | 15 % until 15/11, 12 % from 16/11 | 1 000,00 € on 10/11 and on 20/11; the first undone | 150,00 + 120,00; −150,00 (credited at the old rate) |
| `version-change-partial-reversal` | 10 % to 5 000,00 € then 6 % until 15/11, 8 % flat from 16/11 | 5 000,00 € on 10/11, 5 000,00 € on 20/11, the first undone; the same three lines in one run on a second file | 500,00; 400,00; −500,00 on the first invoice: 400,00 left, as for the second file in one run |
| `minimum-new-version` | 10 % until 15/11, then 10 % with a minimum of 300,00 € (MAND-N); the reverse (MAND-D) | MAND-N: 400,00 € on 10/11, 1 000,00 € on 20/11, the first undone; a second file collected on 20/11 then 400,00 € dated 10/11. MAND-D: 400,00 € on 10/11, 1 000,00 € on 20/11, the first undone | MAND-N: 40,00; 260,00 (300,00 in all, as for the second file); 0 and 0 (no invoice, no credit note). MAND-D: 300,00; 100,00; −300,00 |
| `version-change-retiering` | 10 % until 15/11, then 5 % to 5 000,00 € and 20 % beyond (MAND-R); then 20 % to 5 000,00 € and 5 % beyond (MAND-S) | MAND-R: 5 000,00 € on 20/11, then 5 000,00 € dated 10/11 booked later, then that one undone. MAND-S: 5 000,00 € on 10/11, 5 000,00 € on 20/11, the first undone | MAND-R: 250,00; invoice « 10 % sur 5 000,00 € » 500,00 + « Régularisation de paliers (changement de conditions) » 750,00; credit note −1 250,00 on that invoice. MAND-S: 500,00; 250,00; credit note −500,00 on the first invoice and invoice « Régularisation de paliers » 750,00 |
| `cross-version-cap` | 80 % until 15/11, then 0 % to 5 000,00 € and 100 % beyond | 5 000,00 € on 10/11, 5 000,00 € on 20/11, the first undone | 4 000,00; 4 333,31 (capped: ⌊(10 000,00 − 0,02) / 1,2⌋ in all); −8 333,31 (the second collection is now the new grid's free first tier) |
| `same-run-credit-and-invoice` | 15 %; and 15 % until 15/11 then 12 % | 1 000,00 €, then in one run that collection undone and 2 000,00 € collected | invoice 300,00 (240,00 under the new terms) and credit note −150,00 on the original invoice, not one netted amount |
| `reversal-keep` | 10 %, `on_reversal: keep` | 1 000,00 €, undone, collected again | 100,00; 0; 100,00 |
| `reversal-keep-marginal` | 10 % to 5 000,00 € then 6 %, `keep`; 1 % with a 300,00 € minimum, `keep` | 5 000,00 €, undone, collected again; 1 000,00 €, undone, collected again | 500,00; 0; 500,00 (the first tier again); 300,00; 0; 10,00 (the minimum once) |
| `forwards` | interest 20 %, other 10 %; ratification listed | forward 500,00 € (ratification), forward 300,00 € (recalled file), allocation 100,00 € | 50,00; 0; 2,00 + 9,00 |

**What we need from you.** Two or three real fee clauses (anonymised) with a collection history and the invoices the client accepted: they replace the synthetic grids, and any difference to the cent is either fixed or documented.

## 8. What I need from you (golden cases)

For each of the four M3 claim types: 2–3 anonymised real files with contract terms, schedule, events (due dates, notice, acceleration, judgment), payments, and the **expected statement** at a given date from a source you trust (bank décompte, bailiff décompte or judgment). These become the golden tests; the engine must match to the cent or we document why not.
