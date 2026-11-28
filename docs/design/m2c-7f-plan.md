# M2c-7f plan — hardening, property machine, 50k close-out, docs close-out

Status: build plan for M2c-7f, the last slice of M2c-7 (`docs/design/m2c-7-plan.md` §8). Nothing here is built. Base:
`034d985` (main through PR #50, 7e-2, merged as `4f8d98c`, plus 7e-3, PR #51, open, CI pending:
`20261201090000_label_reference_exits.sql`). It splits 7f into two PRs:

- **7f-1** — the hardening and every code fix deferred to 7f, each with its db-job read test. Migration
  `supabase/migrations/20261202090000_close_out_hardening.sql`.
- **7f-2** — the property machine (§8.2), the 50k close-out volume file (§8.3), the docs close-out (§8.4), the mutants
  replay (§8.5) and the go-live gate (§8.6).

An item goes to 7f-2 only if it needs the machine or the volume run. §4 names every item dropped or re-deferred, with
why; §5 lists the open items that were never deferred to 7f, so that nothing is lost silently.

**The cancellation-after-download switch stays OFF** (founder 6b-3 Q1 unanswered). A rule reachable only with it on is
tested with it on, inside rolled-back transactions (`private.switch_on()` in the test's own transaction, as 033, 034,
039–042). 033 is unchanged. 034–047c keep every assertion; a changed expectation is justified in the ADR (house rule
R3).

## 0. How this list was compiled (grepped, not recalled)

- **ADR-0014**: every « Left open » block from « M2c-6b-3b part 3 — CI round (PR #40) » (l.5722) to the end (l.12404),
  extracted whole; then `grep -n -E "\b7f\b|7f's|hardening|later slice|next slice"` over the file (47 hits from l.5600).
- **PROGRESS**: `grep -n -E "7f|hardening|later slice"` and every « Known limits » and founder-question default of the
  M2c-7 entries (l.5–257, l.530–555).
- **The plan**: §8 (l.2567–2697) and `grep -n "7f\|machine\|close-out"` elsewhere (l.77, 182, 209–218, 282, 322, 354,
  359, 869–870, 2171, 2705–2723, 2969, 2987).
- **Elsewhere**: `docs/benchmarks/remittances.md` (l.1957, 2448, 3146, 3202), `docs/COMPLIANCE.md` (l.236, OQ-84),
  code comments (`supabase/migrations/20261129090000_top_ups.sql:2273`,
  `worker/tests/test_label_reference_reads_integration.py:35`, `:439`).
- **Latest definitions**: every `create [or replace] function` of the 50 migrations indexed in order (617 functions; the
  last definition wins). Each « copy » below names that file and line, and its length to the closing `$$;`.

---

## 1. The two lists

**7f-1** (hardening and deferred code fixes; details, sources and tests in §2). Kind: « fix » is code, « read test »
a db-job stale-statistics test, « text » French copy on a page; sizes are non-test lines (§2.9), « + » what a
measurement may add.

| ID | Item | Kind | Size | Rubric (off / on) |
|---|---|---|---|---|
| H1 | `run_payment_checks`: `enable_seqscan = off`, every read keyed (forged-statistics test) | fix, read test | ≈ 590 | low / low |
| H2 | `servicer_shortfall` = `private.top_up_needed` (the sweeps in flight) | fix, text check, pgTAP | ≈ 15 (in H1's copy) | **medium-class** / same |
| H3 | main's own nightly probes of `bank_transaction_org_idx`: single-column partial indexes | fix (indexes), read test | ≈ 25 | low / low |
| H4 | `bank_booking_candidates`' 60,000 under the class | fix (indexes), read test | ≈ 15 + 175 | low / low |
| H5 | `debit_queue` keyed (`enable_seqscan = off`, keyed laterals) and bounded absolutely | fix, read test | ≈ 250 | low / low |
| H6 | `apply_bank_bookings`' review replacement by a keyed delete | fix, read test | ≈ 45 | low / low |
| H7 | the payout files' file-keyed reads moved to the items route (D12) | fix (index drop, then copies), read test | ≈ 5 + 380 | low / low |
| H8 | the audit of status-filtered updates beside key arrays | audit, fix where measured, read test | 0 + 650 | low / low |
| H9 | `request_top_up` serialised with the hourly job (MONEY-BANK-3) | fix, text, integration | ≈ 90 | low / low |
| H10 | an own-account file refused by the switch-on two-step cancellation | fix, pgTAP (switch on, rolled back) | ≈ 150 | unreachable / low |
| H11 | MONEY-2: the same proof recorded twice refused (`evidence_already_used`) | fix, text, pgTAP, integration, read test | ≈ 260 | **medium-class** / same |
| H12 | `bad_date` names the greatest refused day | fix, pgTAP | ≈ 30 | low / low |
| H13 | the withdrawal notice worded per advance | fix, text, pgTAP, vitest | ≈ 90 | **medium-class** / same |
| H14 | `post_allocations`' backstop re-reads the mandate's end | fix, pgTAP, integration | ≈ 275 | low / low |
| H15 | a barred invoice dated by the earliest bar in effect, `least(withheld_on, barred_on)` | fix, pgTAP | ≈ 60 | low / low |
| H16 | CCS-2: the advance chip and the totals from the 4112[c] / 419[c] balances; chip out of auto-refresh | fix, text, pgTAP, read test | ≈ 90 + 57 | low / low |
| H17 | a repayment-request letter whose job died re-queued | fix, integration | ≈ 35 | low / low |
| H18 | two or more `/REF` in a CSV label give no end-to-end id | fix (worker), unit, integration, doc (OQ-84) | ≈ 30 | **medium-class** / same |
| H19 | `inflight_overdue_lines` read by the run's key alone | fix, read test | ≈ 40 | low / low |
| H20 | the earlier slices' loader reads under planted statistics (7b round 2's list) | fix, read test | ≈ 90 + 290 | low / low |
| H21 | the statement summary worded « à l'import » | text, vitest, screenshots | ≈ 15 | **medium-class** / same |
| H22 | (carried in, not named 7f) TUI-5: the « Lier » sheet's « Il sera imputé » after a mandate's end | fix, text, vitest, screenshots | ≈ 110 | **medium-class** / same |
| H23 | (carried in, not named 7f) the « Virement hors reversement » sentence false since 7d-2 | text, vitest, screenshots | ≈ 5 | **medium-class** / same |
| T1 | the PR #50 CI-round test can pass vacuously (`_servicer_unseen`'s float4 sum) | test | test lines only | low |
| T2 | the PR #50 CI-round test's two arms differ in an aged state | test | test lines only | low |
| T3 | Hypothesis `deadline=None` on `test_camt053_details` | test | 1 test line | low |
| T4 | 7d-2's reads test extended to the drafted-after-the-event case (TUI-7 docstring) | test | test lines only | low |

**7f-2** (needs the machine or the volume run; details and sources in §3):

| ID | Item | Kind | Size |
|---|---|---|---|
| M1 | the full property machine, switch off and on (§8.2), in its PR budget (F15) | test, benchmark doc | ≈ 1,400 test lines + the oracle's ≈ 600 |
| M2 | 7a's `ledger_machine.py` part (a remitted reversal: an advance or LG009) | test (oracle) | in M1 |
| M3 | 7b's claw-back rule in the machine | test (oracle) | in M1 |
| M4 | 038's three planted « Suivi » scenarios: their reachable states walked by the machine (038 unchanged) | test | in M1 |
| M5 | the cover's release re-queued in a later run (switch on): « less set off, never more » checked | test | in M1 |
| M6 | a live request naming a reversed advance: a machine invariant (no nightly alert) | test | in M1 |
| V1 | `test_close_out_scale_integration.py`: the eight rows of §8.3 | test, benchmark doc | ≈ 700 test lines |
| V2 | R-a's fallback: the run trigger made statement-level if row 8 fails | fix, only if measured | 0 + 120 |
| V3 | measured at volume, changed only if a bound breaks: the blockers' nested calls (7d-1 CC-1), `ledger_post_set`'s pooled lookup, `bank_transfer_file_idx`'s once-per-check reads, `test_transfer_files_scale`'s headroom | measurement, fix only if a bound breaks | 0 + 60–330 |
| V4 | CI wiring: the close-out file's job, the machine's step | CI config | ≈ 30 |
| D1 | docs close-out (§8.4; design §21's M2c-7 docs list) | doc | ≈ 1,000 |
| D2 | the go-live gate's text (§8.6) | doc | in D1 |
| X1 | the mutants replay (§8.5) | test (mutants) | none |

Rubric: « medium-class » marks an item that, by this workflow's severity rule, the system itself or one ordinary ops
action can reach: a false or missing amount or statement on a page (H2, H13, H21, H22, H23) or money misclassified
(H11, H18). Each was recorded low by its own review, or deferred by design (H2, plan D7); none may be re-deferred.

---

## 2. 7f-1 — the hardening and every deferred code fix

Branch `m2c7f-1`, from main once PR #51 is merged. Migration `20261202090000_close_out_hardening.sql` (renamed at PR
open if main holds a later timestamp: [critic] F12). If PR #51's CI round edits `20261201090000` in place, every copy
below taken from it is copied again from the final file.

Every redefinition copies the latest body whole (file and line below), changes only what this section says, and
restates SECURITY DEFINER, every SET clause, `search_path ''` and the grants (service_role where the worker calls it).
Its header names the file and line it redefines from. No table is added. If one becomes necessary, it gets RLS, the
change log and a pgTAP tenant-isolation test.

### 2.1 The nightly and the bank lines (the plan class that broke main after 7a and in PR #50's CI round)

**H1 — `private.run_payment_checks` hardened.**
- **Sources:** plan §8.1 (`m2c-7-plan.md:2571-2575`), its table l.77, §1 l.182-183, §1.1 l.210, §1.4 l.322;
  ADR-0014:5724-5729 (PR #40 CI round, « set it in a later slice with the 50k scale run measured »); PROGRESS.md:555;
  `docs/benchmarks/remittances.md:1957` (under 7c-1's plant its earlier checks read the servicer's planted invoices 18
  times, 180,012 rows: « 7f's hardening »).
- **Do:**
  - Copy `20261118100000_switch_on_prerequisites_2.sql:3310` (566 lines) and add `set enable_seqscan = off`. Under
    PR #40's forged statistics, its `refund_request` reads by a payment's or transfer's key ran as one scan per row
    (1.7 million rows for 640 payments), and `bank_transfer` was read once by a scan of every servicer's rows.
  - Attribute the 18 invoice reads statement by statement under 7c-1's plant
    (`test_client_payment_reads_integration.py`'s `_plants`). A per-row read is keyed. A read of the servicer's
    invoices once per statement is bounded per statement and named in the ADR.
  - H2's change goes in the same copy.
- **Kind:** code fix + db-job read test.
- **Size:** about 590 lines (the copy and about 25 changed).

**H2 — `servicer_shortfall` = `private.top_up_needed` per currency.**
- **Sources:** plan §8.1 (l.2573-2574), D7 (l.282), §7.1 (l.2171), money rule 19 (l.2722, « 7f `servicer_shortfall` »);
  `20261129090000_top_ups.sql:2273` (« keeps its formula in run_payment_checks until 7f (D7) »).
- **The gap today:** the statement at `20261118100000:3770` alerts when Σ4679 − top-ups in flight > 0. It omits
  `+ sweeps in flight`, which `top_up_needed` (`20261129090000:181`), the hourly order and the shortfall log use. With
  a sweep in flight, « Contrôles » therefore shows less than the hourly job orders, or no row when
  Σ4679 < 0 < Σ4679 + sweeps.
- **Do:** compute the amount from `top_up_needed` (one keyed call per currency of the servicer's 4679 accounts), with
  `details` gaining `sweeps_in_flight_minor`.
  - The help (`apps/web/src/lib/payments/debits.ts:1324-1327`) must stay true. So must the TUI-1 variant
    (`debits.ts:1865-1875`) and « Contrôles »' cut rows (ADR-0014:10936-10938).
- **Tests:** `048` (a sweep in flight; switch off and on). R3 if `017` (l.843-883) or `047a`'s pins change.
- **Size:** about 10 lines inside H1's copy, and 5 of web.

**H3 — main's own probes of `bank_transaction_org_idx`, keyed by single-column partial indexes.**
- **Sources:** ADR-0014:11819-11826 and :11848 (PR #50's CI round: under that plant main's nightly reads the servicer's
  lines six times, 60,002 for 10,000, against the scale bound of 62,000); PROGRESS.md:49.
- **The probes:**
  - `run_payment_checks`' `debit_unclassified`: three kind branches (`20261118100000:3809-3829`);
  - `duplicate_unresolved` (`:3844`);
  - `run_transfer_checks`' `other_debit` read (`20261121120000_switch_on_prerequisites_5.sql:1310`).
- **Do:** the shape of PR #50's fix (`bank_transaction_label_reference_idx`, `20261130090000:85`), created beside the
  existing multi-column indexes. A single-column partial index is a subset of `bank_transaction_org_idx`, priced with
  the same correlation and a shorter descent, so it is never above it.
  - `(organization_id) where kind in ('return', 'refund_out', 'suspected_duplicate')`: the first branch and
    `duplicate_unresolved`.
  - `(organization_id) where kind in ('transfer_out', 'own_transfer_in', 'client_transfer_in', 'label_reference')`:
    the second branch (its three kinds imply it) and H4.
  - `(organization_id) where kind = 'other_debit'`: the third branch, `run_transfer_checks` and H4.
  - `run_transfer_checks` is not copied (404 lines, R1). A probe that still loses gets a fence per probe in its
    function: the ADR's alternative, measured.
- **Test:** PR #50's plant (the servicer unseen, correlation 1, 200,000 lines of five other servicers in organization
  order). Bound: no probe reads a line outside its kinds. The whole nightly's `bank_transaction` reads are at most the
  plant's lines of each probe's kinds, plus the two keyed reads PR #50's arithmetic names, plus PER_CALL. The plant
  mixes the kinds, so a probe reading the servicer's every line fails it. It fails on main's indexes (60,002).
- **Volume:** the scale files' `assert_checks_keyed` bound (6 × N + 2,000) is unchanged; the dispatched `scale` run
  reports the new figure.
- **Size:** about 25 lines.

**H4 — `private.bank_booking_candidates`' 60,000.**
- **Sources:** ADR-0014:11824-11826 (« the funds pass's `bank_booking_candidates` reads 60,000 on that state with both
  bodies »).
- **Do:** first H3's indexes, plus three for its other branches:
  - `(organization_id) where direction = 'debit' and end_to_end_id is null and payment_info_id is not null` (batch
    lines);
  - `(organization_id) where direction = 'credit' and kind = 'return'`;
  - `(organization_id) where unsplit_ours > 0`.
- **Then measure** each of its six branches under H3's plant.
  - The copy (`20261130090000:784`, 171 lines; `set enable_seqscan = off` added beside its hash and merge settings)
    is made only if a branch still reads beyond its bound.
  - The branches keep `order by booking_date, id limit`. Under true statistics the multi-column indexes keep serving
    the cursor, which the dispatched `scale` and `scale-payouts` runs confirm (the funds pass and the 5,000-payout
    bookings).
- **Test:** the funds pass's candidates call bounded at its limit + PER_CALL per branch.
- **Size:** about 15 lines; the copy only if needed (175).

**H5 — `public.debit_queue` keyed and bounded absolutely.**
- **Sources:** ADR-0014:11456-11460 (7e-2 round 1, CC-1: « the 7f hardening slice gives it `set enable_seqscan = off`,
  turns the four join tables into keyed `offset 0` laterals by `bank_transaction_id` in each branch and in the final
  select, and bounds the whole queue absolutely »), :11825; PROGRESS.md:50; benchmarks l.3146, l.3202;
  `test_label_reference_reads_integration.py:35`, `:439`.
- **Do:** copy `20261130090000:964` (205 lines; same signature, `create or replace`). Make the review, link, release
  and resolution reads keyed laterals in each branch and in the final select, and the servicer's lines served by H3's
  indexes.
- **Test:** the whole queue under PR #50's plant and the four tables planted (10,000 rows each over two keys). Bound
  absolutely: ≤ 2 rows per listed line per table + PER_CALL. It fails on the old body (260,196 index rows for 65,000
  lines measured by the 7e-2 review).
- **Size:** about 250 lines.

**H6 — `private.apply_bank_bookings`' review replacement by a keyed delete.**
- **Sources:** ADR-0014:11312-11314, :12091, :12241; PROGRESS.md:50, :544 (founder default « a keyed delete in 7f's
  hardening »).
- **Do:** copy `20261129090000_top_ups.sql:1845` (38 lines). The delete reads `bank_transaction_id = any (array(…))`
  of the job's temporary table instead of joining it.
- **Test:** the review table planted with 10,010 rows (the 7e-2 reads test's figure). Bound: the rows the call writes
  + PER_CALL.
- **Size:** about 45 lines.

**H19 — `private.inflight_overdue_lines` by the run's key alone.**
- **Sources:** ADR-0014:6583-6587 (7a CI round: the same shape as the three reads it fixed, `x.run_id = r.id and not
  x.released` implying `remittance_line_live_uq`'s predicate; 10,048 rows for one run in flight under the plant;
  « give it the same shape in a later slice, with the nightly's scale run measured »); ADR-0014:7245-7246 (the night's
  other 10,036 `remittance_line` rows).
- **Do:** copy `20261112090000_remittance_runs.sql:2320` (37 lines). The run's lines are read by `run_id` alone inside
  the `offset 0` fence, the conditions outside: the 7a CI round's form (`20261123080000`).
- **Test:** `test_remitted_cover_reads_integration.py`'s plant. Bound: ≤ the run's lines + PER_CALL. It fails on the
  old body.
- It is the per-row class this workflow names, so it is not left to 7f-2. The dispatched `scale` run is its « nightly's
  scale run ».
- **Size:** about 40 lines.

### 2.2 Payout files and updates

**H7 — the payout files' file-keyed reads moved to the items route (D12).**
- **Sources:** ADR-0014:11063-11066 (7e-1 round 2: « 7f's hardening measures them and moves them to the items »);
  D12 (ADR-0014:11004); PROGRESS.md:66.
- **Do, in three steps:**
  1. Drop `bank_transfer_filed_amount_idx` (`20261117100000_transfer_line_ops.sql:81`). It is the index of 7e-1's
     flip: its predicate `transfer_file_id is not null` is implied by every `transfer_file_id = f.id`. It is a partial
     twin of `bank_transfer_account_amount_idx` (`20261117110000:2007`, the same columns), which rule 3b's per-line
     probe then uses, filtering `transfer_file_id` on the row. This is measured by the transfer-lines scale file in the
     dispatched `scale` run.
  2. Measure each remaining direct read under 7e-1 round 2's plant (dead index entries from rolled-back plants):
     - `private.transfer_file_release` (`20261118100000:4663`, 75 lines; l.27, 30, 65 of its body);
     - `private.transfer_line_supersedes` (`20261117100000:1708`, 51; l.39);
     - `public.mark_transfer_file_sent` (`20261115090000:2174`, 54; l.50);
     - `public.confirm_transfer_file_cancellation` (`20261116090000:4883`, 69; l.58; copied for H10 anyway);
     - `private.transfer_line_locks` (`20261118100000:1888`, 187; l.151, a late predecessor's file: switch-on states,
       measured with the switch on in the rolled-back transaction).
  3. Move to the file's items (`transfer_file_item` by its key, each transfer by its own, file, status and kind checked
     on the row, as 7e-1 round 2 did) every read that still reads beyond them. A status filter can still imply
     `bank_transfer_debtor_idx`'s or `bank_transfer_servicer_flight_idx`'s predicate, which is why the index drop
     alone is not taken as the fix. A read that does not read beyond them is recorded with its figure and kept: H7's
     only size lever.
- **Test:** each read's rows ≤ its file's items + PER_CALL.
- **Size:** about 5 lines; then up to about 380 lines of copies, one per read the measurement moves.

**H8 — the audit of status-filtered updates and reads beside a key array.**
- **Sources:** ADR-0014:12384-12387 (7e-3 round 2: « audit them in the 7f hardening slice, with a plant of current rows
  as here »); PROGRESS.md:26.
- **Candidates** (from a grep of the latest bodies for `update … = any (…) … status in/=`):
  - `private.bank_booking_post_rows` (`20261201090000:2883`, 296 lines): its `remittance_run` update (body l.187, the
    ADR's example) and its two `bank_transfer` updates (l.170, l.179);
  - `private.transfer_line_post` (`20261201090000:2679`, 189; l.135);
  - `public.generate_top_up_file` (`20261129090000:659`, 104; l.94);
  - `public.cancel_top_up_file` (`20261129090000:773`, 62; l.54);
  - and the same pattern in reads found while auditing.
- **Do:** run each under a plant of current rows (7e-3 round 2's: many live rows whose status implies the partial
  index's predicate, every servicer's). Fix it (a loop by key, or the key alone inside a fence with the status outside)
  only where the plant shows the partial index read whole. The audit's table, with its figures, goes in the ADR.
- **Size:** the audit, then 0 to about 650 lines of copies (expected: `bank_booking_post_rows` only, about 300).

### 2.3 Commands

**H9 — `public.request_top_up` serialised with the hourly order (MONEY-BANK-3).**
- **Sources:** ADR-0014:10927-10930 (« 7f's hardening takes `remittance_command_locks` in `request_top_up` (a whole
  copy, a 55P03 refusal to map on « Comptes bancaires ») »); PROGRESS.md:66, :534 (founder default); plan R-f (l.2988).
- **Do:**
  - Copy `20261111090000_remittance_funds.sql:1548` (71 lines). Add `set lock_timeout = '2s'` and
    `perform private.remittance_command_locks(org, true)` before its read of what is owed, as `order_due_top_up` does
    (`20261129090000:311`).
  - The web maps 55P03 on « Comptes bancaires » to « Une opération est en cours sur les fonds du cabinet : réessayez
    dans quelques secondes. ».
- **Test:** worker integration, two connections. While the hourly job holds the remit lock, ops' order is refused
  55P03; retried after the job's commit, it reads the top-up the job ordered. Then the reverse order.
- **Size:** about 90 lines.

**H10 — an own-account file refused by the switch-on two-step cancellation.**
- **Sources:** ADR-0014:10932-10935 (« Default: 7f refuses own files there as `cancel_transfer_file` now does »).
- **Do:** copy `public.request_transfer_file_cancellation` (`20261116090000_debit_bookings.sql:4813`, 68 lines) and
  `public.confirm_transfer_file_cancellation` (`:4883`, 69). Both refuse an own file with the refusal
  `cancel_transfer_file` uses (`20261129090000:839`). H7 is applied in the same copy.
- **Tests:** `048`, with the switch on inside its rolled-back transaction. With the switch off the path is refused
  earlier (`033` unchanged).
- **Size:** about 150 lines.

**H11 — MONEY-2: the same proof recorded twice is refused.**
- **Sources:** ADR-0014:7839-7848 (« 7f's hardening (plan §8.1) adds `evidence_already_used`, keyed on the proof's
  content (its sha256 among the client's payment evidence, as two uploads of one file are two documents) with a partial
  unique index on the entries' source, and a stale-statistics bound for that read. `record_client_refund` the same,
  bounded by what is owed; one transfer refunding two documents is then two recordings of one proof, which the guard
  must still allow »); PROGRESS.md:194.
- **Do:**
  - Copy `public.record_client_payment` (`20261124090000_client_payments.sql:1940`, 93 lines). It refuses
    `evidence_already_used` when a `client_payment_evidence` of the client with the same `document.sha256` already
    sources a client payment entry. The entries' source is `'document'`, the evidence id (its body l.87).
  - Add a partial unique index on `ledger_entry (source_id)` for the client-payment entry types, and an index for the
    keyed sha256 read: `document (client_organization_id, sha256) where kind = 'client_payment_evidence'`.
  - Copy `public.record_client_refund` (`:2158`, 114 lines). It refuses the same proof twice for the same credit or
    credit note and allows it across documents.
  - The French hints go on both sheets, for example « Ce justificatif a déjà servi à enregistrer le règlement du … ».
- **Tests:**
  - `048`: two documents with one sha256; refunds of two documents by one proof (allowed); switch off and on.
  - Worker integration: two sessions recording one proof, exactly one succeeding.
  - Reads test: the client's planted evidence documents. Bound PER_CALL.
- **Size:** about 260 lines.

**H12 — `bad_date` names the greatest refused day.**
- **Sources:** ADR-0014:8247-8251 (« 7f's hardening names the greatest day among the refused designations »);
  PROGRESS.md:198.
- **Do:** copy `private.client_payment_named_refusal` (`20261124090000:1477`, 26 lines). It returns the `bad_date`
  refusal with the latest day among the refused designations. The web text (`settlements.ts:463-494`) is unchanged:
  it prints the day SQL names.
- **Test:** `048` (round 4's verifier probe q6: an advance born d−2 and an invoice issued today, both designated at d−5:
  one refusal naming today).
- **Size:** about 30 lines.

**H13 — the withdrawal notice worded per advance.**
- **Sources:** ADR-0014:8714-8718 (« 7f's hardening returns which advances stay requested and words the notice per
  advance »); PROGRESS.md:160.
- **Do:**
  - Copy `public.withdraw_advance_repayment_request` (`20261125090000_repayment_requests.sql:603`, 49 lines). It also
    returns, per advance of the withdrawn request, the live requests that still name it. `still_requested_by` is kept
    for the web's older parse.
  - `requests.ts` `withdrawEffect` (l.108-135) names the advances that stay requested and those that may be requested
    again.
- **Tests:** `048`; vitest (R3 for its pins). Screenshot `m2c7-demande-remboursement` retaken if the toast is in it.
- **Size:** about 90 lines.

**H14 — `private.post_allocations`' backstop re-reads the mandate's end.**
- **Sources:** ADR-0014:9014-9016 (« Default: keep; 7f's hardening »); PROGRESS.md:128.
- **Do:** copy `20261110120000_debits_refunds.sql:2017` (268 lines). Its gates (body l.63-74) gain the mandate's end,
  as `gate_assignments` reads it (`20261126090000:1149`, body l.70: `client_mandate_ended`).
  - The allocation scale file times this path: dispatch `scale`.
- **Tests:**
  - `048`: an end committed between the job's read and its post, planted by calling the job's SQL with the end
    inserted between.
  - Integration: two connections.
- **Size:** about 275 lines.

**H15 — a barred invoice dated by the earliest bar in effect.**
- **Sources:** ADR-0014:10490-10496 (7d-3 round 3's verifier: « 7f's hardening dates a barred invoice by the earliest
  recording among the invoice bars in effect and keeps least(`withheld_on`, `barred_on`), with 046c cases »);
  PROGRESS.md:87.
- **Do:** copy `private.client_post_opening_unpaid` (`20261128090000_declarations_statement.sql:376`, 38 lines).
  - `barred_on` is the least of `private.client_set_off_bar_recorded_on` over the invoice bars in effect
    (liquidation, mandate end, seizure).
  - The filter is `coalesce(due_date, least(withheld_on, barred_on)) < p_on`, so a debit on the check's day no longer
    drops the invoice for that night.
  - `run_advance_checks` is not copied (435 lines): its age stays `coalesce(due_date, withheld_on, barred_on)`, the day
    each help sentence names. Check that the web's help reads `barred_on` correctly once it is also returned for a
    withheld invoice; if it does not, `barred_on` stays null when `withheld_on` is set and only the filter uses
    least().
- **Tests:** the cases go in `048`, not `046c`, which stays unchanged: a seizure then a liquidation, a seizure then a
  death, a debit after a liquidation.
- **Size:** about 60 lines.

**H17 — a repayment-request letter whose job died is re-queued.**
- **Sources:** ADR-0014:8518-8519 (« Default: keep until 7f »); PROGRESS.md:156.
- **Do:**
  - Add a new `private.requeue_repayment_letters()` (SECURITY DEFINER, keyed on live requests with no letter after an
    hour, `enable_seqscan` off), scheduled hourly by pg_cron. It sends the same message `request_advance_repayment`
    sends (`20261125090000:588`).
  - The job is idempotent: it draws once, skips a withdrawn request, and the letter's document is set once.
  - The nightly `repayment_request_document_missing` stays.
- **Tests:** worker integration (a message archived after its retries, then re-queued, one letter).
- **Size:** about 35 lines.

**H18 — two or more `/REF` in a CSV label give no end-to-end id.**
- **Sources:** ADR-0014:11571-11577 (7e-2 round 2: « in the 7f hardening slice, a label carrying two or more `/REF`
  markers gives no end-to-end id (its tokens of ours then candidates, held `label_reference`); a single `/REF` keeps
  M2b's reading »), :11707; PROGRESS.md:50, :543 (founder default); COMPLIANCE.md:236 (OQ-84).
- **Do:**
  - `worker/src/collectoo_worker/payments/csv_import.py` `parse_label` (l.220) counts the `/REF` markers and the
    end-to-end choice (around l.521) takes none when there are two or more.
  - The duplicate fingerprint (7e-2 R5: it keeps the cell) must be unchanged for a re-import of a pre-fix file. If it
    is not, R2's precedent applies (held as a possible duplicate, never booked twice).
  - COMPLIANCE OQ-84's residual is marked closed.
- **Tests:** unit, Hypothesis over labels, and integration (the real CSV import and the debit job: a payer's
  « /REF RMT… » before the bank's is held `label_reference`, not booked `payout_returned`).
- **Size:** about 30 lines of Python.

### 2.4 Advances and credits read in full (CCS-2)

**H16 — totals from the ledger, the chip out of the auto-refresh.**
- **Sources:**
  - ADR-0014:7054-7059 (7b round 1, CCS-2: « 7f's hardening takes the chip's totals from the 4112[c] balances (the
    nightly `advance_ledger` proves them equal) or a keyed set of open advances, and moves the chip read out of the
    page's auto-refresh »);
  - :7675-7677 (credits: « 7f's hardening with CCS-2 »);
  - :8525-8526 (« Avances »' totals);
  - PROGRESS.md:196, :220.
- **Do:**
  - Add a new `public.client_advance_totals(p_organization_id)`: per (client, currency), the balance of the servicer's
    4112[c] accounts, read by the accounts' key (money staff at aal2).
  - The chip on « Reversements » (`apps/web/src/app/backoffice/reversements/page.tsx:42-52`) and « Avances »' totals
    read it; the chip is fetched outside the page's refresh loop.
  - Credits: totals from 419[c] likewise, where a total is shown.
  - The lists keep the per-row open part, bounded by the client's own rows (§4 R11).
  - Types regenerated.
- **Tests:** `048` (the totals equal Σ `advance_open` and Σ `client_credit_open` in the fixtures, switch off and on).
  Reads test: 5,000 settled advances planted; the totals read ≤ the client's accounts + PER_CALL. Vitest.
  Screenshots `m2c-reversements`, `m2c7-reversements-avance` and `m2c7-avances` retaken if a number moves.
- **Size:** about 90 lines (plus `client_advances`' 57-line copy only if its totals move into it).

### 2.5 The earlier slices' reads under planted statistics

**H20 — the loader reads of 7b round 2's list.**
- **Sources:** ADR-0014:7240-7248 (« 7f's hardening plants these the same way »); PROGRESS.md:223.
- **Planted figures** (`test_advance_reads_integration.py`'s print):
  - the prepare's pending items by draft (`worker/src/collectoo_worker/jobs/remittances.py:397-406`;
    `remittance_pending` 10,013);
  - the terms by mandate (`:527`; `mandate_terms` 10,098);
  - the blockers (`:673` → `private.remittance_payout_blockers`, `20261126090000:1097`, 46 lines;
    `client_status_event` 10,000);
  - `write_draft`'s `remittance_pending` (`private.remittance_record_draft`, `20261127090000:663`, 60;
    `private.remittance_prepare_begin`, `20261112090000:1064`, 17; 10,006);
  - the approval job's (`private.approve_remittance_run`, `20261127090000:845`, 165; `remittance_pending` 20,012,
    `client_status_event` 10,000, `mandate_terms` 10,099).
- **Do:** plant each table as that test does and measure every read.
  - Each worker query that reads the plant moves into a keyed SQL helper (SECURITY DEFINER, `enable_seqscan = off`, a
    fenced lateral; the pattern of `private.client_open_advances` and `private.draft_held_items`).
  - Each SQL function that reads the plant is copied and fenced.
- **Test:** every call ≤ its rows + PER_CALL (60).
- **Size:** about 90 lines (helpers and worker), then up to about 290 lines of copies, only where measured (approval
  165, draft 60, prepare 17, blockers 46).

### 2.6 Texts on pages

**H21 — the statement summary worded as of the import.**
- **Sources:** ADR-0014:12236-12239 (7e-3 round 1: « word it as of the import (« à l'import ») in the 7f hardening
  slice »); PROGRESS.md:22.
- **Do:** `apps/web/src/app/backoffice/encaissements/statement-summary.tsx:82` (« À classer ou retenues ») and
  `apps/web/src/lib/payments/statements.ts:204-206` (« expliqué par N lignes du compte à classer ») say the count is the
  import's, for example « À classer ou retenues à l'import » and « … expliqué à l'import par N lignes du compte ».
- **Tests:** vitest (R3 for its pins). Screenshots `m2-statement-imported` and `m2c-debits-detail-releve` retaken
  (mobile + desktop).
- **Size:** about 15 lines.

**H22 — (carried in) TUI-5: the « Lier » sheet after a mandate's end.**
- **Sources:** ADR-0014:9107-9112, :9239-9241 (« the slice that next redefines `match_queue_accounts` and
  `search_payment_files` carries the client's end date »); PROGRESS.md:127.
- **Why 7f-1 takes it:** no slice after 7f is planned to redefine these reads, and it is a false statement on a page.
- **Do:**
  - Drop and create `public.match_queue_accounts` (`20261109150000_payment_matching.sql:902`, 26 lines) and
    `public.search_payment_files` (`:930`, 46). Both return the client's mandate end. Grants are restated and the types
    regenerated.
  - `matching.ts` `gatingOutcome` words the hold (« Ce paiement sera retenu : le mandat du client a pris fin le … ;
    reversez-le au client ou rendez-le au payeur »).
- **Tests:** vitest; screenshot `m2c7-paiement-apres-fin-mandat` retaken.
- **Size:** about 110 lines.

**H23 — (carried in) the « Virement hors reversement » sentence.**
- **Sources:** ADR-0014:9968-9971 (7d-3: « reworded by the next slice that touches the sheet (R3 for its pins) »).
- **Why 7f-1 takes it:** no later slice touches the sheet.
- **Do:** `apps/web/src/lib/payments/transfer-lines.ts:517` says an advance with a claw-back clause is taken back
  « jamais si elle est antérieure à l'ouverture d'une procédure collective du client ». Since 7d-2, none is taken back
  while a proceeding or a liquidation stands, whatever its birth. It is reworded to what the plan does.
- **Tests:** R3 for `transfer-line-pages.test.ts:254`, `:265`. Screenshots `m2c-virement-hors-reversement` retaken.
- **Size:** about 5 lines.

### 2.7 Tests only

- **T1** (ADR-0014:11846; PROGRESS.md:49): `_servicer_unseen` (`test_label_reference_reads_integration.py:526`) raises
  the largest frequency until the float4 sum is ≥ 1. The test asserts that the 7e-1 arm reads ≥ 4 per servicer line,
  so a vacuous pass fails. H3, H4 and H5 reuse the helper.
- **T2** (ADR-0014:11847): in the PR #50 test, bound only `bank_transaction`, or run an untimed arm first. Default: an
  untimed arm first; both bounds are kept.
- **T3** (ADR-0014:12092-12094; PROGRESS.md:25): `@settings(deadline=None)` on `test_camt053_details.py:412`. It is
  added now, not « if CI ever shows it »: it is one line, and the test already failed twice on the build VM (7e-3's
  suites).
- **T4** (ADR-0014:9707-9710): `test_set_off_bar_reads_integration.py`'s proceeding case also drafts after the event, so
  the approval re-check reaches `plan_sets_off_barred`'s repricing read. Planted as the verifier did (20,000 draft lines
  and repricings, n_distinct 2, generic plans). Bound ≤ 60.

### 2.8 7f-1's tests (written first, seen failing)

- **pgTAP `048_close_out_hardening.test.sql`:** H2, H10 (switch on, rolled back), H11, H12, H13, H14, H15 and H16, each
  with the switch off and on.
  - It also checks the index definitions (H3, H4), H7's dropped index, and the grants and settings of every redefined
    function (`proconfig` has `enable_seqscan=off` where this plan sets it).
- **The db-job read test `worker/tests/test_close_out_reads_integration.py`** (not a `*scale_integration.py` name, so
  the `db` job runs it). It covers H1, H3, H4, H5, H6, H7, H8, H11, H16, H19 and H20.
  - It reuses `_plant` and `_servicer_unseen` (T1) of the `*_reads_integration.py` files.
  - Each test plants stale statistics in a rolled-back transaction and bounds the rows read from
    `pg_stat_xact_user_tables` (`idx_tup_fetch` + `seq_tup_read`).
  - Each is seen failing on the old body, created beside the new one in the transaction as earlier rounds did.
- **Worker integration `test_close_out_hardening_integration.py`:** H9 (two connections), H11 (two sessions), H14, H17,
  and H18 through the real import and debit job.
- **Unit and Hypothesis:** H18's parser, T3.
- **Vitest:** H2's help, H9's hint, H11's hint, H13, H16, H21, H22, H23.
- **E2E:** the existing specs, re-run, with screenshots retaken for every changed page (mobile + desktop).
- **Mutants:**
  - each read test against the old body;
  - `servicer_shortfall` without the sweeps term;
  - the sha256 comparison removed, and the refund's cross-document allowance removed;
  - `request_top_up` without the lock;
  - the own-file refusal dropped (switch on);
  - `bad_date` by min;
  - the per-advance notice ignored;
  - the backstop's end removed;
  - the barred day by the strongest bar, and least() removed;
  - the `/REF` count removed;
  - TUI-5's date ignored;
  - the totals from `advance_open` again.
- **R3 changes expected:** `017`'s and `047a`'s `servicer_shortfall` pins wherever a sweep is in flight (H2), and the
  vitest pins of H13, H21, H22 and H23. Each is justified in the ADR. `033` and every other assertion of 034–047c are
  unchanged.
- **CI:** 7f-1 changes paths `scale` and `scale-payouts` time: the nightly, the funds pass's candidates, the import,
  allocation, transfer files and the payouts' bookings. Its branch dispatches CI (`workflow_dispatch`) and merges only
  once both volume jobs are green.

### 2.9 7f-1's size (non-test lines; docs apart)

| Part | Firm | Only if measured needed |
|---|---|---|
| SQL: indexes (H3, H4, H7) | 45 | — |
| SQL copies, firm: H1+H2 566, H5 205, H6 38, H9 71, H10 137, H11 207, H12 26, H13 49, H14 268, H15 38, H19 37, H22 72 | 1,714 copied + ≈ 230 changed | — |
| SQL new: H11 indexes, H16 totals read, H17, H20 helpers | ≈ 160 | — |
| SQL copies, conditional: H4 (171), H7 (≤ 367), H8 (≤ 651, expected ≈ 296), H16 (57), H20 (≤ 288) | — | ≤ 1,534 (expected ≈ 450) |
| Python (H18, H20 worker reads) | ≈ 60 | — |
| TypeScript (H2, H9, H11, H13, H16, H21, H22, H23; regenerated types) | ≈ 180 | — |
| **Total** | **≈ 2,390** (≈ 1,710 of it copies) | expected ≈ 2,850, worst ≈ 3,900 |
| Docs: ADR-0014 « M2c-7f-1 » with its R3 list and the audit's table, benchmarks, COMPLIANCE OQ-84 | ≈ 350 | — |

The firm part fits ~2,500. The conditional copies are made only where a measured read exceeds its bound, so the
expected total is over the target by whole-function copies only, as 7d-1, 7e-1 and 7e-3 were. No item moves to 7f-2
for size, because none needs the machine or the volume run. If the measurements require more than about 600 conditional
lines, founder question 4 applies (§6).

---

## 3. 7f-2 — machine, volume, docs, mutants, gate

Branch `m2c7f-2`, from main once 7f-1 is merged: the machine and the volume run time the final code. No migration is
planned. A fix the machine or the volume run requires gets its own migration, its test (a db-job read test for a read),
and a line in the ADR.

**M1 — the full property machine (§8.2).**
- **Sources:** plan §8.2 (l.2577-2635), §1.1 (l.209 D14/PROP-1, l.218 F15), §1 (l.182), §1.4 (l.322, l.354); the
  money rules the plan pins on « machine » (l.2705, 2706, 2709, 2713, 2717, 2723).
- **File:** `worker/tests/test_close_out_machine_integration.py` (db job).
- **Scope:** the world, the rules, the invariants after every step, the oracle checks (M7-MONEY-1, -5, -10, -11) and
  quiescence, all as §8.2 states them.
- **The oracle:** `worker/tests/ledger_machine.py` (919 lines; it already models the two funds at entry level) gains
  runs, lines, payouts, advances, settlements, credits and top-ups. Its expectations come from its own model, never
  from a SQL helper it checks.
- **Deviation from §8.2, for this workflow's switch rule.** §8.2 flips the switch on in a fixture with `try/finally`.
  Here instead, each switch-on example runs inside one transaction rolled back at its end:
  - commands are called as `authenticated` with the claims set locally, as pgTAP's `read_as` does;
  - jobs run through their Python functions on that connection;
  - the nightly runs with `p_today` advanced.
  So the switch is never committed on. The switch-off class keeps real aal2 API sessions and committed state.
  Two-session races stay with their targeted tests. The class asserts the switch is off before and after each example.
- **Budget (F15):** 2 classes × 8 examples × 20 steps in the PR `db` job, ≤ 6 min, measured and written in the
  benchmarks file. The PR fails above 125 % of that.
  - The `db` job runs ≈ 26–31 min of its 45-minute limit (ADR-0014:11086 left that margin for 7e-2, 7e-3 and 7f).
  - The machine runs as its own pytest step after the integration suite (V4), so the switch-on class is last.
- **Longer runs:** founder question 1.

**M2 — 7a's part of `ledger_machine.py`.**
- **Sources:** plan l.869-870; ADR-0014:5835-5836, :5971, :6035; PROGRESS.md:257.
- The `reverse` rule may mark an entry remitted. The oracle expects an advance after a covering reversal and `LG009`
  after a raw one.

**M3 — 7b's claw-back rule.** Source: ADR-0014:6744 (« the full property machine is 7f's »). Advances are taken back
in the plan, oldest first, on their own mandate's money, under its clause only (rules 7 and 8).

**M4 — 038's three planted « Suivi » scenarios.**
- **Sources:** ADR-0014:5964-5967, :6111-6121, :6898-6899 (« drop the planted branch of the other two when 7f's property
  machine walks the reachable states »); PROGRESS.md:257.
- The machine records whether `d_queue`'s and `d_twice`'s shape is reached: an uncovered negative item beside a
  cancellation after download, with a queue bound. 7a found no path to it under I23.
- `f_partial`'s reachable form (a run approved between RV1's debit and its return, over two statements) is checked as
  a machine case.
- **038 is unchanged:** it keeps every assertion (the brief's rule), so its planted branch is not dropped (§4 R2).

**M5 — a cover's release re-queued in a later run** (switch on; ADR-0014:7063-7066, default kept). The switch-on class
reaches it through « the bank executes it late » and « its return ». The oracle checks that the mandate's room is the
lower one: less is set off, never more.

**M6 — a live request naming a reversed advance.**
- **Source:** ADR-0014:8705-8708 (« 7f's hardening may add it with the other invariants »).
- An invariant after every step: no request that is not withdrawn names an advance whose entry is reversed. No nightly
  alert is added (§4 R4).

**V1 — the 50k close-out volume file (§8.3).**
- **Sources:** plan §8.3 (l.2637-2654), §1.1 (l.210 D15/SCALE-1), R-e (l.2987).
- **File:** `worker/tests/test_close_out_scale_integration.py`, with the eight rows and bounds as §8.3 states them.
  Stale statistics come from a reset, then the import, as the 6a/6b files do. Each bound is asserted, then measured in
  `docs/benchmarks/remittances.md`.
- **Row 4** compares the nightly with 1 and with 10 booked 50k-line runs. Its whole-nightly delta « before and after
  7a's checks » is measured by swapping a body without 7a's checks into the rolled-back transaction.
- **Where it runs:** founder question 2. `scale-payouts` has about 15 of its 40 minutes left (its six files take
  about 21 minutes, plus the stack's start), and this file builds a 50k-line run, 1,000 returns and ten booked runs.

**V2 — R-a's fallback** (plan l.2969-2971, §8.3 row 8). If the funds-pass chunk exceeds 24 s × 1.1 with the at-booking
cover and the per-row run trigger, the run trigger becomes a statement-level trigger on a transition table, one check
per statement, with its pgTAP and the row re-measured. It needs the volume run, so it belongs to 7f-2.

**V3 — measured at volume, changed only if a bound breaks.**
- The blockers' two nested calls for a client with events (7d-1 CC-1: ADR-0014:9242-9243; benchmarks l.2448;
  PROGRESS.md:129): a line for 5,000 calls with a death recorded. Budget 8 s; today 2.4 s.
- `ledger_post_set`'s pooled-dimension lookup (ADR-0014:6598-6602): row 8.
- `bank_transfer_file_idx`'s three once-per-check reads (ADR-0014:5730-5731; PROGRESS.md:555) and
  `test_transfer_files_scale_integration`'s headroom (25,083 of 32,000): re-measured.
- Each one keeps its default unless its bound breaks (§4 R5, R6, R8).

**V4 — CI.**
- `ci.yml`'s `scale` step lists every `*scale_integration.py` but two (l.159-160). It gains the close-out file in its
  exclusions, and the job founder question 2 picks runs it.
- The `db` job ignores the machine in its integration step (l.111) and runs it as its own step after that step.
- The 25 × 40 run: founder question 1.

**D1 — docs close-out (§8.4; design `m2c-remittances.md:1241`).**
- **Sources:** plan §8.4 (l.2656-2671), §1.1 (l.212 D19/DOCS-1/D20).
- **COMPLIANCE:**
  - CPCE-02, -03, -07 and -08 final.
  - MAND-01, MAND-03 and FAC-06 added from plan §11 (l.2854, l.2872, l.2901); none exists today.
  - MAND-02, PROC-01 and SAISIE-01 (the seizure Ops row) checked as built.
  - OQ-96 added (plan l.2942; absent today); OQ-88 to OQ-95 and OQ-97 to OQ-99 (present) brought up to date.
  - OQ-25, -34, -35, -36, -37, -38, -41, -45, -82, -84 and -85 updated.
  - Design §21 also names TVA-01, FAC-01 to FAC-04, SEPA-01 and OQ-35 to OQ-50: all present, re-read as built.
- **ADR-0014:**
  - The status line (l.3) reads « … returns after remittance and close-out in M2c-7 (7a–7f) ».
  - The interim passages are marked superseded: l.54 (« Until M2c-7 wires the advance… »), l.163, l.167 and l.185 at
    `034d985`; the plan's l.30 is re-checked by grep for « M2c-7 » promises.
- **ARCHITECTURE:**
  - §8 (now l.239-290) is rewritten to the two funds: 5120/4710/4670/4679 ‖ 5122/4111/4112/44571/44574/4689/7060/6270/
    6780, and 419 and 7714. It covers the remittance and settlement entries, the fees booked, I8′ and I19.
  - §9 (l.291-324) covers the debit job's bookings and covers and the nightly checks. Its l.322 (« remittance +
    statement net of commission ») becomes netting only under a clause.
- **DOMAIN:** « Créances à déclarer » added (absent). « Avance au mandant », LG009, « Règlement du client »,
  « Demande de remboursement d'avance », « Avance passée en perte » and the payee kinds (present) are re-read as built.
- **CALCULATION_RULES §7** (l.243): the claw-back's place in the plan.
- **Design:** §3.2 #12 reworded (LEX-29); §13 and §21 « As built (M2c-7) ».
- **ROADMAP:** the M2c rows (l.28, l.111ff) closed.
- **Benchmarks:** the machine's budget and §8.3's rows.

**D2 — the go-live gate (§8.6, plan l.2683-2697).**
- **The code gate:** merging 7f-2 lifts the design's « no real remittance before M2c-7 ».
- **What remains, none of it code:**
  - R124-2 to the procureur and the dedicated account (CPCE-01/02, Ops; R124-7 1°);
  - counsel's OQ-45;
  - the bank's guide and a real statement with our debits (founder #15; OQ-79, -80, -81, -83, -84);
  - the switch (6b-3 Q1);
  - M3's re-runs and M3c-2's restatement cover;
  - FAC-06's written procedure (CGI 289 VII 1°, Ops with the accountant) and OQ-44's answer, both before the first real
    invoice;
  - founder Q17 to Q21;
  - counsel's OQ-92, -93, -94 and -97.
- ROADMAP records it. PROGRESS and CLAUDE.md are not edited by this workflow's builds, so the text is drafted in ADR
  « M2c-7f-2 » for the assembly to carry into PROGRESS.

**X1 — the mutants replay (§8.5, plan l.2673-2681).** The machine (and, where §8.5 says, the volume file) must kill each
of these on the final code, each one a mutant applied, the class run, then the mutant restored:
- cover off; at-booking cover off; claw-back off; VAT pro rata off; payee kind ignored; the top-up's sweeps term off;
  the LG009 trigger dropped;
- [critic] the same-run exclusion dropped; the in-flight refusal dropped; the advance item's mandate dropped; the
  requested flag ignored; the surplus refused; the debit-time re-read removed;
- [check 1] the LG003 exception widened to any `return:barred:%` key; the 4670 trigger's `settlement_withheld` branch
  removed; the shapes' 419 term dropped; the import's `label_reference` override removed; `paid_on` read from
  `remittance_run_paid_on` alone;
- [check 2] the chain events' label branch removed; rule 3 of `run_settled_on` read from
  `bank_transfer.return_entry_id`;
- added by this plan: H2's sweeps term off in `servicer_shortfall` (the machine's quiescence, after 7f-1), and H11's
  sha256 comparison removed (a rule recording one proof twice).

A mutant that survives is argued equivalent in the ADR, or the machine gains the rule that kills it.

**7f-2's size (non-test lines):**

| Part | Lines |
|---|---|
| docs (COMPLIANCE, ADR-0014 status and « M2c-7f-2 », ARCHITECTURE §8–9, DOMAIN, CALCULATION_RULES, design annotations, ROADMAP, benchmarks) | ≈ 1,000 |
| `ci.yml` (V4) | ≈ 30 |
| conditional fixes (V2 ≈ 120; V3 ≈ 60–330; what the machine finds) | 0 to ≈ 600 |
| **Total** | ≈ 1,030 to ≈ 1,650 |

The machine (≈ 1,400 lines), the oracle's extension (≈ 600) and the volume file (≈ 700) are tests.

---

## 4. Dropped or re-deferred, with why

| # | Item (source) | Decision | Why |
|---|---|---|---|
| R1 | `run_transfer_checks`' `other_debit` read (ADR-0014:11821-11823) | no copy of its 404 lines; H3's `other_debit` index serves it | PR #50's precedent: the index alone fixed the same class; a fence only if the measurement shows it still loses |
| R2 | dropping 038's planted queue branch for `d_queue`, `d_twice` (ADR-0014:6120-6121) | re-deferred: 038 kept whole | the brief keeps every 034–047c assertion; M4 records whether the state is reachable |
| R3 | a portfolio moved to another mandate between E's run and R(E) (ADR-0014:7060-7062, « 7f's property machine adds the case if one appears ») | dropped | no command moves a portfolio's mandate in M2c, so no machine rule reaches it; to be taken by the slice that adds such a command |
| R4 | a nightly alert for a request naming a reversed advance (ADR-0014:8705-8708) | not built; M6's invariant instead | its default is « none »: both reversal paths refuse under the request's lock, and an alert would read every live request each night for a state the refusals rule out |
| R5 | inlining the blockers' two nested functions (ADR-0014:9242-9243, « may inline ») | re-deferred to V3's measure | 2.4 s for 5,000 calls, under 8 s; inlining would put the payee rule, a money rule, in two places |
| R6 | `bank_transfer_file_idx` read whole three times per check under forged index statistics (ADR-0014:5730-5731) | kept; re-measured in V3 | its default is « keep »: linear, once per check |
| R7 | the machine's 200 × 60 examples in CI (plan l.2631-2632) | not in CI; founder question 1 | at the plan's 0.5–1.5 s per step, 12,000 steps take about 1.7–5 h, beyond every job's 40–45-minute limit |
| R8 | `ledger_post_set`'s pooled-dimension lookup (ADR-0014:6598-6602, « a later slice ») | re-deferred to V3 (row 8) | the ledger's posting core (a 323-line copy, LG006 re-checked) for 62–87 ms bounded by the lot cap; changed only if row 8 breaks |
| R9 | `client_advances`' list reading closed advances (ADR-0014:6900-6902) | kept | H16 moves the totals; an index on what is open needs a column the settlements would update on append-only rows |
| R10 | `run_advance_checks` (435 lines) for H15's age | not copied | the age stays the help's named day; H15's helper carries the day and the filter |
| R11 | the per-row open part in the advance and credit lists (CCS-2's lists) | kept | each list is the client's own rows (bounded in H16's test); only the totals were servicer-wide |

---

## 5. Open items never deferred to 7f (left at their recorded defaults)

Listed so the close-out shows them. None is taken here, except H22 and H23 (§2.6).

| Item | Source | Default kept |
|---|---|---|
| « Traités »' first badge of a released copy | ADR-0014:12231-12232 | keep (the decision badge beside it) |
| a return beyond its payment shown as « retour du paiement » | :12233-12235 | keep |
| « prioritaire » rows not sorted first (MB-4) | :11461-11462 | keep; order them if ops ask |
| the kept candidate chosen at import; exit (a) for another token | :11702-11706, :12087-12088 | keep |
| the client picker's 500 clients | :12089-12090 | a search field when needed |
| an own file's regenerate sheet | :10746-10747 | keep |
| a dedicated account reopened: one stale alert | :11060-11062 | keep |
| « Contrôles »' cut rows and `servicer_shortfall`'s help | :10936-10938 | keep; H2 re-checks it |
| a withheld set-off given back counted under « Sommes encaissées » (TUI-7) | :10134-10137 | a later template, with the accountant |
| giving back a set-off `set_off_after_bar` alerted | :9959-9961 (OQ-98) | a later slice, with the accountant |
| an event recorded during a running debit (CC-3) | :9692-9694 | the nightly P0 is the backstop |
| the delta pass's generic plan on a near-empty `remittance_run` | :6384-6386 | keep |
| items read « not received » conservatively (`paid_on`) | :6236-6244, :6373-6383, :6891-6894 | keep |
| a requested advance written off | :8520-8522 | withdraw first |
| a request after its payout came back (Q23) | :8709-8713 | founder Q23 (a) |
| a trop-perçu never applied to a later invoice | :8242-8244 | founder |
| a loss written off in parts | :8239-8241 | keep |
| a payment dated before the invoice it settles | :7680-7683 | keep |
| the race in the held-rows alert; a line imported onto a covered day | :5640-5644 | keep |

---

## 6. Founder questions (« 1 ok, 2 b … »; each default is what the plan builds)

1. **The machine's longer runs.** (a) 25 × 40 on manual dispatch only, in its own job (timeout 45); 200 × 60 run once
   locally on 7f-2's final code, its seed and time in the benchmarks file. (b) 25 × 40 also on every push to `main`
   (≈ +25 billed minutes each). Default (a).
2. **The close-out volume file's job.** (a) A new job `scale-closeout`, on pushes to `main` and on dispatch, in
   parallel with the other volume jobs (≈ +35 billed minutes per such run). (b) Inside `scale-payouts`, with the
   history at 10 × 5,000 lines instead of 10 × 50,000 (row 4 then compares 1 and 10 runs of 5,000). Default (a).
3. **Two page texts not named for 7f** (TUI-5's « Il sera imputé » after a mandate's end; the « Virement hors
   reversement » sentence false since 7d-2): carried into 7f-1. Default yes.
4. **7f-1's size**, if its measurements require more than ≈ 600 lines of conditional copies (§2.9). (a) One PR, over
   the target by whole-function copies only, as 7d-1, 7e-1 and 7e-3 were. (b) A 7f-1b PR before 7f-2. Default (a).

The switch question (6b-3 Q1) stays open; 7f writes no switch.

## 7. Order

1. PR #51 (7e-3) merged with its CI green, dispatched volume jobs included.
2. 7f-1: tests first (seen failing), the migration, the web and the worker. Every suite green; `scale` and
   `scale-payouts` dispatched on the branch and green; merged.
3. 7f-2, on 7f-1's main: the machine and the volume file run against the final code. Docs close-out; mutants; the gate
   text. Dispatched volume jobs green; merged.

## 8. Risks

- **The indexes in H3, H4 and H7 change plans on scale-timed paths:** the funds pass, rule 3b's per-line probe and the
  50k import. That is why 7f-1 dispatches `scale` and `scale-payouts`, and keeps the multi-column indexes beside the new
  single-column ones. The new indexes are partial on rare kinds, so the import's cost moves little; it is measured.
- **The whole copies are about 1,700 firm lines:** each is diffed against its source in the PR, and pgTAP 033–047c and
  every integration file are re-run (plan R-b).
- **7e-3's CI round may change `20261201090000`.** Any 7f-1 copy taken from it (H8's conditional
  `bank_booking_post_rows` and `transfer_line_post`) is re-copied from the merged file.
- **The machine's budget:** the PR class is pinned at 2 × 8 × 20 and ≤ 6 min, and the build measures it before the
  bound is set (F15).
