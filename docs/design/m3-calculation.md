# M3 Calculation engine: synthesized design (M3-01 … M3-15)

Status: this is the design for the M3 PRs. Implementation follows, one PR per slice (§17). The founder decisions in §20 are pending.

How it was produced: a three-design panel (legal-first, engine-first, ops-first), an adversarial critique of each design, then a judge.

What it was checked against:
- branch `m2b5r` @ 8647ce2: migrations up to `20261110130000_plan_robustness.sql`, `worker/src/collectoo_worker/payments/allocation.py` (engine `alloc-1`);
- ADR-0005, ADR-0012, ADR-0013 and its addenda;
- `docs/design/m2b-payments.md` and `docs/design/m2c-remittances.md` (founder decisions of 2026-11-09 accepted; M2c-1 not built yet).

`worker/rule_packs/` and `collectoo_worker/engine/` do not exist yet. `ledger_entry` already has `engine_version`, `rule_pack_version_id` (no FK) and `inputs_hash`. `private.allocation_plan` keeps, per allocation entry, the policy, the designation, the inputs hash and the engine version.

On 2026-11-09 the judge re-read on LibreJustice every legal text quoted in §3, in the version in force that day unless another date is given. Texts that were not re-read are listed in §3.6 and are never quoted.

Nothing here is implemented. **Every amount and every legal reading is TO VALIDATE** until the founder's golden cases pass.

---

## 0. Decision in one paragraph

**The law sets the ceiling; the mandate chooses within it; the contract and the recorded facts fill it in.**

**Rule packs.** A rule pack is versioned YAML, and every rule in it cites a text that was read, with its URL, the versions read and a verbatim quote. A closed vocabulary of rule kinds is implemented in code. Validators and database guards make the forbidden things impossible:
- interest on interest without 1343-2;
- capitalisation for consumers;
- any charge outside L312-39 for consumer credit;
- a debtor-borne recovery fee;
- the €40 outside B2B.

**The engine** is one pure, deterministic Python function: `replay(facts, packs, rates, through)`. It replays a file from its servicing start, interleaving accrual and the unchanged M2b waterfall at each payment date. It returns:
- itemised décompte lines;
- the **target ledger**: what should be posted at each posting date;
- the target allocation of each live payment.

The arithmetic is exact integers, rounded half-up once per economic segment, so the total does not depend on when we post. A missing input (rate, due date, contract rate, notice) **blocks** the stream concerned; the engine never guesses.

**Posting.** A `plan` compares the target with the ledger. Entries that differ are corrected **by reversal and re-posting at their own dates, in one set-based call**, so the ledger checks see only the final state. Interest is posted (`accrual`; one-off indemnities as `charge`; `capitalisation`) at reproducible posting dates only:
- every allocation, direct-payment and netting date (1343-1 needs interest at the payment date);
- each indemnity's due date;
- each capitalisation anniversary;
- a **monthly close**, run once that month's bank statements are in.

Documents never post.

**Back-dated facts.** A fact recorded late marks the file dirty from its date. The recompute restates later allocations by reversal plus re-allocation at the same date. This is **automatic only when no payment's cash total changes**; otherwise ops approve first. M2c-7 must net the remitted-reversal cover per restatement.

**Out of M3.** Judgments, surendettement measures, interest forfeiture, liquidation of a professional borrower, variable rates and public buyers are « hors calcul » from their date: frozen, never typed by hand.

**Décomptes and receipts.** A décompte is a frozen snapshot, computed as ledger plus pending lines. Receipts show « reste dû » only for validated packs.

**Go-live** for real payments of a claim type needs its pack VALIDATED by the founder's cases, and M2c-7 merged.

---

## 1. Scope and non-scope

| Roadmap | What M3 builds | Acceptance criterion → proven in |
|---|---|---|
| **M3-01** rate tables | `rate_index`, `rate_value` (append-only, superseded only); legal rates 2015-H1 → 2026-H2 from each arrêté; ECB MRO index (values per D5); `RateBook` + SQL twin | lookup at any date returns the arrêté value with its source; a missing semester gives `RateMissing` → §14, M3a-1 |
| **M3-02** rule-pack format | `worker/rule_packs/<pack>/<effective_from>.r<rev>.yaml`, schema `rule-pack/1`, float-refusing loader, validators, generated migration, `private.rule_pack*` tables, activation after a dry run | invalid packs fail CI; a used version is immutable → M3a-2 |
| **M3-03** engine core | timeline, economic segments, day counts, integer arithmetic, half-up per line | splitting a segment changes the total by ≤ 1 minor unit per split; zero rate ⇒ zero → M3a-4 |
| **M3-04** events and state | starts (due + 1, notice, acceleration), stops (L622-28, L722-14, 1343-5), L313-3 primitive, hors-calcul events; holds tied to events | unit tests per event from the worked examples → M3a-3, M3a-4 |
| **M3-05** fees and caps | D312-16, €40 (D441-5), contractual indemnity (1231-5); per-regime component whitelist; cost components refused without a title | a pack declaring a forbidden fee fails validation; the ledger refuses a cost posting without a title → M3a-2, M3a-3 |
| **M3-06** capitalisation, limitation | 1343-2 only for the professional loan with a clause; refused for consumer regimes and after an opening; indicative prescription and forclusion dates | property: never for consumer regimes; limitation table test → M3a-4 |
| **M3-07** schedule | `schedule_line` imported or rebuilt; capital not yet due vs unpaid instalments | rebuilt = reference to the cent → M3b-3 |
| **M3-08 … M3-11** packs | `b2b_invoice.commercial_b2b`, `b2c_invoice.consumer_b2c`, `professional_loan.professional_credit`, `consumer_instalment_loan.consumer_credit_pre_ccd2` / `_ccd2` | worked examples to the cent under the conventions of §8.3 → M3b-1…4 |
| **M3-12** golden harness | `worker/tests/golden/<claim_type>/*.yaml`, `conventions:` header, line diff, `SIGNOFF.yaml` | readable diff; founder cases drop in without code → M3a-4 |
| **M3-13** accrual posting | posting dates, `engine_post_plan`, monthly close, dirty tracking, recompute, drift check | every seeded account: engine target = ledger at each posting date → M3c-1 |
| **M3-14** décompte | live view, issued snapshot `D-AAAA-NNNNNN`, French HTML/PDF, client space, staleness | every line traces to postings or to an explicit pending line; total = ledger + pending at the date → M3c-3 |
| **M3-15** allocation from the pack | `alloc-2`: policy defaults from the pack version at D, overrides only where the pack allows; crystallise before planning | M2b allocation properties pass with pack-driven policies → M3c-2 |
| **M2b founder #16** | re-run of earlier allocations by date (restatement), review queue, M2c-7 net cover, `restate_all` | a back-dated event gives the same balances as a from-scratch replay; a no-op gives an empty plan → M3c-2 |

**Not in M3, and why:**
- **Other claim-type packs:** revolving, overdraft, BNPL, mortgage, rent, private loan, judgment debt. Their own texts (L313-50/51, the 1989 lease law…) were not re-read. Each comes as one pack plus golden cases later.
- **Judgments.** The L313-3 +5-point primitive is built and unit-tested, but a recorded judgment makes the file « hors calcul » from its date (D11). Encoding the operative part (heads, 1231-7, art. 700, appeal) is the later `judgment_debt` pack.
- **Surendettement measures** (L733-1: capital first, reduced rate, suspension), **interest forfeiture** (L341-8), a **judge's capital-first or reduced-rate order** (1343-5 al. 2): hors calcul.
- **Variable-rate loans** (no index table: `euribor_3m` is dropped from M3), actuarial rates, insurance premiums, early-repayment indemnities: blocked or hors calcul, never approximated.
- **Further B2B compensation « sur justification »**, contractual penalty clauses in B2C contracts, any enforcement cost: the cost components exist and are guarded, but nothing posts to them.
- **Public buyers** (Code de la commande publique R2192-31: ECB rate « majoré de huit points », another regime): hors calcul for accessories.
- **Non-EUR claims** (OQ-27): the €40 and the default B2B rate are EUR-only; other currencies are blocked.
- **Guarantor-facing documents** (2302, OQ-65): the principal debtor only.
- **Debtor delivery:** the R124-4 letter (M4), the portal (M5), the bailiff package with the R211-1 one-month provision (later).
- **Automatic write-off of residues; payoff quotes at a future date.**
- **AI Act.** M3 is deterministic rules. It has no model, no LLM and evaluates no natural person, so there is nothing to flag. Engine outputs (balances, statuses) must not feed any propensity model without the AI-01 go/no-go (OQ-14).

---

## 2. Panel scores and contradictions resolved

### 2.1 Scores (out of 10; weights as M2b/M2c: money 25 %, legal 20 %, ops 15 %, performance 15 %, testability 15 %, simplicity 10 %)

| Criterion | Legal-first | Engine-first | Ops-first |
|---|---|---|---|
| Money correctness | 7.5. Sound lazy crystallisation and reversal. But it says the order inside the transaction does not matter (false with `ledger_post_set`'s immediate checks), its idempotency keys collide on A→B→A, and crystallising at snapshots causes re-run storms. | **8.5**. Pure replay, then diff, then one set. But restated allocations bypass the 1343-1 re-check in `post_allocations`, on-demand posting points cannot be reproduced, and capital not yet due can be prepaid. | 7. The `reallocation` entry is invisible to M2c commission, its keys collide on A→B→A, the month close races the statements, and the review is not atomic. |
| Legal grounding | **8.5**. Widest reading. But it claims 3× legal is « conservative », its day rule contradicts example 3, it overstates L313-3, and the judgment overlay adds streams instead of replacing them. | 7.5. Finds L722-14. But the D4 floor claim is false, forclusion is treated as prescription, judgments are half-modelled, and law time is used for contract rules. | 7.5. Finds L722-14 and freezes judgments. But its calendar-year justification is overstated, and refusing a CGV rate below the floor fabricates a term. |
| Ops usability | 6.5 | 6.5 | **9**: status chips, « hors calcul », review queue, provisional mode, stale décomptes |
| Performance | 7: re-runs under the servicer lock | 7.5: lock held 7–8 s per 5k chunk | 7: one lock for everything |
| Testability | 8.5 | **9**: oracle, `Fraction` reference, empty-plan property | 8.5 |
| Simplicity / fit with ADR-0012/0013 | 7: judgment overlay in M3, many components | 7.5 | 7.5 |
| **Weighted** | **7.6** | **7.8** | **7.7** |

No single base. The synthesis takes:
- **The skeleton from engine-first:** replay → plan → one set; posting-date independence; append-only bitemporal inputs; an empty plan when nothing changed; the oracle property.
- **The legal frame from legal-first:** law ceiling plus mandate selection; reasons and guards for each claim type; fail closed; the décompte families of R124-4 3°; the M2c double-credit risk.
- **The product layer from ops-first:** file-page cards and statuses; hors calcul; the review queue; the provisional mode for a missing rate; frozen, numbered décomptes with staleness; the receipt balance.

**Rejected:**
- the `reallocation` claim-only entry (ops-first): M2c commission and remittance lines could not see it;
- crystallising at frozen documents (legal-first);
- month-end posting without a statements gate (engine-first, ops-first);
- defaulting to 3 × the legal rate « because it is lower » (legal-first, engine-first);
- refusing a CGV rate below the floor at entry (ops-first);
- the judgment overlay in M3 (legal-first);
- automatic raises of a payment's allocated amount (engine-first);
- an admin rate-entry page (ops-first; rates come by reviewed change, D5);
- Decimal arithmetic in the engine (ROADMAP M3-03): exact integers instead, with Decimal only to parse and print.

### 2.2 Contradictions resolved

| # | Question | Legal-first | Engine-first | Ops-first | **Chosen** | Why |
|---|---|---|---|---|---|---|
| 1 | When interest is posted | lazily: allocations, regime events, frozen documents | cash events, month-end, on demand | monthly close, before allocations, on décompte issue | **allocation, direct-payment and netting dates; charge dates; capitalisation dates; a monthly close gated on statements; never documents** | Posting dates must be a function of recorded facts, so a replay reproduces them (engine critique C1). Documents that post cause re-run storms (legal critique G6). A close before the month's statements is always restated (ops critique B2). |
| 2 | First day and payment day | `start: due + 1` with `[start, end)`, yet text claiming 75 days | due + 1 (D1) | `[due, payment)`, 75 days | **conservative default: first day = the day after the triggering date; the payment day is not charged; founder D1** | L441-10: « exigibles le jour suivant la date de règlement ». Never charge a day that is not clearly late. Example 3 becomes 7 455,54 € (§12). |
| 3 | Year basis | ACT/365 | ACT/365F | calendar year | **calendar year (366 in a leap year) for interest the engine computes; contract schedules as given; founder D2** | Never above ACT/365; no worked example changes before 2028. Cass. 1re civ. 19 juin 2013 requires « l'année civile » for conventional interest to consumers. It is a choice, not a rule of law for statutory interest (OQ-52). |
| 4 | Rounding | per segment | per economic segment, partial postings by difference | per line | **half-up once per economic segment (= décompte line); partial postings post round(cum) − round(previous cum); adjacent sub-segments with equal base, rate, basis and state are merged** | Lines add up to the total; posting dates never change totals; a no-op pack version or an equal rate row never restates anything (engine critique C2, ops critique M4). |
| 5 | B2B rate when the CGV is not known | 3 × legal (« conservative ») | floor (« never more than due ») | CGV refused if below the floor, else ECB + 10 | **client declares `cgv_rate` / `no_clause` / `unknown`; unknown → lower of (3 × legal, ECB + 10) per semester; a CGV rate below the floor is applied as written, flagged** | 3 × 5,07 % = 15,21 % in 2024-H1 (arrêté du 21 décembre 2023), so the floor is not lower by construction. Claiming less than the law allows is always lawful; inventing a rate is not. |
| 6 | Re-run mechanism | reversal + re-allocation at the same date | reverse + repost in one restatement set | claim-side `reallocation` unless the cash total changes | **reversal + re-posting at the original date, in one `ledger_post_set` call, grouped by `restatement_id`; automatic only if every (payment, file) keeps its cash total** | « Corrections by reversal » (CLAUDE.md). One definition of a live allocation for returns, receipts, feed and commission. M2c sees a negative and a positive line, which its telescoping commission already handles. |
| 7 | Cash-total changes | not specified | lowering → ops; raising → automatic | both → ops | **both → ops approval; never automatic** | Raising couples the files of a split payment (engine critique C5); lowering moves remitted money. |
| 8 | Judgments | overlay in M3 | events block items until heads are encoded | freeze, hors calcul | **hors calcul from the judgment date; L313-3 primitive unit-tested only** | Heads, 1231-7 al. 2, art. 700 under L312-38 and stream replacement are a pack of their own (legal critique L3, L4, L9). |
| 9 | Surendettement | stop, then manual after measures | stop, resume at the measures' rate | stop, then freeze | **stop all interest, penalties and new charges from admissibility; hors calcul after measures** | L722-14; the L724-1 measures erase the debt and L733-1 can impose capital-first (engine critique L3). |
| 10 | Consumer acceleration | notice or clause flag; else a warning | event with evidence | event with evidence | **late interest and D312-16 only after a recorded acceleration notice that gives a regularisation delay and has expired; a tape date alone computes nothing beyond the openings** | Cass. 1re civ. 3 juin 2015 and 29 mai 2024 (§3.1); a tape date is the seller's word (legal critique L5). |
| 11 | Legal stops vs holds | hold requires the event | holds refer to events; `accruals` scope honoured | hold sheet asks the legal date; `accruals` scope inert | **the engine reads legal stops from events only; placing a surendettement or collective-proceeding hold also records its event; hold scopes never change interest; lifting a hold never resumes interest** | `account_hold.started_at` is a recording time. The current default scope `accruals` on collective-proceeding holds would stop interest that L622-28 lets run (engine critique L11). |
| 12 | Contract terms time axis | temporal `valid_from` | temporal | `claim_terms.valid_from` | **contract and CGV terms attach to the contract or invoice (append-only, superseded), never time-sliced; collection instructions (claim policy, waivers) are time-sliced and prospective** | A new CGV version must not re-rate old invoices (ops critique M1). A new policy must not re-allocate past payments (legal critique G9). |
| 13 | Rates loading | migration | YAML sync at worker start | admin page + migration seed | **repo YAML with verbatim quote → generated migration (`make rates`, CI equality); alert from 1 June / 1 December** | Reviewed, reproducible, no hand-typed rate. Arrêtés of recent semesters appeared mid-December and late June (D313-1-A II sets no date). |
| 14 | Pack storage and activation | `private` tables, worker sync | `public` tables, worker sync | `public`, generated migrations | **`private.rule_pack_version` (ADR-0005) from a generated migration; lands inactive; an admin activates it after a dry run** | Migrations auto-apply on merge; a revision must not restate files unseen (ops critique M3). |
| 15 | Snapshot of balances | none | none | `account_balance` cache | **`public.account_engine_summary` (cache, rebuildable, no lock), nightly and on change** | Lists, flows (M4) and the file page need today's figure; renamed to avoid `account_balances()` (ops critique). |
| 16 | Allocation lock | servicer lock, 10k chunks | 5k files per transaction | 2,000 files | **compute outside the lock; under it re-check each file's fact stamp, then post; chunks of 2,000 files (as M2b-6 debits), measured** | Ops commands wait at most 2 s (ADR-0013 #12). |
| 17 | Capital not yet due (loans) | — | reclassification entries | `exigible_on` passed as the slot due date | **instalment items + schedule; before acceleration, capital not yet due is not passed to the waterfall (held for ops); acceleration makes every item due** | Otherwise a payment prepays capital while schedule interest keeps running (engine critique C3); `allocate` stays unchanged. |
| 18 | Receipt balance | after ≥ 2 validated cases | when the pack is validated | from M3b-3 | **only if the pack is VALIDATED and the file's status is `ok`; frozen as known on issue** | A wrong balance on a debtor document is worse than none (ops critique B5, M9). |

---

## 3. Legal basis

### 3.1 Texts relied on (quoted; read on LibreJustice 2026-11-09)

| Text | Operative words (quoted) | What M3 does |
|---|---|---|
| [C. civ. 1343-1](https://librejustice.fr/norm/fr/code-civil/1343-1) | « Le paiement partiel s'impute d'abord sur les intérêts. » · « Le taux de l'intérêt conventionnel doit être fixé par écrit. Il est réputé annuel par défaut. » | Interest first in every pack; no pack key can express otherwise. A contract rate runs only with written evidence in `contract_terms`. |
| [C. civ. 1342-10](https://librejustice.fr/norm/fr/code-civil/1342-10) | « … d'abord sur les dettes échues ; parmi celles-ci, sur les dettes que le débiteur avait le plus d'intérêt d'acquitter. A égalité d'intérêt, l'imputation se fait sur la plus ancienne … » | M2b order unchanged. Once debts bear different interest, « plus d'intérêt » becomes material: OQ-21 must be answered before go-live (§16 R10). |
| [C. civ. 1343-2](https://librejustice.fr/norm/fr/code-civil/1343-2) | « Les intérêts échus, dus au moins pour une année entière, produisent intérêt si le contrat l'a prévu ou si une décision de justice le précise. » | Capitalisation only for the professional loan with a clause (judgments are hors calcul), at anniversaries, unpaid interest only (OQ-63). |
| [C. civ. 1231-6](https://librejustice.fr/norm/fr/code-civil/1231-6) | « … consistent dans l'intérêt au taux légal, à compter de la mise en demeure. » · « … sans que le créancier soit tenu de justifier d'aucune perte. » | B2C (and the professional fallback): legal interest only from a recorded `formal_notice` with evidence. |
| [C. civ. 1344](https://librejustice.fr/norm/fr/code-civil/1344) | « … soit par une sommation ou un acte portant interpellation suffisante, soit, si le contrat le prévoit, par la seule exigibilité de l'obligation. » | The exigibility route only on a clause in evidence; disabled for consumer contracts until counsel answers (OQ-3 updated). |
| [C. civ. 1231-5](https://librejustice.fr/norm/fr/code-civil/1231-5) al. 2, al. 5 | « … le juge peut, même d'office, modérer ou augmenter la pénalité … » · « Sauf inexécution définitive, la pénalité n'est encourue que lorsque le débiteur est mis en demeure. » | A contractual indemnity (and D312-16, which L312-39 makes « sans préjudice de l'application de l'article 1231-5 ») requires a recorded notice. |
| [C. civ. 1231-7](https://librejustice.fr/norm/fr/code-civil/1231-7) | « … la condamnation à une indemnité emporte intérêts au taux légal même en l'absence de demande … » · « … l'indemnité allouée en appel porte intérêt à compter de la décision d'appel. » | Not encoded in M3: a judgment makes the file hors calcul (D11). |
| [C. civ. 1343-5](https://librejustice.fr/norm/fr/code-civil/1343-5) al. 2, al. 4 | « … porteront intérêt à un taux réduit au moins égal au taux légal, ou que les paiements s'imputeront d'abord sur le capital. » · « Les majorations d'intérêts ou les pénalités prévues en cas de retard ne sont pas encourues pendant le délai fixé par le juge. » | `judicial_delay` event: penalties, increases and late margins are suspended for its period (OQ-59). A reduced rate or capital first → hors calcul. |
| [CMF L313-2](https://librejustice.fr/norm/fr/code-monetaire-et-financier/l313-2) | « … un taux applicable lorsque le créancier est une personne physique n'agissant pas pour des besoins professionnels et un taux applicable dans tous les autres cas. » · « Il est calculé semestriellement … » | Two indices with one value per semester. The category comes from the **owner at each day**. Phase A owners are professionals (M2c founder #13) → « autres cas »; the engine still reads the owner's capacity. |
| [CMF D313-1-A](https://librejustice.fr/norm/fr/code-monetaire-et-financier/d313-1-a) | 2°: MRO « en vigueur deux mois avant le début du semestre » + « 60 % de la moyenne … de l'écart … ». II: « Le ministre … fait procéder à la publication par arrêté … des taux qui serviront de référence pour le semestre suivant. » | Only published arrêté values are used; the engine never derives a legal rate. Structurally, 3 × legal can exceed MRO + 10 (§2.2 #5). |
| [CMF L313-3](https://librejustice.fr/norm/fr/code-monetaire-et-financier/l313-3) | « … le taux de l'intérêt légal est majoré de cinq points à l'expiration d'un délai de deux mois à compter du jour où la décision de justice est devenue exécutoire, fût-ce par provision. » · « … le juge de l'exécution peut … exonérer celui-ci de cette majoration ou en réduire le montant. » | Primitive only: applies to legal-rate streams only; the expiry date is computed per CPC 641 al. 2, extended per 642 al. 2 (latest candidate), start the day after; `jex_decision {majoration_pp}`. Unit-tested; no M3 pack uses it (OQ-60). |
| Arrêtés: [21 déc. 2023](https://librejustice.fr/norm/fr/arrete-du-21-decembre-2023-relatif-a-la-fixation-du-taux-de-l-interet-legal/1), [19 juin 2025](https://librejustice.fr/norm/fr/arrete-du-19-juin-2025-relatif-a-la-fixation-du-taux-de-l-interet-legal/1), [15 déc. 2025](https://librejustice.fr/norm/fr/arrete-du-15-decembre-2025-relatif-a-la-fixation-du-taux-de-l-interet-legal/1), [26 juin 2026](https://librejustice.fr/norm/fr/arrete-du-26-juin-2026-relatif-a-la-fixation-du-taux-de-l-interet-legal/1), art. 1 | 2024-H1 « … à 8,01 % ; 2° Pour tous les autres cas : à 5,07 % » · 2025-H2 « … 6,65 % ; 2° … à 2,76 % » · 2026-H1 « … 6,67 % ; 2° … à 2,62 % » · 2026-H2 « … 6,84 % ; 2° … à 2,75 % » | Seed values (all other semesters are read during M3a-1). **The CALCULATION_RULES §4.1 caveat on 2,76 % is cleared.** |
| [C. com. L441-10](https://librejustice.fr/norm/fr/code-de-commerce/l441-10) II: versions 2019-04-26 → 2026-08-31, 2026-09-01 → 2026-12-31 and from 2027-01-01, all three read; II is word for word the same | « … pénalités de retard exigibles le jour suivant la date de règlement figurant sur la facture … » · « Sauf disposition contraire qui ne peut toutefois fixer un taux inférieur à trois fois le taux d'intérêt légal, ce taux est égal au taux d'intérêt appliqué par la Banque centrale européenne à son opération de refinancement la plus récente majoré de 10 points de pourcentage. Dans ce cas, le taux applicable pendant le premier semestre … est le taux en vigueur au 1er janvier … second semestre … au 1er juillet … » · « Les pénalités de retard sont exigibles sans qu'un rappel soit nécessaire. Tout professionnel en situation de retard de paiement est de plein droit débiteur … d'une indemnité forfaitaire pour frais de recouvrement … » · « … le créancier ne peut invoquer le bénéfice de ces indemnités lorsque l'ouverture d'une procédure de sauvegarde, de redressement ou de liquidation judiciaire interdit le paiement à son échéance de la créance qui lui est due. » | `b2b_invoice` pack: penalties from the day after the due date; rate per §2.2 #5; ECB fixed at 1 Jan / 1 Jul; €40 per late invoice, barred when the opening judgment is on or before the due date. L441-10 I: with no invoice due date, the legal default runs from receipt of goods or performance, which we do not know → **blocked**, never « issue + 30 ». |
| [C. com. L441-6](https://librejustice.fr/norm/fr/code-de-commerce/l441-6) I (version 2017-04-08 → 2019-01-31) | the same penalty, ECB + 10 and €40 wording | The version 2019-02-01 → 2019-04-25 was not read. Pack v1 covers late days from 2019-04-26; earlier invoices are hors calcul (and in any case past L110-4's five years unless interrupted). |
| [Cass. com. 3 mars 2009, 07-16.527](https://librejustice.fr/decision/7nnBK9Q9HZq0) | « … les pénalités de retard pour non paiement des factures sont dues de plein droit, sans rappel et sans avoir à être indiquées dans les conditions générales des contrats » | `no_clause` → the statutory rate, with no reminder needed; the pack applies by accrual day (`applies_by: accrual_day`). |
| [C. com. D441-5](https://librejustice.fr/norm/fr/code-de-commerce/d441-5) | « … est fixé à 40 euros. » | `b2b_flat_indemnity` 4 000 minor units, EUR only. |
| [CJUE 1er déc. 2022, C-370/21](https://librejustice.fr/decision/jj5vhyqjUk1b) points 25, 26 | « … est exigible pour chaque tranche de paiement non réglée à l'échéance. » · « … est dû à un créancier qui a rempli ses obligations pour chaque paiement non effectué à l'échéance en rémunération d'une transaction commerciale, attestée dans une facture … à moins que le débiteur ne soit pas responsable de ces retards » | One €40 per late claim item (invoice, or instalment of an invoice schedule). Held while a `dispute` hold is active on the file. Not charged when the seller already invoiced it (OQ-56). |
| [C. com. L441-9](https://librejustice.fr/norm/fr/code-de-commerce/l441-9) I (version to 2026-12-31) | « Le règlement est réputé réalisé à la date à laquelle les fonds sont mis, par le client, à la disposition du bénéficiaire ou de son subrogé. » | The base drops on the allocation date (= booking date, M2b). Whether the value date matters is OQ-62. The 2027 version was not read. |
| [C. com. L622-28](https://librejustice.fr/norm/fr/code-de-commerce/l622-28) | « Le jugement d'ouverture arrête le cours des intérêts légaux et conventionnels, ainsi que de tous intérêts de retard et majorations, à moins qu'il ne s'agisse des intérêts résultant de contrats de prêt conclus pour une durée égale ou supérieure à un an ou de contrats assortis d'un paiement différé d'un an ou plus. » · « Les personnes physiques coobligées … peuvent se prévaloir … » · « … les intérêts échus de ces créances ne peuvent produire des intérêts. » | `collective_proceeding_opened {kind}` stops every stream at the opening date. Exception, for sauvegarde or redressement only: a loan ≥ 1 year (or with a deferred payment ≥ 1 year) keeps its **contract rate**; the late margin and capitalisation stop (conservative, OQ-58). No €40 for invoices due on or after the opening date. |
| [C. com. L641-3](https://librejustice.fr/norm/fr/code-de-commerce/l641-3), [L643-1](https://librejustice.fr/norm/fr/code-de-commerce/l643-1) | « Le jugement qui ouvre la liquidation judiciaire a les mêmes effets que … par la première phrase de l'article L. 622-28 … » · « … rend exigibles les créances non échues … » | Liquidation: every stream stops at the opening date. A professional loan in liquidation is hors calcul after it (exigibility and the loan exception are for counsel, OQ-58). |
| [C. conso L722-14](https://librejustice.fr/norm/fr/code-de-la-consommation/l722-14) (in force since 2018-01-01, no later version) | « Les créances figurant dans l'état d'endettement du débiteur dressé par la commission ne peuvent produire d'intérêts ou générer de pénalités de retard à compter de la date de recevabilité et jusqu'à la mise en œuvre des mesures prévues aux 1° et 2° de l'article L. 724-1 et aux articles L. 732-1, L. 733-1, L. 733-4 et L. 733-7. » | **New requirement, missing from COMPLIANCE (new INT-11).** `surendettement_admissible` stops every stream, the schedule interest of instalments falling due later, and every new charge, from the decision date. `surendettement_measures` → hors calcul (OQ-57). |
| [C. conso L733-1](https://librejustice.fr/norm/fr/code-de-la-consommation/l733-1) 2°–4° | « Imputer les paiements, d'abord sur le capital » · « Quelle que soit la durée du plan de redressement, le taux ne peut être supérieur au taux légal. » · « … la suspension de la créance entraîne la suspension du paiement des intérêts dus à ce titre. » | Why measures are hors calcul: they override 1343-1, which LG006 refuses. |
| [C. conso L312-38](https://librejustice.fr/norm/fr/code-de-la-consommation/l312-38) | « Aucune indemnité ni aucuns frais autres que ceux mentionnés aux articles L. 312-39 et L. 312-40 ne peuvent être mis à la charge de l'emprunteur … » · « … le remboursement des frais taxables … à l'exclusion de tout remboursement forfaitaire de frais de recouvrement. » | The consumer whitelist is enforced by the validator and a DB guard (INT-05). |
| [C. conso L312-39](https://librejustice.fr/norm/fr/code-de-la-consommation/l312-39) (single version since 2016-10-10) | « … le remboursement immédiat du capital restant dû, majoré des intérêts échus mais non payés. Jusqu'à la date du règlement effectif, les sommes restant dues produisent les intérêts de retard à un taux égal à celui du prêt. » · « … une indemnité qui, dépendant de la durée restant à courir du contrat et sans préjudice de l'application de l'article 1231-5 … » | `late_interest` at the loan rate on **capital only** (INT-06; OQ-62), from the day after acceleration. |
| [D312-16](https://librejustice.fr/norm/fr/code-de-la-consommation/d312-16), [D312-17](https://librejustice.fr/norm/fr/code-de-la-consommation/d312-17) | « Lorsque le prêteur exige le remboursement immédiat … une indemnité égale à 8 % du capital restant dû à la date de la défaillance. » · « Lorsque le prêteur n'exige pas le remboursement immédiat … 8 % des échéances échues impayées … » | D312-16 per §7.5. D312-17 is disabled in M3 (OQ-4); the two are exclusive by their own words. |
| [Cass. 1re civ. 9 févr. 2012, 11-14.605](https://librejustice.fr/decision/E8L98IEur4ny) | « … fait obstacle à l'application de la capitalisation des intérêts prévue par le second texte susvisé » (art. 1154) | Capitalisation forbidden for consumer regimes (INT-06): validator + DB guard. |
| [Cass. 1re civ. 3 juin 2015, 14-15.655](https://librejustice.fr/decision/4RFRvshPTEfg) | « … celle-ci ne peut, sauf disposition expresse et non équivoque, être déclarée acquise au créancier sans la délivrance d'une mise en demeure restée sans effet, précisant le délai dont dispose le débiteur pour y faire obstacle » | An `acceleration` event needs a notice event that states the delay, dated before it. |
| [Cass. 1re civ. 29 mai 2024, 23-12.904](https://librejustice.fr/decision/PI_N6W_wOwWZ) (mortgage, L132-1 old) | « … la clause qui prévoit la résiliation de plein droit du contrat de prêt après une mise en demeure de régler une ou plusieurs échéances impayées sans préavis d'une durée raisonnable, crée un déséquilibre significatif … » | No clause-only path for consumers. A notice with too short a delay is flagged for ops (warning) — the delay's adequacy is not decided by the engine (OQ-61). |
| [Cass. 1re civ. 19 juin 2013, 12-16.651](https://librejustice.fr/decision/2ZI-pqS0t9Xq) | « … le taux de l'intérêt conventionnel mentionné par écrit dans l'acte de prêt consenti à un consommateur ou un non-professionnel doit … être calculé sur la base de l'année civile » | Consumer packs refuse 360-day bases for interest the engine computes; supports D2. |
| [C. conso R312-35](https://librejustice.fr/norm/fr/code-de-la-consommation/r312-35) | « … dans les deux ans de l'événement qui leur a donné naissance à peine de forclusion … le non-paiement des sommes dues à la suite de la résiliation du contrat ou de son terme ; ou le premier incident de paiement non régularisé … » · « … le premier incident non régularisé intervenu après le premier aménagement ou rééchelonnement … » | Indicative forclusion date. The first unregularised incident is computed from the replay's allocations to instalments; it restarts after a `rescheduling` / plan / measures event. |
| [C. civ. 2220](https://librejustice.fr/norm/fr/code-civil/2220), [2241](https://librejustice.fr/norm/fr/code-civil/2241), [2240](https://librejustice.fr/norm/fr/code-civil/2240), [2224](https://librejustice.fr/norm/fr/code-civil/2224); [C. com. L110-4](https://librejustice.fr/norm/fr/code-de-commerce/l110-4) I; [C. conso L218-2](https://librejustice.fr/norm/fr/code-de-la-consommation/l218-2); [CPCE L111-4](https://librejustice.fr/norm/fr/code-des-procedures-civiles-d-execution/l111-4) | « Les délais de forclusion ne sont pas, sauf dispositions contraires … régis par le présent titre. » · « La demande en justice, même en référé, interrompt le délai de prescription ainsi que le délai de forclusion. » · « La reconnaissance par le débiteur … interrompt le délai de prescription. » · 5 years; 5 years; « … se prescrit par deux ans »; « … ne peut être poursuivie que pendant dix ans … » | Indicative dates only, back-office only. Forclusion ignores acknowledgements (validator). Alerts use the uninterrupted date (OQ-67). |
| [CPCE L111-8](https://librejustice.fr/norm/fr/code-des-procedures-civiles-d-execution/l111-8) | al. 1 « … les frais de l'exécution forcée sont à la charge du débiteur, sauf s'il est manifeste qu'ils n'étaient pas nécessaires … » · al. 2 « Les frais de recouvrement entrepris sans titre exécutoire restent à la charge du créancier, sauf s'ils concernent un acte dont l'accomplissement est prescrit par la loi au créancier. Toute stipulation contraire est réputée non écrite, sauf disposition législative contraire. » | No `recovery_fee` component exists, and no pack may name one. `enforcement_cost` / `procedure_cost` are guarded (title, enforceable date, the act as evidence); nothing posts to them in M3. The al. 2 exception (« acte … prescrit par la loi ») is deliberately not used. |
| [CPCE R124-3](https://librejustice.fr/norm/fr/code-des-procedures-civiles-d-execution/r124-3) 1° | « Le fondement et le montant des sommes dues, avec l'indication distincte des différents éléments de la ou des créances à recouvrer sur le débiteur » | ⚖️ reading: accessories are claimed only when the mandate lists them (`claim_policy` with the clause reference, D3). |
| [CPCE R124-4](https://librejustice.fr/norm/fr/code-des-procedures-civiles-d-execution/r124-4) 3° | « Le fondement et le montant de la somme due en principal, intérêts et autres accessoires, en distinguant les différents éléments de la dette, à l'exclusion des frais qui restent à la charge du créancier … » | Décompte families and basis per line (§11); a creditor-borne fee cannot exist in the payload. |
| [CPCE R211-1](https://librejustice.fr/norm/fr/code-des-procedures-civiles-d-execution/r211-1) 3° | « Le décompte distinct des sommes réclamées en principal, frais et intérêts échus, majorées d'une provision pour les intérêts à échoir dans le délai d'un mois … » | The payload can carry a labelled one-month projection; it is used by the bailiff package later. |
| [CPC 641](https://librejustice.fr/norm/fr/code-de-procedure-civile/641), [642](https://librejustice.fr/norm/fr/code-de-procedure-civile/642), [503](https://librejustice.fr/norm/fr/code-de-procedure-civile/503) | « … ce délai expire le jour du dernier mois … qui porte le même quantième … A défaut d'un quantième identique, le délai expire le dernier jour du mois. » · « … prorogé jusqu'au premier jour ouvrable suivant. » · « Les jugements ne peuvent être exécutés … qu'après leur avoir été notifiés … » | L313-3 dates by analogy, latest candidate (OQ-60). Ops enter the enforceable date and its basis; the engine never infers it. |
| [C. civ. 2302](https://librejustice.fr/norm/fr/code-civil/2302) | « … sous peine de déchéance de la garantie des intérêts et pénalités échus … les paiements effectués par le débiteur pendant cette période sont imputés prioritairement sur le principal de la dette. » | Guarantor amounts differ from the debtor's: guarantor-facing décomptes are refused in M3 (OQ-65). |
| [Ord. 2016-131 art. 9](https://librejustice.fr/norm/fr/ordonnance-n-2016-131-du-10-fevrier-2016-portant-reforme-du-droit-des-contrats/9); [Ord. 2025-880 art. 99](https://librejustice.fr/norm/fr/ordonnance-n-2025-880-du-3-septembre-2025-relative-au-credit-a-la-consommation/99) | « Les contrats conclus avant cette date demeurent soumis à la loi ancienne, y compris pour leurs effets légaux et pour les dispositions d'ordre public. » · « Les contrats de crédit en cours au 20 novembre 2026 restent régis par les dispositions … dans leur rédaction antérieure … » | Packs declare `applies_by`. Professional loans signed before 2016-10-01 get no capitalisation (old art. 1154 not encoded). Consumer regime by contract date (CCD-01). |
| [C. conso L341-8](https://librejustice.fr/norm/fr/code-de-la-consommation/l341-8): version to 2026-11-19, and the version from 2026-11-20 (both read) | old: « … l'emprunteur n'est tenu qu'au seul remboursement du capital suivant l'échéancier prévu … » · new: « Le prêteur qui résilie ou réduit l'autorisation de découvert sans respecter les obligations … est déchu du droit aux intérêts. » | `interest_forfeiture` → hors calcul. The ccd2 pack must cite the articles in their CCD2 numbering after an article-by-article review (OQ-10). |

### 3.2 What the law allows, per claim type (the derivation behind the packs)

| | B2B invoice | B2C invoice | Professional loan | Consumer instalment loan |
|---|---|---|---|---|
| Interest stream | `late_penalty` from the day after the due date, no reminder; rate per §2.2 #5; split at 1 Jan / 1 Jul only when the rate changes | `legal_interest` from the day after receipt of a recorded mise en demeure; legal rate of the creditor's category | contract rate through the schedule; after acceleration, the contractual late rate or margin; without a late clause, legal interest from a notice | schedule interest until acceleration; after it, `late_interest` at the loan rate on capital only; none on unpaid instalments before acceleration (OQ-4) |
| One-off | €40 per late item (§3.1) | none (L441-10 binds « Tout professionnel ») | contractual indemnity per the clause, after a notice (1231-5), base may include échu interest | D312-16 8 % per §7.5; nothing else (L312-38) |
| Capitalisation | off (OQ-55) | off (judgments only, hors calcul) | clause + anniversary ≥ 1 year, unpaid interest only; never after an opening (L622-28) | forbidden (Cass. 2012) |
| Stops | opening (L622-28); 1343-5 delay (suspend); dispute holds the €40 | L722-14 admissibility | opening (sauvegarde/redressement: contract rate continues for loans ≥ 1 year, margin stops; liquidation: all) | L722-14; L622-28 for an individual entrepreneur; forfeiture → hors calcul |
| Limitation (indicative) | 5 y (L110-4) | 2 y (L218-2) | 5 y | 2-year forclusion (R312-35) |
| Before our cut-off | from the legal start on the cut-off principal, only by claim policy and if not seller-included | only from a notice in evidence | the seller's 3.10 as declared; engine from the servicing start | the seller's 3.10 as declared; engine from the servicing start |

### 3.3 What the law forbids: validators and DB guards, not conventions

1. Interest on interest without 1343-2. A stream's interest-bearing `base` may hold no interest-family component except `capitalised_interest`. Percentage-charge bases are a separate key and may include échu interest (example 2's indemnity).
2. Capitalisation for `consumer_credit_*` and `consumer_mortgage` (Cass. 2012), and after an opening judgment (L622-28): enforced by the validator, a DB refusal of `capitalisation` entries and a property test.
3. Any engine-posted component outside the regime's whitelist (`private.component_regime`): consumer regimes per L312-38; B2C without the €40.
4. A debtor-borne recovery fee (L111-8 al. 2). The component does not exist and the validator refuses the key. Cost components need an enforceable title dated on or before the entry and the act as evidence.
5. The €40 outside `commercial_b2b`, outside EUR, when the opening judgment is on or before the due date, while a dispute hold is active, or when the seller included it.
6. Any accrual or charge dated inside a stop interval: after admissibility (L722-14), after an opening (except the loan contract-rate exception), and suspended rules during a 1343-5 delay.
7. Principal before interest (LG006). Measures or orders that impose it → hors calcul.
8. Inferring a mise en demeure, an acceleration, an enforceable date, a contract rate, a due date or an ECB value. Each is an input with evidence, or the stream is blocked.

### 3.4 What the law does not require (so M3 does not build it as law)

- **Hold scopes:** not a legal stop. The engine ignores them (§2.2 #11); a client waiver is a claim-policy instruction (claiming less is always lawful).
- **Monthly posting** is a bookkeeping choice (D9), not a legal one.
- **The receipt balance:** R124-6 prescribes no content (M2b design §2 #7); it is a product choice (D14).
- **Debtor-facing wording beyond R124-4 3°:** none added. The method line on the décompte is explanation, not a legal mention.

### 3.5 Not verified

- **ECB MRO values.** LibreJustice does not carry them; the panel found the ECB hosts blocked (`www.ecb.europa.eu`, `data-api.ecb.europa.eu`, `data.ecb.europa.eu`). Nothing is seeded from memory (D5).
- **CPC 641/642 applied to L313-3** is an analogy (OQ-60).
- For the Cour de cassation decisions above, the full judgments were read. Their current authority under renumbered articles is for counsel (INT-06 note).

### 3.6 Not re-read by the judge (never quoted here)

L312-40, L341-1, L724-1, L732-1, L733-4, L733-7, L631-14, R212-2, CPC 514 and 640, C. civ. 2231 and 2303, the arrêté du 17 décembre 2024 (2025-H1, in CALCULATION_RULES from 2026-11-07), the 2027 version of L441-9, and a CJUE judgment of 1 October 2026 (C-209/25) on the €40 that appeared in search. They are re-read in the slice that relies on them.

---

## 4. Naming

| Concept | Name | Note |
|---|---|---|
| Engine package | `collectoo_worker.engine` (`numbers`, `daycount`, `rates`, `packs`, `facts`, `timeline`, `rules/{streams, charges, capitalisation}`, `schedule`, `limitation`, `replay`, `plan`, `decompte`, `hashing`) | `ENGINE_VERSION = "engine-1"` |
| Allocation | `payments.allocation` unchanged; policy source → `alloc-2` | `allocate` and its properties unchanged (M2b promise) |
| Rule pack | `<claim_type>.<legal_regime>` e.g. `b2b_invoice.commercial_b2b`; file `worker/rule_packs/<pack>/<effective_from>.r<rev>.yaml`; schema `rule-pack/1` | ROADMAP M3-02's `engine/rule_packs` path is corrected (ADR-0005, CLAUDE.md) |
| Facts | `account_event`, `contract_terms`, `creditor_terms`, `claim_policy`, `enforceable_title`, `schedule_line` | DOMAIN's `account_rule_pack` → `account.rule_pack_code` (the regime never changes, CCD-01) |
| Outputs | `statement_snapshot` (ARCHITECTURE name), `account_engine_summary` (cache) | not `account_balance` (clashes with `account_balances()`) |
| Statuses | `ok`, `provisional`, `blocked`, `hors_calcul`, `review_pending` (per item/component reasons) | French labels §13 |
| Restatement | « recalcul » in the UI; reason code `recalculation` | |
| Errors | `LG009` engine guard (whitelist, capitalisation, cost title, €40 regime, metadata) | Python `EngineGuardError` |

---

## 5. Data model (forward-only migrations; RLS on every `public` table; change log on fact tables)

Two kinds of writer:
- Ops inputs are written only through SECURITY DEFINER commands at aal2, with an idempotency key + request hash, compare and set, under 8 s. They insert and enqueue.
- Engine outputs are written only by the worker (service role) or definer functions.

Immutable tables carry `ENABLE ALWAYS` append-only triggers (ADR-0012 pattern). pgTAP tenant isolation applies per table and role.

### 5.1 Reference data (global; read by every authenticated user)

```
public.rate_index(code pk, label_fr, kind legal_rate|ecb_mro, creditor_category consumer_creditor|other|null,
                  periodicity semester|on_change, legal_basis text)
  rows: legal_rate_consumer_creditor, legal_rate_other, ecb_mro

public.rate_value(id, rate_index, valid_from date, valid_to date null (exclusive),
                  rate_percent numeric(9,6) not null,        -- as published: « 2,75 % » → 2.750000
                  source_title, source_url (https), source_quote (verbatim sentence), published_on, read_on,
                  recorded_at, supersedes_id null, reason null)
  append-only (ALWAYS); a correction is a new row superseding the old one with a reason;
  no two current rows of one index overlap (exclusion); legal-rate rows start 01-01 or 07-01 and last 6 months;
  generated migration from worker/rate_tables/*.yaml (make rates; CI: YAML = migration)

private.rule_pack(code pk, claim_type_code fk, legal_regime, label_fr)
private.rule_pack_version(id, pack_code, effective_from, revision ≥ 1, schema_version, applies_by,
                  content jsonb (canonical parse), compute_sha256 (rules only), document_sha256 (whole file),
                  source_path, indices text[], components text[], loaded_at,
                  activated_at null, activated_by null, dry_run_id null)
  unique (pack_code, effective_from, revision); append-only except one-time activation (definer command);
  generated migration from worker/rule_packs (make rule-packs; CI: YAML = migration; a committed version
  never changes)
private.rule_pack_validation(version_id, golden_set_sha256, cases int, validated_by (founder), validated_on, note)
  append-only; a version is VALIDATED only with such a row (status is not inside the hashed content)
public.account.rule_pack_code      -- set at confirmation from (claim_type, legal_regime), back-filled; never
                                     recomputed
```

Rates are never typed in the UI. The « Taux » page lists them with their sources, plus a banner for a missing semester.

### 5.2 Facts per file (M3a-3)

```
public.account_event(id, organization_id, client_organization_id, portfolio_id, account_id, claim_item_id null,
                     kind, event_date (Paris business date), details jsonb (schema per kind),
                     evidence_document_id, source tape|ops|client|system, source_row_ref null,
                     recorded_at, recorded_by, voids_event_id null, reason, idempotency key)
  append-only; a correction is a voiding event; evidence required for every kind (tape: the tape document +
  row ref, which is enough for no kind that adds a charge or late interest on its own, §7.5)
  kinds v1:
    formal_notice {sent_on, received_on, method, items[], regularisation_days null}
    acceleration {notice_event_id}            -- consumer: notice with expired delay required (§7.5)
    collective_proceeding_opened {kind sauvegarde|redressement|liquidation, court}
    collective_proceeding_closed               -- recorded; never resumes interest
    surendettement_admissible                  -- decision date
    surendettement_measures {kind}             -- → hors calcul
    judicial_delay {from, to, reduced_rate bool, capital_first bool}
    judgment {court, case_ref}                 -- → hors calcul
    judgment_enforceable {basis}, jex_decision {majoration_pp}   -- L313-3 primitive (unit tests only)
    interest_forfeiture                        -- → hors calcul
    rescheduling                               -- R312-35 restart
    acknowledgement                            -- 2240 (prescription only)
    court_claim_filed                          -- 2241 (prescription and forclusion)
  place_account_hold(surendettement | collective_proceeding) is redefined: it asks the legal date and writes
  the matching event in the same transaction

public.contract_terms(id, account_id, claim_item_id null, terms jsonb (schema terms-1, checked in SQL and
                      pydantic, parity test), evidence_document_id, source tape|ops|client, supersedes_id null,
                      recorded_at, recorded_by, reason)
  append-only; attached to the contract or item, never time-sliced; a correction supersedes from origin
  terms-1 keys: contract_rate_percent, rate_type fixed|variable|actuarial, day_count, payment_frequency,
    term_months, deferred_payment_months, first_due_date, instalment_minor, late_rate_percent | late_margin_pp,
    contractual_indemnity {percent, base[]}, capitalisation_clause, exigibility_is_notice,
    statutory_indemnity_clause, seller_included [late_penalty|b2b_flat_indemnity|statutory_indemnity|
    legal_interest] (what the seller already charged in the boarded amounts)
  EU tape mapping: 3.14 rate, 3.15 type, 3.17/3.18 index, 3.20 margin → terms (variable → blocked)

public.creditor_terms(id, client_organization_id, portfolio_id null, applies_to_invoices_issued_from date,
                      penalty_clause cgv_rate|no_clause|unknown, cgv_rate_percent null, evidence_document_id,
                      supersedes_id null, recorded_at, recorded_by, reason)
  chosen by the invoice's issue date; never re-rates earlier invoices

public.claim_policy(id, client_organization_id, mandate_id, portfolio_id null, account_id null,
                    claim_item_id null, version, effective_from (≥ recording date: prospective),
                    claimed_components text[] (subset of the pack's), pre_cutoff from_legal_start|from_servicing_start,
                    waiver_scope null|from_origin|from_date, mandate_clause_ref, evidence_document_id, reason)
  most specific scope wins (item > account > portfolio > mandate); no row → principal + seller-declared
  openings only; a waiver « depuis l'origine » is the only retroactive instruction (it can only lower amounts)

public.enforceable_title(id, account_id, kind judgment|injonction_de_payer|notarial_deed, decision_date,
                         enforceable_on, basis, evidence_document_id)     -- for the cost guard only

public.schedule_line(account_id, claim_item_id, seq, due_date, capital_minor, interest_minor, insurance_minor,
                     crd_after_minor, source imported|rebuilt, schedule_version, boarding_batch_id)   -- immutable

public.party.public_body boolean null      -- from the INSEE legal category when the tape has it, else ops;
                                              true → B2B accessories hors calcul
```

Boarding: new mapping targets (`event.formal_notice.*`, `event.acceleration.*`, `terms.*`, `creditor_terms.*` at onboarding, a schedule file). The registry, `targets.json` and the mapping eval are updated; the eval must stay at or above its threshold.

### 5.3 Ledger vocabulary (M3a-3)

New `public.ledger_component` rows:

| code | family | sort | label_fr | reference |
|---|---|---|---|---|
| `contractual_interest` | interest | 21 | Intérêts conventionnels échus | contract, schedule |
| `late_interest` | interest | 22 | Intérêts de retard | L312-39; contractual late rate |
| `legal_interest` | interest | 23 | Intérêts au taux légal | C. civ. 1231-6 |
| `late_penalty` | interest | 24 | Pénalités de retard | C. com. L441-10 II (family ⚖️ OQ-55) |
| `capitalised_interest` | interest | 25 | Intérêts capitalisés | C. civ. 1343-2 (rank ⚖️ OQ-63) |
| `statutory_indemnity` | indemnity | 40 | Indemnité légale de défaillance | D312-16 |
| `b2b_flat_indemnity` | indemnity | 41 | Indemnité forfaitaire pour frais de recouvrement | L441-10 II, D441-5 |
| `contractual_indemnity` | indemnity | 42 | Indemnité contractuelle (clause pénale) | contract; C. civ. 1231-5 |
| `procedure_cost` | cost | 60 | Frais taxables | L312-38 al. 2 (title required; nothing posts in M3) |
| `enforcement_cost` | cost | 61 | Frais d'exécution forcée | CPCE L111-8 al. 1 (title + act; nothing posts in M3) |

The M2b waterfall already ranks families (interest → accessories → principal → unclassified), so no allocation code changes.

**`private.component_regime`** (component × legal_regime × condition `none` / `title_required`) is checked by an `ALWAYS` set-based trigger on every 1100 posting of a non-opening entry (`LG009`). Openings keep the seller's components (OQ-18). The whitelist per regime:

| Regime | Components |
|---|---|
| consumer regimes | principal, `contractual_interest`, `late_interest`, `statutory_indemnity`, `procedure_cost` (title) |
| `commercial_b2b` | principal, `late_penalty`, `b2b_flat_indemnity` |
| `consumer_b2c` | principal, `legal_interest` |
| `professional_credit` | principal, `contractual_interest`, `late_interest`, `legal_interest`, `capitalised_interest`, `contractual_indemnity` |
| every regime | `enforcement_cost` (title), and the seller's opening components |

New entry types. All are claim books only (1100/3100), all require `engine_version`, `inputs_hash` and `rule_pack_version_id` (the pack version must belong to the account's pack), and all are posted only through `private.engine_post_plan` → `ledger_post_set`. `ledger_post` refuses them.

| type | lines |
|---|---|
| `accrual` | Dr 1100[item, interest-family component] / Cr 3100[owner, portfolio, component]; every 1100 line > 0 |
| `charge` | the same shape with an indemnity-family component; `source_id` = the rule id |
| `capitalisation` | inside one item: Cr 1100[unpaid interest components] / Dr 1100[`capitalised_interest`]; mirror on 3100; Σ1100 per item = 0; refused on consumer regimes and after an opening event |

Corrections are ordinary reversals.

ADR-0013 I6 already covers every entry that moves an allocated receivable, reversals included. So reversing an accrual that a live allocation paid fails with `LG007` unless the allocation is reversed in the same set (§9.4).

### 5.4 Engine runtime

```
private.engine_state(account_id pk, dirty_from date null, posted_through date null, fact_stamp bigint,
                     last_inputs_hash, last_run_id, status, status_reasons jsonb (per item × component),
                     updated_at)
  fact_stamp is bumped by every dirty trigger; compute reads it, posting re-checks it under the lock
private.engine_run(id, organization_id, kind close|allocate|recompute|restate_all|dry_run|summary|statement,
                   through, engine_version, counts jsonb, timings jsonb, started_at, finished_at)
private.engine_plan_entry / _line / _reversal / _segment (run_id, …)   -- stored plan: a retry posts the same
                                                                          plan with the same keys
private.accrual_segment(entry_id, claim_item_id, component, seg_from, seg_to, posted_from, posted_to,
                        base_minor, rate_value_id null, terms_ref null, rate_micro bigint, day_count, basis,
                        days, line_minor, cum_posted_minor, rule_id, ref)                       -- explain rows
private.restatement(id, run_id, account_id, from_date, cause jsonb, old_inputs_hash, new_inputs_hash,
                    effect jsonb (per payment: old/new totals, lines, remitted lines), effect_sha256,
                    status applied|review_pending|approved|reverted, decided_by, decided_at)
public.engine_close(organization_id, month date, statements_complete_on date, posted_run_id, posted_at)
  -- the close watermark is a fact: replay reproduces close dates
public.account_engine_summary(account_id pk, as_of, principal_minor, interest_minor, indemnity_minor,
                     other_minor, total_minor, posted_through, pending_minor, status, status_reasons,
                     inputs_hash, engine_version, computed_at)         -- cache, rebuildable, no lock
public.statement_snapshot(id, number text null 'D-AAAA-NNNNNN' (issued only), account_id, as_of, known_at,
                     purpose ops|client|letter|receipt|bailiff, audience staff|debtor, payload jsonb,
                     payload_sha256, document_id null, engine_version, rule_pack_version_ids uuid[],
                     inputs_hash, template_version, renderer_version, issued_by, created_at)   -- append-only
private.statement_staleness(snapshot_id, detected_at, cause)          -- issued snapshots overtaken by a recompute
```

RLS:
- `statement_snapshot` and its PDF: read by the portfolio's staff and the client's members (policies as `receipt`, M2b-5).
- `account_engine_summary`: read by the portfolio's staff and the client's members.
- `restatement`: staff only.
- `private` tables are not exposed.
- Numbering: a yearly counter per servicer, not claimed gapless (as receipts).

### 5.5 Dirty marking (statement-level triggers over transition tables; set `dirty_from = least(…)` and bump `fact_stamp`)

| Change | Marks dirty from |
|---|---|
| `account_event` insert, or a voiding event | the event date |
| `contract_terms` version | the servicing start (it applies from origin) |
| `creditor_terms` version | each affected invoice's first late day (only invoices issued on or after `applies_to_invoices_issued_from`) |
| `claim_policy` | its `effective_from` (≥ today: no restatement), or the servicing start for a waiver « depuis l'origine » |
| `rate_value` insert or supersede | `valid_from`, only for accounts whose pack reads the index and whose `posted_through` or pending lines reach that date (a future-dated row dirties nothing) |
| `rule_pack_version` activation | its `effective_from`, for the accounts of that pack (activation follows a dry run, §6.4) |
| any non-engine entry touching 1100 with `effective_date < posted_through` (late allocation, reversal, return, netting, direct payment, adjustment) | that date |

Engine entries carry `source_type = 'engine'`, so the triggers ignore them. Measured on the 50k run (one UPDATE per fan-out).

---

## 6. Rate tables (M3-01)

1. **Authoring.** `worker/rate_tables/legal_rate.yaml` and `ecb_mro.yaml` hold one entry per value: index, valid_from, `rate_percent` as a quoted string, the arrêté or notice title, URL, verbatim sentence, published_on, read_on. The loader refuses float scalars.
2. **Seed.**
   - Legal rates: every semester from 2015-H1 to 2026-H2, each read in full on LibreJustice during M3a-1. 2024-H1, 2025-H2, 2026-H1 and 2026-H2 are already read (§3.1). Search snippets are never a source.
   - Before 2015 the rate was a single one. Claims needing it are blocked (`rate_missing`).
3. **ECB MRO (D5).**
   - Stored per change date with its source.
   - Primary source: the Official Journal C notices of the rate applied by the ECB to its main refinancing operations, on EUR-Lex (`eur-lex.europa.eu`, already allowed). M3a-1 tries it.
   - If that does not cover every 1 January and 1 July since 2019, the founder allows `data-api.ecb.europa.eu` (ECB Data Portal) or sends the values with their ECB links. The host is never worked around.
   - Until loaded, the B2B `no_clause` and `unknown` paths report `blocked: rate_missing`; the `cgv_rate` path works.
4. **Lookup.**
   - `RateBook.value(index, day, known_at)` returns a `Rate` (integer micro-percent + row id) or `Missing(index, semester)`, never a guess. A SQL twin is parity-tested on 10k dates.
   - Legal rate: the semester containing the day.
   - MRO for L441-10: the value in force on 1 January (H1) or 1 July (H2).
   - Rates are read « as known at » for reproducibility.
5. **Missing semester (D5).**
   - Streams that need it stop at the last known day. The file becomes `provisional` with that date and payments keep being allocated on the interest known so far.
   - No issued décompte goes beyond that day.
   - When the row arrives, a recompute restates automatically if cash totals are unchanged (§10).
   - Alert `rate_next_semester_missing` daily from 1 June and 1 December; P0 from the semester's first day.

---

## 7. Rule-pack format (M3-02)

### 7.1 Principles

- **A pack is data.** The **vocabulary** is code: a closed, versioned set of primitives. An unknown key is an error, so a new rule kind means an engine change with tests (ADR-0005).
  - Rate sources: `term`, `index` (with `fixing`), `times`, `plus_pp`, `lowest_of`, `floor`, `steps` (L313-3).
  - Anchors: `item.due_date`, `event:<kind>`, `schedule`.
  - Stops: `stop` / `suspend` / `hors_calcul`.
  - Amounts: `fixed_minor`, `percent_of`.
  - Also `capitalisation`, `limitation` and `allocation`.
- **Two time axes.**
  - `effective_from` + `applies_by` is **law time**. `applies_by` is one of `accrual_day`, `contract_date` or `invoice_issue_date`, and must cite its transitional reference.
  - `revision` is **knowledge time**: a correction of our encoding. It is applied only by activation, after a dry run, and marks files dirty from `effective_from`.
  - A regime (pre/post CCD2) is a separate pack, not a version.
- **References.** Every stream, charge, stop, limitation and allocation rule names keys of `legal_references`. Each reference carries the title, article and paragraph, the article versions encoded, URL, read date and a verbatim quote. A contract term names the term.
- **Conventions** (first-day offset, period, year basis, rounding) are a block of the pack. Golden cases may override them per case to diagnose « convention vs error » without code.

### 7.2 B2B invoice (abridged, TO VALIDATE)

```yaml
schema: rule-pack/1
pack: b2b_invoice.commercial_b2b
effective_from: 2019-04-26
revision: 1
applies_by: accrual_day                 # Cass. com. 3 mars 2009: of immediate application
transitional_ref: cass_com_2009_03_03
coverage: {first_late_day_from: 2019-04-26}      # earlier → hors calcul (L441-6 2019-02/04 version not read)
legal_references:
  l441_10_ii:
    title: "C. com. art. L441-10 II"
    url: https://librejustice.fr/norm/fr/code-de-commerce/l441-10
    versions_read: ["2019-04-26/2026-08-31", "2026-09-01/2026-12-31", "2027-01-01/"]
    read_on: 2026-11-09
    quote: "Les pénalités de retard sont exigibles sans qu'un rappel soit nécessaire."
  d441_5: {title: "C. com. art. D441-5", url: …, read_on: 2026-11-09, quote: "… est fixé à 40 euros."}
  cjue_c_370_21: {title: "CJUE 1er déc. 2022, C-370/21, pt 26", url: https://librejustice.fr/decision/jj5vhyqjUk1b, …}
  l622_28: {…}
  c_civ_1343_1: {…}
  c_civ_1343_5: {…}
  l110_4: {…}
inputs:
  item.due_date: {type: date, required: true}                    # L441-10 I default unknown → blocked
  creditor_terms.penalty_clause: {type: enum, values: [cgv_rate, no_clause, unknown], required: true}
  creditor_terms.cgv_rate_percent: {type: rate, required_if: {penalty_clause: cgv_rate}}
conventions: {first_day_offset: 1, period: half_open, year: calendar, rounding: half_up_per_line}   # D1, D2
components:
  late_penalty: {family: interest, ref: l441_10_ii}
  b2b_flat_indemnity: {family: indemnity, ref: [l441_10_ii, d441_5]}
streams:
  - id: penalties
    component: late_penalty
    items: [invoice]
    base: [principal]
    start: {anchor: item.due_date, ref: l441_10_ii}           # first day = due date + first_day_offset
    stop:
      - {event: collective_proceeding_opened, ref: l622_28}
      - {event: surendettement_admissible, ref: l722_14}      # an individual trader can be one
      - {event: judicial_delay, mode: suspend, ref: c_civ_1343_5}
    rate:
      by_input: creditor_terms.penalty_clause
      cgv_rate:
        term: creditor_terms.cgv_rate_percent
        floor_check: {index: legal_rate, category: creditor, times: "3", per: semester}
        below_floor: apply_as_written_flagged                  # OQ-54
      no_clause: {index: ecb_mro, fixing: semester_start, plus_pp: "10"}
      unknown:
        lowest_of:
          - {index: legal_rate, category: creditor, times: "3", per: semester}
          - {index: ecb_mro, fixing: semester_start, plus_pp: "10"}
    open_questions: [OQ-54, OQ-55]
charges:
  - id: flat_indemnity
    component: b2b_flat_indemnity
    amount: {fixed_minor: 4000, currency: EUR}
    per: claim_item
    items: [invoice]
    when: item_paid_or_open_after_due_date
    at: {anchor: item.due_date, offset_days: 1}
    unless:
      - {event: collective_proceeding_opened, on_or_before: item.due_date, ref: l441_10_ii}
      - {seller_included: b2b_flat_indemnity}
    hold_while: [{hold: dispute}]                              # « à moins que le débiteur ne soit pas responsable »
    bears_interest: false
    ref: [l441_10_ii, d441_5, cjue_c_370_21]
    open_questions: [OQ-2, OQ-6, OQ-56]
capitalisation: false                                          # OQ-55
pre_cutoff: {by_claim_policy: true, base: cutoff_principal, skip_if_seller_included: true}
allocation:
  accessory_rank: {default: before_principal, overridable: true}   # OQ-7
  unclassified: last
  ref: [c_civ_1343_1]
limitation: [{kind: prescription, period: P5Y, from: item.due_date,
              interrupted_by: [acknowledgement, court_claim_filed], ref: l110_4}]
hors_calcul_if: [{party: public_body}, {event: judgment}]
```

### 7.3 B2C invoice (differences)

```yaml
pack: b2c_invoice.consumer_b2c
applies_by: accrual_day
components: {legal_interest: {family: interest, ref: c_civ_1231_6}}
streams:
  - id: legal_interest
    component: legal_interest
    items: [invoice]
    base: [principal]
    start: {event: formal_notice, date: received_on, requires_evidence: true, ref: [c_civ_1231_6, c_civ_1344]}
    # exigibility-as-notice clause route disabled for consumers (OQ-3)
    stop: [{event: surendettement_admissible, ref: l722_14}]
    rate: {index: legal_rate, category: creditor, per: semester}
charges: []                                  # no €40 (L441-10 binds « Tout professionnel »)
capitalisation: false                        # judgment only; judgments hors calcul in M3
limitation: [{kind: prescription, period: P2Y, from: item.due_date, ref: l218_2}]
```

### 7.4 Professional loan (differences)

```yaml
pack: professional_loan.professional_credit
applies_by: contract_date
coverage: {contract_date_from: 2016-10-01}          # ord. 2016-131 art. 9 (earlier: no capitalisation)
inputs:
  contract_terms.contract_rate_percent: {required: true}
  contract_terms.rate_type: {required: true, allowed: [fixed]}      # variable → hors calcul
  contract_terms.term_months: {required: true}                       # L622-28 exception
  contract_terms.late_rate_percent: {required: false}
  contract_terms.late_margin_pp: {required: false}
  contract_terms.contractual_indemnity: {required: false}
  contract_terms.capitalisation_clause: {required: false}
streams:
  - id: schedule_interest                        # due at each instalment date, from the schedule
    component: contractual_interest
    source: schedule
    until: {event: acceleration}
  - id: late
    component: late_interest
    base: [principal]
    start: {event: acceleration}
    requires_one_of: [contract_terms.late_rate_percent, contract_terms.late_margin_pp]
    rate: {one_of: [{term: late_rate_percent}, {term: contract_rate_percent, plus_term_pp: late_margin_pp}]}
    stop:
      - event: collective_proceeding_opened
        keep_if: {kinds: [sauvegarde, redressement], loan_term_ge: P1Y}
        keep_rate: {term: contract_rate_percent}               # margin stops: OQ-58
  - id: legal_fallback                           # only when no late clause exists
    component: legal_interest
    base: [principal]
    start: {event: formal_notice, date: received_on}
    rate: {index: legal_rate, category: creditor}
    enabled_if_absent: [late_rate_percent, late_margin_pp]
charges:
  - id: indemnity
    component: contractual_indemnity
    percent_of: {term: contractual_indemnity.percent,
                 base: [principal, contractual_interest]}      # charge base may include échu interest
    at: {event: acceleration}
    requires_term: contractual_indemnity
    requires_event: [formal_notice]                            # 1231-5 al. 5 (an acceleration notice counts, OQ-61)
    bears_interest: false
capitalisation:
  source: contract_clause
  period: P1Y
  anchor: stream_start
  moves: unpaid_interest_of_elapsed_year_and_interest_due_1y
  never_after: collective_proceeding_opened
  ref: [c_civ_1343_2, l622_28]                                 # OQ-63
limitation: [{kind: prescription, period: P5Y, from: item.due_date, ref: l110_4}]
hors_calcul_if: [{event: collective_proceeding_opened, kind: liquidation}, {event: judgment}]
```

### 7.5 Consumer instalment loan, pre-CCD2 (the `_ccd2` pack starts as a copy, TO VALIDATE, OQ-10)

```yaml
pack: consumer_instalment_loan.consumer_credit_pre_ccd2
applies_by: contract_date                                   # ord. 2025-880 art. 99 II; CCD-01
conventions: {year: calendar, refuse_day_counts: [ACT/360, 30/360, 30E/360]}   # Cass. 1re civ. 19 juin 2013
whitelist: [principal, contractual_interest, late_interest, statutory_indemnity, procedure_cost]
streams:
  - id: schedule_interest
    component: contractual_interest
    source: schedule
    until: [{event: acceleration}, {event: surendettement_admissible}]
  - id: late
    component: late_interest
    base: [principal]                                         # capital only (INT-06; OQ-62)
    start:
      event: acceleration
      requires: {notice_event: formal_notice, with: regularisation_days, expired_before: acceleration}
    rate: {term: contract_terms.contract_rate_percent}
    stop: [{event: surendettement_admissible}, {event: collective_proceeding_opened}]
    # no late interest on unpaid instalments before acceleration (OQ-4)
charges:
  - id: d312_16
    component: statutory_indemnity
    percent_of: {percent: "8", base: capital_after_last_due_instalment, at_date: acceleration}   # OQ-5, OQ-61
    requires_term: statutory_indemnity_clause
    requires_claim_policy: true
    unless:
      - acceleration_before_servicing_start                   # unless ops attest 3.11 excludes it
      - {seller_included: statutory_indemnity}
      - {event: surendettement_admissible, on_or_before: acceleration}
    bears_interest: false
    exclusive_group: d312                                     # D312-17 disabled in M3
capitalisation: false                                         # forced (validator + DB)
allocation: {unclassified: held, not_yet_due_capital: held_until_acceleration}
limitation:
  - kind: forclusion
    period: P2Y
    from: [first_unregularised_incident_computed, non_payment_after_termination]
    restart_after: [rescheduling, surendettement_measures]
    interrupted_by: [court_claim_filed]                       # acknowledgement refused (2220)
    ref: [r312_35, c_civ_2220, c_civ_2241]
hors_calcul_if: [{event: surendettement_measures}, {event: interest_forfeiture}, {event: judgment},
                 {event: judicial_delay, any: [reduced_rate, capital_first]}, {terms: {rate_type: variable}}]
```

**Without a recorded acceleration notice** (most EU tapes): openings are as declared (3.09/3.10/3.11). No late interest and no indemnity are added; the file shows « déchéance du terme non justifiée » until ops attach the notice. This is D8; ops can bulk-attach documents through the M1-20 zip.

### 7.6 Validation (load time and CI; all errors reported together with file, path and reason; one failing fixture per rule)

1. JSON Schema (draft 2020-12), with the closed vocabulary.
2. The YAML loader refuses float, sexagesimal and unquoted percent scalars. Rates are strings, minor amounts integers, dates ISO; only `true`/`false` are booleans.
3. Every rule names references that resolve, each with a URL, a read date and a quote. Every `open_questions` id exists in COMPLIANCE §9.
4. Stream bases hold no interest-family component except `capitalised_interest`; charge bases may.
5. `capitalisation` is false for `consumer_credit_*` and `consumer_mortgage`, and never enabled for B2B in v1.
6. Components exist with the declared family and are in `private.component_regime` for every declared regime. No `recovery_fee` key. Cost components need `requires: enforceable_title`.
7. `b2b_flat_indemnity` only for `commercial_b2b`, with an EUR amount.
8. No allocation key orders principal before interest (`Policy.from_json` refuses unknown keys).
9. L313-3 `steps` only on streams whose rate is a legal-rate index.
10. `contractual_indemnity` and `statutory_indemnity` require a notice event (1231-5 al. 5).
11. Forclusion rules refuse `acknowledgement`.
12. Consumer packs refuse 360-day bases.
13. Every index exists. Versions of one pack never overlap (except revisions of the same date), and revisions increase.
14. A pack has `applies_by` and a transitional reference.
15. `status: validated` is never in the YAML; it comes from `rule_pack_validation`.

### 7.7 Loading, activation, validation

1. **Generated migration.** `make rule-packs` generates one forward-only migration per new version, like `make catalogue`. CI fails if a YAML has no identical migration or a committed version changed. The worker ships the same files and accepts both the old and new `compute_sha256` during a deploy.
2. **Inactive on arrival.** A new version or revision lands inactive.
3. **Activation.** `activate_rule_pack_version(key, version_id)` (admin, aal2) needs a completed `engine.dry_run`: a replay of every file of the pack without posting, reporting files changed, Σ Δ per family, restatements that would need review, and blocked files. Activation stores `dry_run_id` and marks the files dirty.
4. **Recompute trigger.** Only a change of `compute_sha256` triggers a recompute; labels and references do not.
5. **Validation.** A version becomes VALIDATED when the founder signs `worker/tests/golden/<claim_type>/SIGNOFF.yaml`, which lists the case files and their sha256. A migration then inserts the `rule_pack_validation` row (`validated_by` = the founder, never Claude).

---

## 8. Engine (pure Python, `collectoo_worker.engine`, `engine-1`)

### 8.1 Inputs and outputs

**Inputs** are loaded set-based by a thin repository, through analysed temp tables (ARCHITECTURE §4, `stats_helpers` adverse settings):
- items with due and issue dates;
- per (item, component), the dated ledger deltas with entry types;
- live and reversed allocation entries with their `allocation_plan` (policy as stored, designation);
- direct payments and nettings;
- events (including voided ones, for the hash);
- contract terms, creditor terms, claim policy;
- schedule;
- owner capacity per day (`claim_ownership_period`);
- servicing start and end;
- the close watermark;
- pack versions (parsed);
- a `RateBook` restricted to the needed indices;
- `through`, `known_at`.

**Outputs:**
- **décompte lines**: segments, charges, capitalisations, allocations;
- the **target ledger**: per posting date p and (item, component), the cumulative engine amount for days < p;
- the **target split** of each live allocation and direct payment;
- `blocked[]`, `hors_calcul[]`, warnings, limitation dates;
- the **inputs hash**: sha256 of canonical JSON (sorted keys; integers; rates as integer micro-percent; ids). It covers every fact including voided events, pack `compute_sha256`s, rate row ids and values, engine and alloc versions, and `through`.

No I/O and no clock (`through` is a parameter). A static test bans `float`, float literals, `datetime.now`, `date.today` and any LLM/AI import in `engine/`. Inputs are sorted canonically, so their order never matters.

### 8.2 Timeline and segments

- **Breakpoints:** first days of streams, events, stop and suspend bounds, cash events (base changes), rate-row boundaries of the indices a stream uses, the L313-3 step, capitalisation anniversaries, year boundaries when the year length changes, ownership boundaries, `through`.
- **An economic segment** is a maximal `[a, b)` per (item, stream) where base, rate value, basis and stop state are constant. Adjacent sub-intervals with equal values are merged, so a pack-version date, an equal rate row or a posting date never splits a line.
- **Day d bears interest on what is owed after the cash events of day d − 1.** A payment on D stops interest on what it paid from D (the payment day is not charged on it). A return on R raises the base from R (OQ-25 updated).
- **Day order on D:**
  1. accrue the days before D;
  2. events dated D;
  3. charges falling due on D;
  4. capitalisation on D;
  5. cash events on D, in M2b processing order (booking date, statement, line, payment id);
  6. the posting point at D.

### 8.3 Day counts and conventions (pack data; defaults per D1, D2)

| Convention | Default | Effect on the worked examples (§12) |
|---|---|---|
| First day | the day after the triggering date: due date (L441-10 « le jour suivant »), receipt of the notice (1231-6), acceleration (L312-39) | examples 1, 3, 4 lose one day |
| Period | `[first_day, end)`, end = the day the base drops; a décompte « au D » = what must be paid on D (days < D) | — |
| Year basis | `ACT/ACT_CALENDAR` (366 in a leap year; split only where the year length changes) for interest the engine computes; contract day count for contract streams of professional loans; consumer packs refuse 360-day bases | none before 2028 |
| Schedule interest | as the imported or rebuilt schedule (monthly rate = annual / 12, rounded per period) | example 1 schedule 234,85 € |
| `30E/360` (contracts only) | its own day formula, not `end − start` | — |

### 8.4 Arithmetic and rounding

- A rate is converted to integer micro-percent: `rate_micro = rate_percent × 10⁶`. More than 6 decimals is refused.
- The exact amount of a segment is `num / den` with `num = base_minor × rate_micro × days` and `den = 100 × 10⁶ × basis`.
- The **line amount** is `(2·num + den) // (2·den)`, half-up (num ≥ 0; bases are never negative).
- A posting inside a segment posts `round(exact[a, p)) − (already posted for this segment)`, so totals never depend on posting dates.
- `lowest_of` and `times` are evaluated in exact rationals before rounding.
- A reference implementation with `fractions.Fraction` is checked by properties.

### 8.5 Rules

- **Starts:** due + offset; a `formal_notice` with evidence (`received_on`); acceleration with its preconditions; the schedule.
- **Stops** (`stop`), **suspensions** (`suspend`, 1343-5) and **hors calcul** events. Hors calcul closes every stream of the file at its date; later days are not computed, and the décompte can no longer be issued.
- **Charges:** dated at `max(trigger, servicing start)`. Before the cut-off they need the claim policy (`from_legal_start`) and must not be seller-included. A `hold_while` rule holds the charge (not posted) until the hold is lifted, then posts it at its original date.
- **Capitalisation:** at each anniversary of the stream's first day, unpaid interest of the elapsed full year plus unpaid interest due for ≥ 1 year (example 2's 68,46 € of instalment interest) moves to `capitalised_interest`, which then bears the stream's rate. Only unpaid amounts move, so I6 is never at risk. It never applies after an opening, nor for contracts before 2016-10-01 (OQ-63).
- **L313-3 primitive:**
  - the step starts the day after `expiry = add_months_cpc641(enforceable_on, 2)`, extended to the next working day (642);
  - it applies only to legal-rate streams;
  - it is reduced or waived by `jex_decision`;
  - it is suspended during a 1343-5 delay;
  - unit tests only.
- **Pre-cut-off:**
  - B2B items with `pre_cutoff: from_legal_start`: computed from the first late day on the **cut-off principal** (never higher; undated earlier partial payments ignored, debtor-favourable), posted at the servicing start with the true periods on the décompte.
  - B2C: only from a notice in evidence.
  - Loans: the seller's 3.10 as declared; the engine starts at the servicing start.
- **States:**
  - `provisional`: a rate is missing after X; lines stop at X.
  - `blocked`: an input needed now is missing (ECB value, due date, contract rate, notice), for that item and component only.
  - `hors_calcul`: frozen at the event date.
  - `review_pending`: a restatement waits.

  Each carries a French reason. Several can hold at once per item.

### 8.6 Allocation inside the replay (M3-15)

At each allocation date D, in order:
1. The replay state gives the slots at D. This includes interest for days < D and charges falling due on or before D. It excludes, before acceleration, loan capital not yet due (§2.2 #17), and items or components that are blocked or hors calcul.
2. The policy comes from:
   - **for a new allocation:** the pack version at D (defaults: `accessory_rank`, `unclassified`), then `allocation_policy` only where the pack says `overridable`, then `for_regime` (consumer → `held`);
   - **for a restated allocation:** the policy id and version stored in its `allocation_plan` (a later policy edit never restates earlier allocations).
3. The designation is read from the plan.
4. The unchanged `payments.allocation.allocate` runs, with `cap_items`.
5. The amount is the payment's live allocated amount A on this file. A new allocation uses the payment's U as M2b does.

`ENGINE_VERSION` of allocation becomes `alloc-2`; the pack version id enters the allocation `inputs_hash`.

---

## 9. Ledger integration (M3-13)

### 9.1 Posting dates P(file): a function of recorded facts only

P(file) is the union of:
- the dates of every allocation, direct-payment and netting entry of the file, live or reversed;
- the date of each charge;
- each capitalisation date;
- each close date of `engine_close` (the 1st of the month following a closed month);
- ownership-period and servicing-end boundaries;
- the servicing start (pre-cut-off amounts);
- the closure date.

Documents never add a date.

An `accrual` entry dated p covers days < p. The page reads it as « intérêts comptabilisés jusqu'au JJ/MM inclus » (p − 1). Nothing is posted after today (Paris) or before the servicing start.

### 9.2 Monthly close (D9)

- The close for month M is dated the 1st of M+1. It runs once every active `client_funds` account of the servicer has bank statements through the last day of M (M2b-2 data), and at the latest on the 5th business day of M+1.
- It is a job `engine.close` (pg_cron in UTC, deriving the Paris date inside the job). It writes `engine_close` and posts per file only what differs from the target.
- A payment imported after the close and dated in M restates the close entry automatically (accruals only).

### 9.3 Plan

For each (item, component) and each p in P ascending:
- `target_delta(p) = target_cum(p) − target_cum(p_prev)`;
- the posted delta = the live engine entry at p.

Only differing entries are reversed and re-posted, each at its own date. Unchanged later entries stay, even when earlier ones changed (engine critique G4). Zero deltas post nothing; the ledger refuses zero lines and entries with fewer than two lines.

Identical inputs give an empty plan (property). An inputs-hash change with identical lines also gives an empty plan, because lines are compared and hashes ignored.

### 9.4 Write path

1. **Compute outside the lock** (`engine.recompute`, `engine.close`, `restate_all`). The stored plan goes to `private.engine_plan_*`, and each file's `fact_stamp` is recorded.
2. **Post under the lock.** Lock order as ADR-0013: files `FOR KEY SHARE`, then the servicer's allocation lock. `private.engine_post_begin()` drops and recreates the `_eng_*` temp tables (as `allocation_begin()`), then `private.engine_post_plan(run_id, chunk)`:
   - (a) re-checks each file's `fact_stamp`; a changed file is skipped and re-queued;
   - (b) re-checks set-based: account confirmed and open, servicing started, pack version active and of the account's pack, whitelist, cost title, no consumer capitalisation, no future date, engine metadata;
   - (c) passes allocation lines through the **shared** `private.check_allocation_lines()`, extracted from `post_allocations` (LG006 1343-1, LG007 item net, currency, servicing start as of D); `post_allocations` calls the same function;
   - (d) **one `ledger_post_set` call per chunk**, extended to take reversal rows. Every reversal, engine entry and re-posted allocation of a file goes in the same set, so the immediate checks (I4, I6, mirror, closure) see only the final state. Inside the set, rows are ordered: reversals of allocations latest first, reversals of engine entries, new engine entries in date order, new allocations in date order;
   - (e) writes `accrual_segment`, `allocation_plan` (with `replaces_entry_id`, `restatement_id`), notifications, the receipts queue, `engine_state`.
3. **Chunks of 2,000 files per transaction** (the M2b-6 lesson), measured. Interactive commands get the lock between chunks; ops commands keep `lock_timeout = 2 s` (« réessayez »).

### 9.5 Idempotency

- Keys are `eng:<run_id>:<account_id>:<seq>` and `engrev:<run_id>:<reversed_entry_id>`. Request hashes are canonical.
- A retry of the same run posts its stored plan, so it gets the same keys and the same hashes and posts nothing twice.
- A recompute after facts changed gets a new run id and new keys. So A→B→A never replays an already-reversed entry (all three critiques).

### 9.6 Invariants and checks

- **I-E1:** at every p in P, Σ live engine-entry debits per (item, component) up to p = `target_cum(p)` (to the cent).
- **I-E2:** décompte(D) = ledger(D, known_at) + pending(D), where pending lines are those after the last posting date ≤ D, minus the partials already posted.
- **I-E3:** a replay with unchanged inputs gives an empty plan.
- **Existing I4/I6:** they hold for every engine type and its reversals.
- **Nightly checks** (extending `private.run_payment_checks`, one statement each): `engine_ledger_drift` (I-E1 at `posted_through` for every open file), `hors_calcul` count by reason, `provisional` and `blocked` counts, `missing_rate`, `stale_statement`, `restatement_review_ageing` (> 2 business days), `dirty_backlog`.

---

## 10. Re-running earlier allocations by date (M2b founder #16)

1. **Trigger.** A dirty mark (§5.5) queues `engine.recompute` (queue `engine`, debounced to one message per servicer). The job processes dirty files by `dirty_from`. It replays from the servicing start (cost is O(events), so no checkpoints are needed) and plans as in §9.3.
2. **Restatement.** For each live allocation (or direct payment) dated ≥ `dirty_from` whose lines differ, it reverses the entry at its own date and posts a new one at the **same date**, grouped by `restatement_id`.
   - **Automatic** when all of the following hold:
     - every (payment, file) keeps its cash amount (A′ = A);
     - no reversed line belongs to a booked M2c run, or M2c-7's net cover is merged;
     - the file has no active surendettement or collective-proceeding hold (OQ-24).
   - **Otherwise review**: `restatement.status = review_pending`. Nothing from that cause is posted until a decision (atomic; ops critique B4). New payments of the file are allocated meanwhile on the current ledger and are included when the restatement is recomputed at approval.
3. **Review page** « Recalcul à valider ». Each card shows:
   - the cause;
   - Δ interest per family;
   - payments whose allocated total changes (old → new);
   - an overpayment created or absorbed;
   - remitted money concerned.

   Actions:
   - « Valider »: compare-and-set on `effect_sha256`; bulk up to 200;
   - « Annuler la cause »: voids the event or terms with a reason, and the file returns to its previous plan.
4. **Lowering A** turns the excess into an overpayment kept for the payer (M2b founder #8). If it was remitted, M2c-7 covers it. **Raising A** takes only the payment's own unallocated money, never money with a refund requested or executed, and never automatically.
5. **Closed episodes are facts.**
   - Allocations already reversed (returns, ops reversals) are never re-split, since an entry is reversed at most once.
   - If their lines exceed the recomputed balances (e.g. interest they paid no longer exists), the file goes `hors_calcul: closed_allocation_conflict` for ops, rather than a ledger workaround.
   - Nettings stay principal-only facts (OQ-68).
   - Direct payments are restated like allocations (adjustment reversed and re-posted; no client money).
6. **Late payments.** When the allocation job meets a payment dated before `posted_through`, it performs the restatement inline in the same transaction, under the same rules, so the ledger is never wrong in between (legal critique C5). If review is needed, that payment waits with `review_reason = recompute_pending`.
7. **M2c coupling (requirements on M2c-7, to agree before M3c-2):**
   - (a) `cover_remitted_reversals()` nets per (payment, file, `restatement_id`): it advances only `max(0, reversed 4670 − re-posted 4670)` on remitted lines;
   - (b) both entries enter the pending queue, and the statement shows the pair as « imputation recalculée »;
   - (c) the telescoping commission per (file, tier key) gives the family-rate delta, and a credit note or invoice follows in the next run;
   - (d) lines keep their payment's encaissement date E (M2c §9.2 already), so a positive net delta is immediately due, which is why it needs approval;
   - (e) until M2c-7 is merged, a restatement touching a remitted line goes to review by an explicit check, not by the aggregate `LG008`.
8. **Receipts and feed.**
   - The reversal and the new allocation are payment-tagged, so the receipts job issues a new version only when the payment's lines change.
   - `client_notification` rows carry reason `recalculation`; the feed groups the pair as « imputation recalculée au JJ/MM, montant inchangé ».
   - The client is told of an amount change only when its 4670 nets to non-zero.
9. **Go-live.** `engine.restate_all(servicer)` marks every confirmed file dirty from its servicing start and runs the recompute. Cash-total changes are gathered in one bulk review card per servicer. It runs on test and staging data before any real payment (M2c R7).

**Why not a claim-only « reallocation » entry:**
- M2c commission and remittance lines are built from 4670 movements, so a claim-only re-split would change the family split with no line for commission to follow (ops critique M8).
- It is a correction that is not a reversal.
- It would give « live allocation » two meanings for returns and receipts.

---

## 11. Décompte (M3-14) and receipts

### 11.1 Builder

`decompte.build(account, as_of, known_at, audience)` produces canonical JSON with these blocks.

**Header:** file, client (« agissant pour le compte de »), principal debtor, currency, `as_of`, `known_at`, engine version, pack codes, versions and status (« barème à valider » / « validé »), inputs hash.

**Per item:**
- principal: original, credit notes, payments by date and component (receipt number), outstanding;
- each **segment line**: from → to, days, base, rate and its source (« 3 × taux légal, arrêté du 26 juin 2026 » / « taux BCE au 1ᵉʳ juillet + 10 points » / « taux des CGV du … »), year basis, amount, basis (« art. L441-10 II C. com. »), posted or « non comptabilisé »;
- charges with their base and percentage;
- capitalisation events.

**Totals** per R124-4 3° family: Principal / Intérêts / Autres accessoires. Creditor-borne fees cannot exist.

**Staff only:**
- blocked and provisional reasons (« pénalités non calculées : taux BCE non chargé »);
- indicative limitation dates;
- the seller's unclassified consumer amounts (« Autres sommes déclarées — non réclamées (à classer) », OQ-18).

**Optional:** a R211-1 one-month projection, labelled « provision pour intérêts à échoir (1 mois) » (bailiff package later).

**Reconciliation:** Σ lines = ledger(as_of, known_at) + pending (I-E2), or the build fails.

**Refused:**
- hors calcul files;
- `as_of` beyond a provisional date;
- guarantor-facing documents (OQ-65).

### 11.2 Live and issued

- **Live view** (« Voir le calcul ligne à ligne »): a job, no lock, cached 24 h.
- **Issued** (« Établir un décompte », staff at aal2):
  - freezes the payload in `statement_snapshot` with a number, rendered as a deterministic French PDF (the M2b-5 stack: reportlab pinned, invariant mode, DejaVu committed, metadata from the payload);
  - **issuing never posts**: the total is ledger + pending, each part shown;
  - the nightly check flags issued snapshots whose date's lines have changed (« Le décompte D-2026-000123 du 10/11 n'est plus à jour (recalcul du 15/11) »).
- **Client space:** « Décomptes » lists the issued décomptes of the client's files.
- **Future consumers:**
  - the M4 R124-4 letter (CPCE-04 checks the snapshot is from the send date and its pack is VALIDATED);
  - the M5 portal;
  - the bailiff package.
- **No LLM.** Every number is formatted from integers; no free text sits in amounts.

Layout (worked example 3 under D1/D2, TO VALIDATE):

```
DÉCOMPTE N° D-2026-000042 — à payer le 31/10/2026
[Servicer], agissant pour le compte de [Client] · Dossier M-0042 · Débiteur : [raison sociale]
Facture F-2026-118 du 02/03/2026, échéance 01/04/2026                         Montant TTC 12 000,00 €
  Pénalités de retard (art. L441-10 II C. com.)
    02/04/2026 → 15/06/2026   74 j   12 000,00 € × 7,86 % × 74/365     191,22 €   3 × taux légal (arrêté du 15/12/2025)
    15/06/2026 → 01/07/2026   16 j    7 231,22 € × 7,86 % × 16/365      24,92 €
    01/07/2026 → 31/10/2026  122 j    7 231,22 € × 8,25 % × 122/365    199,40 €   3 × taux légal (arrêté du 26/06/2026)
  Indemnité forfaitaire pour frais de recouvrement (art. L441-10 II, D441-5)          40,00 €
  Paiement du 15/06/2026 : 5 000,00 € — imputé : pénalités 191,22 €, indemnité 40,00 €, principal 4 768,78 €
                                                    (art. 1343-1 C. civ. : d'abord sur les intérêts)
RESTE DÛ      Principal 7 231,22 € · Intérêts 224,32 € · Autres accessoires 0,00 €      TOTAL 7 455,54 €
Méthode : intérêts jour par jour à partir du lendemain de l'échéance, jour du paiement non compté,
année civile ; chaque ligne arrondie au centime.  Barème b2b_invoice 2019-04-26 r1 (à valider) · engine-1
```

### 11.3 Receipts' remaining balance (M2b founder #14; D14)

- Template `quittance-fr-3` adds « Reste dû au JJ/MM/AAAA après ce paiement : X € (selon les éléments connus à cette date) ».
- It is shown only when the file's pack is VALIDATED and its status is `ok` at the allocation date; otherwise the line is omitted.
- It is computed in SQL from the ledger at D after the crystallisation and the allocation, as known at the version's `known_at`.
- A new receipt version comes only when the payment's lines change (existing M2b-5 versioning). A later balance change alone never re-issues a receipt.
- Consumer unclassified amounts are excluded.

---

## 12. Worked examples under the conventions (TO VALIDATE; exact integers, half-up per line)

| Example | As written in CALCULATION_RULES §6 | Under D1 (day after; payment day not charged) | What changes |
|---|---|---|---|
| 1 Consumer loan | late interest 90 days 62,83 € → **4 658,19 €** | 89 days 62,13 € → **4 657,49 €** | first day 2025-12-11; D312-16 base at the acceleration date = 3 602,60 € (288,21 €) unchanged |
| 2 Professional loan | 365 + 31 days → **22 147,37 €** | first day 2025-10-01, year 1 = 365 days (1 408,35 €), capitalisation on 2026-10-01, then 30 days: 115,76 € + 8,74 € → **22 143,23 €** | anniversary moves with the first day (OQ-63) |
| 3 B2B invoice | 75 / 16 / 122 days → **7 458,20 €** | 74 / 16 / 122 days: 191,22 / 24,92 / 199,40 → **7 455,54 €** | allocation 191,22 / 40,00 / 4 768,78 |
| 4 B2C invoice | 103 + 91 days → **486,84 €** | 102 + 91 days: 3,51 + 3,29 → **486,80 €** | first day 2026-03-21 |

- Year basis: none of the examples crosses a leap year, so D2 changes nothing.
- Rounding: per line gives 24,92 + 199,40 = 224,32 €, against 224,40 € (as written) or 224,32 € (D1) if the two later segments were rounded once (both conventions computed; per-line is the chosen default).
- The golden harness carries both conventions as parameterised cases until the founder's real décomptes decide (D1).

---

## 13. Ops and client UI (French, phone-first; Playwright screenshots mobile + desktop per page)

- **File page, « Solde et calcul »:**
  - « Solde dû au JJ/MM/AAAA » with Principal / Intérêts et pénalités / Indemnités / Autres sommes;
  - « dont comptabilisé au … » and « couru depuis »;
  - status chip: « Calcul à jour », « Recalcul en cours… », « Recalcul à valider », « Provisoire : taux du 1ᵉʳ semestre 2027 non publié », « Bloqué : taux BCE non chargé », « Hors calcul : jugement du 12/03/2026 », « Intérêts arrêtés le 12/03/2026 (procédure collective) », « Déchéance du terme non justifiée »;
  - links « Voir le calcul », « Établir un décompte », « Décomptes établis ».
- **« Faits de calcul »:** events with their legal date, source and evidence.
  - « Ajouter un fait »: kind, date with a per-kind label (« date de réception de la mise en demeure », « date du jugement d'ouverture »), document, note.
  - The effect is stated before sending (« Les intérêts légaux courront à partir du 21/03/2026 ; recalcul automatique »).
  - « Corriger » voids the fact with a reason.
- **« Conditions »:**
  - contract terms with their source (tape, ops, CGV);
  - creditor terms (« Pénalités : taux des CGV 10,00 % (CGV du 01/09/2026) — plancher légal ce semestre 8,25 % : conforme »; below the floor: « inférieur au plancher : appliqué tel quel, à vérifier »);
  - the claim policy (« Accessoires réclamés selon le mandat, clause 4.2 »).
- **Mandate terms** (M2c-2 page, new section « Accessoires réclamés »): an explicit choice per component, with **no pre-ticked box**; « Calcul avant la date de reprise »; « Taux des pénalités (CGV) » with document.
- **« Recalcul à valider »** (`/backoffice/calcul/a-valider`): cards per §10.3, plus the bulk card for `restate_all`.
- **« Taux »** (read-only): index × semester, value, arrêté link; banner from 1 June / 1 December when the next semester is missing.
- **« Contrôles »:** the §9.6 checks.
- **Client space « Décomptes »:** issued PDFs of its files. The feed row « imputation recalculée » is shown.
- **Screenshots:** `m3-file-calc`, `m3-file-events`, `m3-file-terms`, `m3-mandate-accessories`, `m3-recompute-review`, `m3-rates`, `m3-statement`, `m3-client-statements`, `m3-receipt-balance`, plus M2b pages re-taken where they change.

---

## 14. Tests

### 14.1 Golden harness (M3-12)

Location: `worker/tests/golden/<claim_type>/<case>.yaml`. Each case holds:
- `conventions:` (offset, year, rounding);
- inputs: items, terms, creditor terms, claim policy, events, payments with designations, rate overrides (synthetic cases only), pack version;
- `as_of` dates;
- expected lines (item, component, from, to, days, base, rate, amount, ref), allocations and totals, as text euros (more than 2 decimals refused);
- `status: TO_VALIDATE | VALIDATED {by, on, source}`.

The runner:
- runs the pure engine on every case and a DB subset end to end;
- prints a line diff (« F-101 late_penalty 2026-06-15→07-01 : attendu 24,92, obtenu 24,93 »);
- prints the count of TO_VALIDATE cases;
- refuses a change to a VALIDATED case's expected values unless the same commit sets it back to TO_VALIDATE.

Founder cases come as PDFs. They are anonymised before conversion, and the originals never enter the repo (« Never commit real personal data »). Claude transcribes; only the founder validates.

First cases (TO_VALIDATE):
- examples 1–4 under both conventions;
- semester crossing;
- payment mid-segment;
- B2B `no_clause` (blocked until the ECB values load), `unknown` (lowest of) and a CGV below the floor;
- opening before or after the due date (€40 or not);
- €40 held under a dispute;
- B2C without a notice → 0, with the reason;
- notice without proof of receipt → 0, flagged;
- L722-14 stop;
- consumer acceleration without a notice → nothing, and with a notice → late interest and D312-16;
- acceleration before the cut-off → no indemnity;
- capitalisation anniversary;
- L622-28 loan ≥ 1 year (contract rate kept, margin stopped);
- a 2028 leap-year segment;
- L313-3 primitive with a JEX reduction;
- a missing rate → provisional.

### 14.2 Hypothesis (engine)

1. Zero rate or zero base gives zero.
2. Without payments, cumulative interest is non-decreasing in `through`, and rises with rate and base.
3. Any set of posting dates gives the same final totals (exact).
4. An artificial split of an economic segment changes the total by ≤ 1 minor unit per split.
5. A no-op pack version or an equal rate row gives an empty plan.
6. Unchanged inputs give an empty plan.
7. Recording then voiding an event gives the original ledger with an empty plan.
8. Permuted input lists give the same output and the same hash.
9. Posting through t1 then t2 equals posting through t2.
10. Incremental (`dirty_from`) equals from scratch in balances per (item, component, date) and in live allocation lines. Literally identical entries are not expected (legal critique T1).
11. Exact rounding equals the `Fraction` reference.
12. Base rules: no interest-family base except capitalised; never capitalised for consumer regimes, after an opening or for B2B.
13. €40 at most once per item; never outside B2B, never with an opening on or before the due date, never while a dispute hold is active.
14. No accrual or charge inside a stop interval; the suspended rules are zero during a 1343-5 delay.
15. L313-3 applies only to legal-rate streams.
16. D312-16 and D312-17 never add up.
17. Forclusion ignores acknowledgements.
18. Consumer packs never post non-whitelisted components.
19. Schedule: Σ capital = principal, the CRD is never negative, the last instalment adjusts.
20. M2b allocation properties with pack-driven policies: interest first, Σ lines + remainder = amount, no line above a balance, order-independent, including payments split across files.
21. A restatement never pays principal while interest is available.
22. The engine's plans never trigger LG006 or LG007.
23. CPC 641 month arithmetic agrees with a reference (month ends, 29 February).
24. Date generators cover 29 February, semester edges, month-end clamping, and an event and a payment on the same day.

### 14.3 Against Postgres

The M2b `RuleBasedStateMachine` is extended with these rules:
- record and void events;
- terms versions;
- a rate supersede;
- pack activation;
- monthly close;
- back-dated and late payments;
- returns, refunds, nettings and direct payments;
- restatement approve and revert;
- A→B→A sequences.

After each step:
- I-E1…I-E3;
- I2–I11 and client money closed;
- the snapshot total = ledger + pending;
- nothing posted to cost components;
- engine entries carry metadata.

### 14.4 pgTAP (next free numbers after M2c)

| File | What it tests |
|---|---|
| `rates` | append-only; supersede-only with a reason; overlap exclusion; read access |
| `rule_packs` | rows immutable; activation one-time and only with a dry run; hash unique; `rule_pack_version_id` outside the account's pack refused |
| `calc_facts` | RLS and tenant isolation per role for events, terms, creditor terms, claim policy, titles, schedule; change log; commands at aal2 (idempotent, compare and set); a hold for surendettement or collective proceeding writes its event |
| `engine_ledger` | `ledger_post` refuses engine types; metadata required; whitelist per regime; capitalisation refused on consumer regimes and after an opening; €40 refused off B2B; cost component without a title refused; I6 for reversals of engine entries; a restatement set with allocation reversals passes; the same set split into two calls fails (documents the order) |
| `statements` | snapshot append-only; client read of its own files only; collectors read their portfolios; summary written by the service role only |

### 14.5 Integration and end to end

- **Integration:**
  - example 3 end to end: statement import → match → allocation of 5 000,00 € on 15/06 → receipt v1 (no balance while TO_VALIDATE);
  - a back-dated CGV change → restatement, 4670 unchanged, receipt v2, feed row;
  - a décompte at 31/10 = ledger + pending;
  - a monthly close run twice → one entry set;
  - a missing 2027-H1 rate → provisional, then loaded → restated automatically;
  - a rate correction that changes a cash total → review → approve;
  - a return after a restatement;
  - `restate_all` on the seeded data.
- **E2E (Playwright, desktop + mobile):** the file card; add an event; the terms page; issue and download a décompte; the review queue; the rates page; the client « Décomptes ».
- **Static:**
  - no float, clock or LLM import in `engine/`;
  - no raw ledger DML (existing test);
  - every pack and rate YAML has its migration.

---

## 15. Scale (targets; measured per slice in `docs/benchmarks/engine.md`)

| Run | Target | Estimate (from M2 measurements) |
|---|---|---|
| Replay per file | p99 ≤ 20 ms for a B2B file with 200 invoices and 50 payments | integer maths ~10–100 segments per file; benchmark p99 files, not averages (ops critique M15; use a sorted running minimum in `BalanceProfile` if needed) |
| Nightly summary, 50k files (no lock) | ≤ 5 min, one process | set-based load 10–20 s; engine 1–3 ms per file |
| Monthly close, 50k files | ≤ 2 min | ~50k accrual entries; posting measured at ~0.9 ms per entry in the M2b allocation run (50k in 50.8 s, 2026-11-09) |
| 50k allocations with crystallisation | ≤ 2 × today (≈ 100 s) | one extra accrual entry per (payment, file) |
| Rate correction two years back, 50k files | ≤ 15 min overnight, chunks of 2,000 | only the close entries inside the corrected semester differ (≈ 6 per file × 2), plus restatements where splits change; measured (ops critique M14) |
| Décompte issue, one file | ≤ 3 s to the PDF | receipts render ~12 ms each |
| 1M files | close ≤ 40 min per servicer in chunks; RSS < 4 GB (`make bench-engine`) | — |

- **CI `scale` job:** adds the 50k close, 50k allocations with crystallisation, a 50k rate fan-out and 1k décomptes. If the job passes 15 min, CI runs 20k and the 50k runs locally.
- **Lookups:** every new one is keyed and statistics-proof (ARCHITECTURE §4); read counts are asserted with `pg_stat_xact_user_tables`.
- **Ledger growth:** about 12 close entries per file per year, plus one per payment date, plus restatements.

---

## 16. Risks and dated obligations

- **R1 Data, not law, is the bottleneck.** SMB exports rarely carry CGV rates, and EU tapes rarely carry notices. Mitigation: fail closed, with blocked and hors-calcul reasons visible per file and counted in « Contrôles ».
- **R2 Conventions vs real décomptes** (first day, year basis, rounding). Mitigation: conventions are pack data; golden cases carry them; the founder's cases decide (D1, D2).
- **R3 Double counting** with seller-declared amounts (3.10, 3.11, penalty invoices). Mitigation: `seller_included`, no D312-16 for acceleration before the cut-off, pre-cut-off B2B only by policy; the DQ report shows the pre-cut-off penalty total.
- **R4 Restatement noise and M2c coupling.** Mitigation: net cover per restatement (a requirement on M2c-7), grouped feed rows, review only on cash change, receipts re-issued only when lines change.
- **R5 Lock contention.** Mitigation: compute outside the lock, fact stamps, 2,000-file chunks, the close at night; measured.
- **R6 Pack or engine mistakes look like legal statements.**
  - Packs are reviewable YAML with references, validators and a dry run before activation, and debtor-facing outputs are gated on VALIDATED.
  - A result-changing `engine-2` is shadow-run against `engine-1` on all files, then activated like a pack revision.
- **R7 Touching merged M2b code** (`post_allocations`, `ledger_post_set`, `place_account_hold`, `receipt_payload`, the notification guard). Mitigation: redefinitions only; the M2b and M2c suites and 50k runs in M3a-3 and M3c-2.
- **R8 Hors calcul files get no R124-4 letter in M4** (block 3° comes only from a décompte). This is a product impact the founder should know.
- **R9 ECB values unverified:** the B2B `no_clause` and `unknown` paths are blocked until D5.
- **R10 1342-10 « plus d'intérêt d'acquitter »** (OQ-21) becomes material once debts bear different interest. Counsel should answer before go-live; the M2b order is kept meanwhile.
- **R11 Hold migration.** Existing surendettement and collective-proceeding holds have no legal date. The migration marks those files `blocked: date légale à saisir` until ops record the event.
- **Dated:**
  - **2026-11-20:** CCD2 in force. The ccd2 pack is a copy, TO VALIDATE; L341-8 already moved (read). Re-read article by article (OQ-10).
  - **Mid or late December 2026:** the 2027-H1 arrêté; alert from 1 December; provisional mode from 1 January.
  - **2027-01-01:** L441-10 in a new version (II unchanged, read) and L441-9 in a new version (not read: re-read before relying on it).
  - **2028:** the first leap year under D2; a golden case covers it.

---

## 17. PR slicing (each ≤ ~2,000 lines; plan → tests → code → run; screenshots with every UI change)

| PR | Content (ROADMAP ids) | Acceptance criteria |
|---|---|---|
| **M3a-1** Rates (M3-01) | `rate_index`, `rate_value`, YAML + `make rates` migration, every legal-rate semester 2015-H1 → 2026-H2 read on its arrêté (URL + quote), ECB per D5, `RateBook` + SQL twin, missing-rate alert, read-only « Taux » page; ADR-0015 started | lookup = arrêté value at any covered date (table test against the YAML) and parity on 10k dates; outside the span `Missing`; append-only and supersede-only (pgTAP); ECB loaded or 🔒 with the host named in CLOUD_ENV; screenshots |
| **M3a-2** Pack format (M3-02, M3-05 validation) | schema `rule-pack/1`, float-refusing loader, validators §7.6 with failing fixtures, `make rule-packs` migration, `private.rule_pack*`, `rule_pack_validation`, `account.rule_pack_code` + back-fill, activation command + dry-run stub | each invalid fixture fails CI with its named error; a committed version cannot change (CI); DB rows immutable; activation refused without a dry run |
| **M3a-3** Facts and ledger vocabulary (M3-04 data, M3-05 ledger) | `account_event`, `contract_terms`, `creditor_terms`, `claim_policy`, `enforceable_title`, `schedule_line`, `party.public_body`, `engine_state`, commands with evidence, hold ↔ event, legacy-hold migration; components, `component_regime`, entry types `accrual`/`charge`/`capitalisation`, `LG009` guards, `ledger_post` refusal, `ledger_post_set` with reversal rows, shared `check_allocation_lines()`; boarding targets; mandate « Accessoires réclamés » section | pgTAP `calc_facts`, `engine_ledger`; §3.3 guards refuse what they must; change log on fact tables; mapping eval ≥ threshold; M2b suites and the 50k allocation green with the extracted check |
| **M3a-4** Engine core + golden harness (M3-03, M3-04 engine, M3-06, M3-12) | `numbers`, `daycount`, `rates`, `timeline`, segments and merging, rounding, starts/stops/suspend/hors calcul, charges, capitalisation, limitation, L313-3 primitive, replay and plan (pure, no writes), harness with `conventions:` and SIGNOFF | examples 1–4 to the cent under both conventions; §14.2 properties 1–19, 23–24 green; static tests; readable diff; a new case needs no code |
| **M3b-1** B2B pack (M3-08) + live calculation | `b2b_invoice` pack; `engine.summary` (nightly + on change, no lock); file-page cards « Solde et calcul », « Faits de calcul », « Conditions »; statuses | example 3 per D1 ✓; `no_clause` blocked until ECB; €40 rules; an event changes the page within seconds (E2E); 50k nightly ≤ 5 min; screenshots |
| **M3b-2** B2C pack (M3-09) | `b2c_invoice` pack | example 4; no notice or no receipt proof → 0 with the reason; no €40; L722-14 stop |
| **M3b-3** Schedules + professional loan (M3-07, M3-10) | schedule import and rebuild, instalment items, `not_yet_due_capital` held, `professional_loan` pack | rebuilt schedule = example 2 extract to the cent; example 2; capitalisation only with a clause at the anniversary; L622-28 (contract rate kept, margin and capitalisation stopped; liquidation hors calcul) |
| **M3b-4** Consumer instalment loan (M3-11) | `consumer_instalment_loan` pre_ccd2 + ccd2 packs | example 1; regime by contract date (2026-11-19 vs 2026-11-20); no acceleration notice → nothing added; no indemnity when accelerated before the cut-off; whitelist guard; capitalisation property; forclusion date |
| **M3c-1** Posting (M3-13) | posting dates, `engine_post_begin`/`engine_post_plan`, stored plans and keys, `engine.close` gated on statements, dirty triggers, `engine.recompute` (accrual corrections), drift check and « Contrôles » rows | every seeded account: I-E1 at every posting date; close idempotent; re-run with no change → empty plan; A→B→A posts correctly; 50k close ≤ 2 min; a planted drift is found |
| **M3c-2** Allocation from the pack + restatements (M3-15, M2b #16) | replay inside `payments.allocate` (crystallise, then allocate per date), `alloc-2`, inline restatement of late payments, `restatement` + review page, receipts `quittance-fr-3` behind the gate, feed `recalculation`, `restate_all`, M2c-7 net-cover integration (fail-closed until merged) | M2b properties pass with pack-driven policies; a back-dated event gives the same balances and live lines as from scratch; a cash-total change waits for approval; a remitted line before M2c-7 → review; 50k allocations ≤ 2 × today; property machine green; screenshots |
| **M3c-3** Décompte (M3-14) | builder, `statement_snapshot`, numbering, French HTML and PDF, staleness, client « Décomptes », debtor/staff variants; docs | every line traces to `accrual_segment` rows or pending lines; total = ledger + pending; PDF golden hash; E2E + screenshots; roadmap demo (one file per claim type at three dates, recomputed from scratch with the same hash) |

Docs land with the slices:
- **ADR-0015** « Calculation engine and accrual posting »: amends ADR-0005 (path, activation, `applies_by`) and ARCHITECTURE §7 (posting dates, documents never post, `statement_snapshot`).
- **COMPLIANCE:**
  - new INT-11 (L722-14), INT-12 (1343-5 al. 4);
  - INT-08 rewritten (the bar reads « interdit le paiement à son échéance »; dispute hold);
  - INT-04 test aligned with OQ-63;
  - INT-02/03/05/06/09/10, CPCE-09, HOLD-01/02 enforcement points;
  - OQ-51…68 and the updated OQs.
- **CALCULATION_RULES:** §2 conventions, §4 rates (2,76 % caveat cleared), §5 schema, §6 examples under D1.
- **DOMAIN:** components, entry types, tables, `account.rule_pack_code`, hold scopes.
- **ROADMAP:** path fix and the M3-14 AC (« ledger + pending »).
- **PROGRESS.**

**Order and dependencies.**
- M3a-1 → M3a-4 do no ledger writes.
- M3b-1 brings the first segment's value first.
- M3c-2 needs M2c-7 for automatic restatements of remitted lines; it fails closed until then.

---

## 18. Critique findings and where they are fixed

| Finding (critique) | Fix (§) |
|---|---|
| 3 × legal is not conservative; 2024-H1 = 15,21 % (legal L1, engine L1) | lowest-of for `unknown`; the clause rate as written below the floor (§2.2 #5, §7.2) |
| Day rule contradicts example 3 (legal L2, C1; engine L10) | one rule, D1; both conventions in golden cases (§8.3, §12) |
| L313-3 scope and dates overstated (legal L3, engine L2) | primitive on legal-rate streams only; latest candidate date; JEX reduction; suspended in a 1343-5 delay; no pack uses it (§8.5) |
| Judgment overlay adds streams; 1231-7 al. 2; art. 700 vs L312-38 (legal L4, L9) | judgments hors calcul; later pack (§2.2 #8, OQ-60) |
| Weak consumer acceleration evidence; tape date (legal L5, engine L5) | notice with an expired delay required; tape alone adds nothing (§7.5, D8) |
| Guarantors ignored (legal L6) | principal debtor only; guarantor documents refused (§11.1, OQ-65) |
| 1342-10 material once interest exists (legal L7) | R10, OQ-21 before go-live |
| Recovery-fee guard over-permits (legal L8) | no `recovery_fee` component; cost components need a title, an enforceable date and the act (§5.3) |
| Stop classification per stream; L722-14 covers schedule interest; L641-3 (legal L10; engine L3, L11; ops A2) | §3.2, §7; liquidation all stops; measures hors calcul; no auto-resume |
| Capitalisation readings (legal L11, L12; ops M10; engine L11) | anniversary, unpaid only, includes instalment interest; separate charge bases; INT-04 aligned (§8.5, OQ-63) |
| €40 conditions (legal L13; ops minor) | per item, dispute hold, seller-included skip, EUR only, invoices with principal > 0 (§7.2) |
| Interest stop date in M2b paths; value date (legal L14, engine L9) | allocation date (booking); returns raise the base from the return date; OQ-62, OQ-25 |
| Variable rates (legal L15, engine C12) | blocked or hors calcul (§1) |
| L341-8 moved; pre-2015 single rate; negative balancing line (legal L16) | §3.1; `rate_missing` before 2015; `cap_items` already caps by item net |
| Crystallise and allocate must alternate per date (legal C2) | the replay interleaves (§8.6) |
| Rounding breakpoints (legal C3, engine C2, ops M4) | economic segments merged (§8.2) |
| ACT/ACT and 30E/360 formulas (legal C4) | §8.3 |
| Late-matched payments leave the ledger wrong (legal C5) | inline restatement in the allocation transaction (§10.6) |
| Order inside the transaction; `ledger_post_set` immediate checks (legal G1) | one set call with reversal rows; ordered rows; pgTAP documents the split-call failure (§9.4) |
| `post_allocations` gates cannot re-post; LG006 bypass (legal G2, engine G1) | shared `check_allocation_lines()`; gates as of D; holds → review (§9.4, §10.2) |
| Reversed allocations cannot be re-split (legal G3, engine C7) | closed episodes are facts; conflict → hors calcul for ops (§10.5) |
| LG008 is not a guard here; R124-6 date; commission (legal G4, engine G9, ops M7, M8) | explicit remitted check; M2c-7 net cover; E kept; telescoping commission (§10.7) |
| Idempotency A→B→A; capitalisation key without hash; retries (legal G5, engine G5, ops B1) | run-scoped keys + stored plans (§9.5) |
| Snapshot crystallisation storm; on-demand points not reproducible (legal G6, engine C1, ops M6) | documents never post; posting dates are facts (§9.1) |
| Missing rate at an allocation date (legal G7) | provisional; allocate on known interest; restate when loaded (§6) |
| Pack status inside the hash; retroactive versions (legal G8, ops M3) | `rule_pack_validation`; activation after a dry run; `compute_sha256` (§7.7) |
| Claim policy re-allocates the past (legal G9) | prospective except a waiver from origin (§5.2) |
| Ownership splits (legal G10, engine G6) | ownership boundaries are posting dates (§9.1) |
| DOMAIN conflicts (legal G11) | `account.rule_pack_code`; `euribor_3m` dropped; hold scopes ignored (§4, §17 docs) |
| Lock hold time; set-based reversals; trigger cost (legal S2–S4, engine S1–S2) | §9.4, §5.5, §15 |
| Incremental vs from scratch wording; missing cases; OQ numbers (legal T1–T3) | §14.2 #10; §14.1; §19 written in the PR |
| Law time vs contract rules (engine L7) | `applies_by` + transitional reference (§7.1) |
| L313-2 creditor category (engine L8) | owner capacity per day (§3.1) |
| Forclusion vs prescription (engine L4, ops A3) | separate kinds; 2241 only; R312-35 restarts (§7.5) |
| Interest forfeiture (engine L6) | hors calcul (§1) |
| Pre-acceleration prepayment of capital not yet due; two loan shapes (engine C3, C4) | instalment items; capital not yet due held (§2.2 #17) |
| Raising A couples files; stored policy (engine C5, C6) | never automatic; policy as stored (§8.6, §10.4) |
| Direct payments as facts (engine C8) | restated like allocations; netting OQ-68 (§10.5) |
| Pre-cut-off base (engine C9; ops M12) | cut-off principal, by policy, seller-included skip (§8.5) |
| Hash rates as integers; missing semester only after the last known day (engine C10–C13) | §8.1, §6 |
| Temp tables (engine G2) | `engine_post_begin()` (§9.4) |
| Holds not bitemporal (engine G3; ops M5) | legal effects only from append-only events; legacy-hold migration (§2.2 #11, R11) |
| Reverse only what differs (engine G4) | §9.3 |
| `contract_terms` time axis (engine G7, ops M1) | append-only, not time-sliced; CGV by invoice date (§5.2) |
| Close before statements (ops B2) | statements gate, 5th business day at the latest (§9.2) |
| Review atomicity and R124-6 while waiting (ops B4) | atomic; new payments allocate meanwhile; ageing alert (§10.2) |
| Go-live gate vs debtor documents (ops B5, M9) | VALIDATED packs + `ok` status (§11.3, D14, D15) |
| Floor refused at entry fabricates a term (ops M2) | as written, flagged (§2.2 #5) |
| Boarded events need evidence at 50k (ops M11) | tape + row ref; insufficient alone for charges and late interest (§5.2) |
| Real data in golden cases (ops M13) | anonymised; Claude never validates (§14.1) |
| Pre-ticked accessories (ops A5) | explicit choice per component (§13) |
| L441-10 I missing due date (ops A4) | blocked (§3.1) |
| Name clash, timezone, zero lines, per-item status, I-E1 wording (ops minor) | §4, §9.2, §9.3, §8.5, §9.6 |

---

## 19. Open questions for counsel (new rows for COMPLIANCE §9, after OQ-50; each with the conservative default the packs apply)

- **OQ-51 Day counting:**
  - Does « exigibles le jour suivant la date de règlement » (L441-10 II) make the first day of penalties the day after the due date?
  - Is the payment day charged?
  - Does « à compter de la mise en demeure » (1231-6) count the day of receipt?
  - From which day does L312-39 late interest run after acceleration?

  Default: the first day is the day after the event; the payment day is not charged.
- **OQ-52 Year basis:** for legal interest, B2B penalties and L312-39 interest, is the year 365 days or the calendar year (366 in a leap year)? Default: the calendar year.
- **OQ-53 Rounding:** is half-up per décompte line (per segment) acceptable to courts and bailiffs, or is there a reference practice? Default: per line.
- **OQ-54 L441-10 rate:**
  - Is « trois fois le taux d'intérêt légal » the rate of each semester or the rate at the due date?
  - Is it the creditor-category rate?
  - For a CGV rate below that floor: does the floor, the statutory ECB + 10, or the clause's own rate apply?
  - What applies when the CGV clause is unknown?
  - Is the base the TTC amount?

  Default: per semester, « autres cas »; below the floor, the clause as written, flagged; unknown, the lower of 3 × legal and ECB + 10; base TTC.
- **OQ-55 B2B penalties:** are « pénalités de retard » « intérêts » for 1343-1 (paid first) and for 1343-2 (capitalisable by a CGV clause)? Default: paid first; never capitalised.
- **OQ-56 €40 (refines OQ-6):**
  - Is it due per invoice, or per instalment of an invoice schedule (C-370/21 pts 25–26)?
  - Does an open dispute mean the debtor « n'est pas responsable »?
  - Does « interdit le paiement à son échéance » mean an opening judgment on or before the due date?
  - Is it skipped when the seller already invoiced it?
  - Is the €40 claimable in our amicable letter without a title (OQ-2)?
  - CJUE C-209/25 (1 October 2026), not read, is to check.

  Default: per late item; held during a dispute; barred by an opening on or before the due date; skipped when seller-included.
- **OQ-57 L722-14:**
  - Are we bound from the admissibility decision before the commission's état d'endettement lists the claim?
  - Does « pénalités de retard » cover D312-16/17 and the €40?
  - Does it stop the contractual interest of instalments falling due after admissibility?
  - What runs after the measures (L724-1, L732-1, L733-1, L733-4, L733-7)?

  Default: everything stops from the decision date; no new charge; hors calcul after measures.
- **OQ-58 L622-28, L641-3, L643-1:**
  - Does the loan ≥ 1 year exception keep the contractual late margin (« intérêts de retard et majorations »)?
  - How is « durée » measured?
  - In liquidation (first sentence only; L643-1 exigibility), does interest continue on such loans?
  - Does anything resume at closure?

  Default: in sauvegarde and redressement only the contract rate continues; the margin and capitalisation stop; liquidation stops everything; nothing resumes.
- **OQ-59 1343-5 al. 4:** which streams are « majorations d'intérêts ou les pénalités » suspended during a judge's delay: L441-10 penalties, late margins, L312-39 loan-rate interest, legal interest at the base rate? Default: suspend everything except legal interest at the base rate; a reduced rate or capital first → hors calcul.
- **OQ-60 Judgments (for the later pack):**
  - Does L313-3's +5 points apply only to legal-rate heads?
  - When is a decision « devenue exécutoire » (notification, CPC 503; provisional enforcement)?
  - Does the two-month period follow CPC 641/642?
  - Does the step start on the expiry day or the next day?
  - How does 1231-7 al. 2 apply on appeal?
  - May art. 700 sums and dépens be claimed on consumer credit under L312-38?

  Default: judgments hors calcul in M3; the primitive uses legal-rate heads only and the latest candidate date.
- **OQ-61 Consumer acceleration (refines OQ-5):**
  - Is a seller's tape date of « déchéance du terme » enough, or must the notice stating the regularisation delay be on file (Cass. 1re civ. 3 juin 2015; 29 mai 2024)?
  - What delay is « raisonnable »?
  - Does the acceleration notice count as the mise en demeure that 1231-5 al. 5 requires for the D312-16 indemnity?
  - Is D312-16's « date de la défaillance » the acceleration date or the first incident?

  Default: notice required; base at the acceleration date, capital after the last due instalment.
- **OQ-62 Interest base and payment date:**
  - Do L312-39's « sommes restant dues » include the échus interest?
  - Is the date of « règlement effectif » (L312-39), or of funds « mis … à la disposition du bénéficiaire » (L441-9), the booking date or the value date on our dedicated account (we receive « pour son compte »)?

  Default: capital only; the booking date.
- **OQ-63 Capitalisation (1343-2):**
  - Does « intérêts échus, dus au moins pour une année entière » mean interest accrued over a full year, capitalised at each anniversary, or interest that has been due for a full year?
  - Is instalment interest included?
  - Where does capitalised interest rank in allocation?

  Default: the anniversary of the stream's first day; unpaid interest of the elapsed year plus interest due ≥ 1 year; ranked with interest. The INT-04 test is aligned with the answer.
- **OQ-64 Accessories and the mandate:**
  - Must the mandate name each accessory for us to claim it (R124-3 1°)?
  - May we claim, and show in the R124-4 letter, penalties or interest for periods before our mandate, computed on the seller's cut-off outstanding?

  Default: only accessories the mandate lists; pre-cut-off B2B only by explicit choice, on the cut-off principal.
- **OQ-65 Guarantors and co-obligors:**
  - Must amounts be stated per obligor (2302 forfeiture and imputation « prioritairement sur le principal »; L622-28 al. 1 for natural-person co-obligors)?
  - May a guarantor receive the debtor's décompte?

  Default: principal debtor only; guarantor-facing documents refused.
- **OQ-66 Restatements:** when a recalculation re-splits an allocation already reported to the client (R124-5) and receipted (R124-6), must the client be told and a new receipt delivered to the debtor? Default: a grouped feed row and a new receipt version; no delivery before M4/M5.
- **OQ-67 Limitation:**
  - Is a partial payment an acknowledgement under 2240?
  - Does anything other than a court claim (2241) interrupt the R312-35 forclusion, given 2220?
  - From when does the 5-year B2B period run (2224 « connu ou aurait dû connaître »; L110-4)?

  Default: indicative dates from the due date; alerts ignore interruptions; forclusion only by a court claim.
- **OQ-68 Compensation with interest:** with interest now posted, do the imputation rules « transposables » (1347-4) put a compensated credit note on the debt's penalties first rather than on principal? Default: principal only (M2b), which lowers later interest.

**Existing questions updated:**
- **OQ-3:** the exigibility-as-notice clause (1344) is not used for consumer contracts until answered; our R124-4 letter does not count as a notice.
- **OQ-4:** no late interest before acceleration; D312-17 disabled.
- **OQ-5:** see OQ-61.
- **OQ-6:** see OQ-56.
- **OQ-7:** €40 before principal, overridable.
- **OQ-10:** the ccd2 pack is a copy; L341-8 changed on 2026-11-20.
- **OQ-18:** unclassified amounts are excluded from debtor décomptes.
- **OQ-21:** now material; before go-live.
- **OQ-24:** a restatement on a held file goes to review.
- **OQ-25:** after a return, the payment counts until the return date (no interest for that period).
- **OQ-27:** non-EUR blocked.

---

## 20. Founder decisions (pending; answer « 1 ok, 2 b … »)

1. **Days.** Do penalties start the day after the due date (or after the notice), with the payment day free? Default: yes (example 3 = 7 455,54 € instead of 7 458,20 €). Why: L441-10 says « le jour suivant », and we never charge a day that is not clearly late.
2. **Year and cents.** Do we count over the calendar year (366 days in a leap year) and round each line to the cent? Default: yes. Why: never more than a 365-day year, and the debtor can check every line.
3. **Accessories.** Do we claim only the accessories the mandate lists one by one, with no pre-ticked box? Default: yes; without a choice, principal and the seller's figures only. Why: R124-3 1°, and claiming less is always lawful.
4. **B2B rate.** Does the client declare its CGV rate, « pas de clause » (ECB + 10) or « inconnu » (the lower of 3 × legal and ECB + 10)? Default: yes; a CGV rate below 3 × legal is applied as written and flagged. Why: 3 × legal can be the higher rate (15,21 % in early 2024).
5. **Rates.** Do legal rates come from each arrêté by a reviewed change, and ECB rates from EUR-Lex (or you allow `data-api.ecb.europa.eu`)? Default: yes; a missing rate makes the file « provisoire ». Why: no rate is ever guessed or typed.
6. **Before our cut-off.** B2B penalties and €40 from the legal start, but only if the mandate says so and the seller did not already invoice them? Default: yes; B2C only from a proven mise en demeure; bank loans from our cut-off. Why: B2B penalties need no reminder; never charge twice.
7. **€40.** One per invoice paid late, ranked before principal, held while the invoice is disputed? Default: yes. Why: CJUE C-370/21 « pour chaque paiement non effectué à l'échéance ».
8. **Consumer loans.** Late interest and the 8 % indemnity only once the déchéance letter with a delay is on file? Default: yes; 8 % on the lower base, never if the seller accelerated before our cut-off. Why: the Cour de cassation requires that letter; a tape date is the seller's word.
9. **Booking.** Is interest booked at each payment and at each month end, once the month's bank statements are in, and never by a document? Default: yes. Why: the books are right every month and a late statement never forces a correction.
10. **Late facts.** Do we correct by reversal at the original dates, automatically only if no payment's total changes? Default: yes; otherwise ops approve in « Recalcul à valider ». Why: money already shown or paid to a client never moves without a person.
11. **Hors calcul.** Judgments, surendettement measures, interest forfeiture, liquidation of a pro borrower, variable rates and public buyers are frozen? Default: yes; such files get no décompte, so no first letter yet. Why: each needs its own rules, and we never type an amount.
12. **Surendettement.** From the admissibility date: no interest, no penalties, no new indemnity? Default: yes; ops give that date when placing the hold. Why: L722-14, which was missing from our compliance list.
13. **Collective proceeding.** Does interest stop at the opening judgment? Default: yes; for loans ≥ 1 year in sauvegarde or redressement only the contract rate continues. Why: L622-28; the late margin is for counsel.
14. **Receipts.** Show « reste dû au [date] » only when the barème is validated and the file fully computed? Default: yes, frozen as known that day. Why: a wrong balance on a receipt is worse than none.
15. **Go-live.** Real payments for a claim type only when 2 of your anonymised real décomptes pass and M2c-7 is merged? Default: yes; please send 2–3 per claim type. Why: every rule is « à valider » until your cases pass.
