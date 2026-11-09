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

## 6b. Allocation of payments (imputation) — M2b-4

Implemented by the pure waterfall `worker/src/collectoo_worker/payments/allocation.py` (engine version `alloc-1`), posted by the job `payments.allocate` (ADR-0013, M2b-4 addendum; design `docs/design/m2b-payments.md` §8.5). Texts (read on LibreJustice, quoted in the design §3): C. civ. [1342-10](https://librejustice.fr/norm/fr/code-civil/1342-10), [1343-1](https://librejustice.fr/norm/fr/code-civil/1343-1), [1305-3](https://librejustice.fr/norm/fr/code-civil/1305-3), [1347](https://librejustice.fr/norm/fr/code-civil/1347), [1347-1](https://librejustice.fr/norm/fr/code-civil/1347-1), [1347-4](https://librejustice.fr/norm/fr/code-civil/1347-4) (« S'il y a plusieurs dettes compensables, les règles d'imputation des paiements sont transposables. »).

**Order (not configurable: founder #5, OQ-19).**
1. **Debts** = claim items of the file. First the items the debtor **designated** when paying (invoice numbers in the remittance text, or a document ops filed), in the order named — an item not yet due included (1305-3: the term benefits the debtor). The rest follows the legal order.
2. Then **due items** (due date ≤ the allocation date), **oldest due date first**, then oldest issue date (« la plus ancienne », OQ-21; « plus d'intérêt d'acquitter » is not encoded). An item without a due date counts as due, after the dated ones (a defaulted loan's single item). An unknown issue date sorts last.
3. Equal keys form one **tie group, shared pro rata** to its items' open amounts (« toutes choses égales, elle se fait proportionnellement »).
4. Then **items not yet due**, by due date.
5. **Inside each item**: interest family first (1343-1); then the accessories (indemnity, charge, cost) where the policy ranks them — `before_principal` by default (§6 example 3; OQ-7 for the B2B €40, which does not exist before M3); principal; then the seller's **unclassified** amounts (EU 3.11, balancing line) — **never by allocation for consumer loans** (regimes `consumer_credit_*`, `consumer_mortgage`) until ops classify them (founder #6, OQ-18).

**Pro rata to the cent (largest remainder).** For a group of demand D and an amount R < D: share_i = ⌊R × d_i / D⌋ in exact integers, then one minor unit to each item by decreasing remainder (R × d_i mod D), ties by item id, until Σ shares = R. Each share is spent in its item's family order. Example: 300,01 € on two invoices of 500,00 € due the same day → 150,01 € and 150,00 €.

**Available amount.** On a receivable at the allocation date D: the lowest running balance from D on (an allocation dated D never makes a later date negative). Items or components at or below zero (credit notes, overpaid invoices, a negative balancing line) are not paid. **Allocation date** = the booking date, or the servicing start if later (a payment before the cut-off waits for ops: founder #10).

**What is not allocated stays unallocated.** If every payable slot is exhausted, the rest is an **overpayment**: it stays in pooled 4710 tagged by the payment, is never passed to the client (founder #8), and is refunded to the payer (M2b-6) or, on the debtor's written request, allocated on another file of his (same client).

**Credit notes (1347).** A credit (credit note, overpaid invoice) is compensated only when invoked: proposed per file — the oldest credit against the first group of **due** invoices in the order above (1347-1: « exigibles »; 1347-4: the imputation rules transpose), pro rata on ties — dated when both were due, not before servicing start, principal only — and applied by one ops tap. Payments of a file with a pending proposal wait until it is applied (or ops allocate without it).

**Worked example (design §8.2, test `worker/tests/test_allocation_integration.py`).** M-0042 (B2B): F-101 1 500,00 € due 10/06, F-102 800,00 € due 15/07, F-103 400,00 € due 20/08, F-104 300,00 € due 15/12, AV-105 −200,00 €. AV-105 applied on F-101 at the cut-off (F-101 → 1 300,00 €). P1 2 000,00 € citing F-103 → F-103 400,00, F-101 1 300,00, F-102 300,00; F-104 is not due and not reached. L-9 (consumer credit): interest 120,00, principal 5 000,00, other balances 30,00; P2 5 200,00 € → interest 120,00, principal 5 000,00; the 30,00 are held; 80,00 € overpayment.

**Re-run by date (M3, founder #16).** The waterfall is a pure function of (amount, slots at D, policy, designation, D); each allocation entry keeps its inputs hash and its plan (policy, designation). M3-13 re-allocates earlier payments by reversing their entries at their dates and posting the waterfall's result on the balances including accrued interest; with nothing changed, a re-run gives the same lines (property and integration tests).

## 7. What I need from you (golden cases)

For each of the four M3 claim types: 2–3 anonymised real files with contract terms, schedule, events (due dates, notice, acceleration, judgment), payments, and the **expected statement** at a given date from a source you trust (bank décompte, bailiff décompte or judgment). These become the golden tests; the engine must match to the cent or we document why not.
