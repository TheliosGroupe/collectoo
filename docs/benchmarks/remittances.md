# Remittances benchmarks (M2c)

Targets: design `docs/design/m2c-remittances.md` §19. Each slice adds its section; transfer files
come with M2c-6 and M2c-7.

## Funds ledger (M2c-1, migration `20261111090000`)

What M2c-1 adds to the posting path: the per-entry commit check closes each fund per currency (I2′), checks the
4679 / 4689 mirror (I12) and the thirteen shapes (I3′) in one keyed query; an ALWAYS statement trigger on
`ledger_posting` upserts each client's running balance of 4670 and feeds the pending queue (one hash join of the
statement's new postings with the few 4670 accounts, through a partial index); a deferred constraint trigger refuses
a client's 4670 in debit (`LG008`). The debit job books the bank's coded charges (`bank_fee`) and the credits
carrying our `TOP…` id (`servicer_top_up`) from the statement's lines.

Scratch harnesses (not committed; the integration helpers of `worker/tests`): one camt.053 statement of N top-up
credits (each carrying the id of a `top_up` order) and N coded charges (`ACMT/MDOP/CHRG`) imported and booked by
the jobs; N entries posted in one `ledger_post_set` call inside a rolled-back transaction, times per function from
`pg_stat_xact_user_functions` (`track_functions = 'all'`); then the nightly checks.

### Result (2026-11-09, cloud session VM: 4 vCPU, 16 GB RAM, local Supabase stack, right after `supabase db reset`)

| Step | Size | Time |
|---|---|---|
| Statement imported + booked by the debit job (`process_debits`, funds lines in chunks of 2,000) | 20,000 lines (10k top-ups, 10k fees) | **13.5 s**: import 2.2 s (ingest 0.9 s), 10 chunks of 1.0–1.2 s |
| The same at 4,000 lines (2k top-ups, 2k fees) | 4,000 lines | 3.9 s (one chunk 1.5–1.6 s) |
| `ledger_post_set` of `bank_fee` entries (4 lines, both funds, no 4670) | 10,000 entries | 2.54 s (2,000: 0.96 s) |
| `ledger_post_set` of `client_advance` entries (4 lines with a 4670 line: lock by lines, trigger, queue, LG008) | 10,000 entries | 2.66–3.28 s on a fresh run (2,000: 0.91 s) |
| of which the 4670 statement trigger (running balance + 10,000 pending items) | 10,000 entries | **116–160 ms** (12–16 µs an entry) |
| of which the per-entry commit checks (I2′, I12, I3′ and the M2b checks) | 10,000 entries | 0.98–1.40 s (**0.10–0.14 ms an entry**) |
| the deferred `LG008` check (one client, its running balance) | 10,000 entries | 0.1–0.3 ms |
| Nightly checks (`run_payment_checks` with I8′, the servicer's fund, the mirror, I13, the pending queue, I19) | 20,000 bookings | 0.17–0.20 s, 0 violations |

- **Design §19 targets.** « Pending trigger + running balance: + < 0.5 s on a 50k-allocation job »: 116–160 ms per
  10,000 entries, ≈ 0.6–0.8 s for 50,000 (the allocation job posts 10,000 a transaction, so ≈ 0.15 s a job).
  « Nightly new checks < 5 s »: 0.2 s here, 1.8 s for every check over 50,000 payments (below).
- A third posting of 10,000 entries in the same session, after two rolled-back ones, took 6.0 s (the per-entry
  checks 4.3 s: the rolled-back postings' dead index entries are read until vacuum); the trigger stayed at 160 ms.
- The per-entry check stays within M2b-4's profile (0.31 ms an entry for allocation entries, which have more lines):
  I2′ and I12 are computed in the same keyed pass that I2 was.
- A first 10,000-pair run aborted on the VM's full disk (`DiskFull` in the job): the database volume held the scale
  runs' data; `supabase db reset` freed 5 GB and the run above passed.

### Scale tests after the migration (`RECEIPT_FILES=5000`, one pytest run in CI order, database not reset before)

5 passed in **536.0 s** (506.9 s for the plan-robustness migration, on a clean reset; see `payments.md`).

| Run | M2c-1 | Before (plan robustness, `payments.md`) |
|---|---|---|
| Allocation 50k (5 jobs of 10k) | 61.8 s, post 9.1–10.1 s per job | 58.7 s, post 8.6–9.5 s |
| 1,000 returns imported + linked | 22.9 s | 22.7 s |
| Nightly checks over 50,000 payments | 1.8 s (one alert: `unallocated_ageing`, the scenario's) | 1.6 s |
| Matching 50k imported + matched | 35.1 s (apply 13.6 s; the account estimated at 4 lines before it) | 32.7 s |
| Statement 50k | 22.0 s (ingest 7.1 s), re-import 5.3 s | 20.6 s (ingest 7.0 s), re-import 4.3 s |
| Receipts 5k | 25 jobs in 58.8 s (11.8 ms a receipt) | 55.2 s |
| Boarding 50k | 80–92 s | 88 s |

- The allocation post is 0.5–0.6 s a job slower, of which the trigger accounts for ≈ 0.15 s; the rest is within the
  run-to-run spread seen before (8.2–9.4 s in M2b-6) on a database not reset since the other runs. The statement and
  matching runs classify every line against the servicer's own and client IBANs (none registered here) and our ids:
  within the same spread.

## Commission engine (M2c-3 review, `remittance.commission`, pure Python)

Scratch harness of the review (not committed): 50,000 lines, 200 mandates; case 1 one marginal part a line under one
terms version; case 2 two parts a line (principal marginal with a minimum, interest by bracket) under two versions
of each mandate; case 2 + history: every (file, tier key) with a prior state. `compute` timed with its inputs hash;
`run_documents` apart. Cloud session VM, 2026-11-10, CPython 3.12 (calibration `sum(range(10**7))` ≈ 0.15 s).

| Case | Before the review fixes | After | Of which the inputs hash (before → after) | Documents |
|---|---|---|---|---|
| 1: one part, one version | 1.77 s | **1.51 s** | 0.48 → 0.25 s | 0.2 s |
| 2: two parts, two versions | 2.85 s | **2.63 s** | 0.37 → 0.26 s | 0.6 s |
| 2 + history | 4.12 s | **4.00 s** | 0.77 → 0.52 s | 0.5–0.8 s |

- After the fixes the engine does more (the state per terms version, the rounding reserve, `keep`) and is still
  faster: rate bands scaled once, the version per (mandate, day) and the rule per (version, claim type, portfolio,
  family) cached, one pass over the versions per part, slotted dataclasses, the hash streamed record by record.
- **Design §19's « commission (Python) ≈ 0.5 s » is not reachable in pure Python** for two-part lines: the rest is
  per-line interpreter work (sorting, building the parts and results). The measured budget is ≈ 1.5–2.6 s for 50k
  lines in the prepare job, outside the allocation lock (§9.4); approval never reruns the engine (§9.5). The unit
  guard `worker/tests/test_commission_scale.py` (case 2, < 15 s each for the engine and the documents; 2.6 s and
  0.9 s here) catches a regression before the M2c-7 scale run.
- **Second review** (the minimum and the rounding taken once on the file, the reserve counting the invoices the
  run's documents leave open, the re-tiering line): case 2 on the same VM, three runs each, the previous engine
  2.54–2.56 s and documents 1.07–1.21 s, now 2.84–3.04 s and 1.04–1.33 s (the VM was noisier that day: the same
  code measured 2.6–3.7 s across sessions). The reserve's search over the run's documents runs only for a key whose
  hold binds (the minimum per file on a small file); every other key takes the schedule's K in one comparison.
- **Third review** (event order, a collection undone in its own run taken out before pricing, the floor after a
  change of VAT rate): case 2 on the same VM, three runs each, interleaved: the second-review engine 2.75–3.18 s and
  documents 1.05–1.22 s, now 2.86–3.16 s and 1.11–1.38 s — no measurable change (one more O(n) pass over the run).


## Runs and invoices (M2c-4, migration `20261112090000`)

`worker/tests/test_remittance_scale_integration.py` (CI `scale` job): 50,000 files boarded from the synthetic EU loan
tape, a statement paying each by its RF reference imported, matched and allocated (the payments queue), then one run
of the client: « Préparer maintenant » (the command: the draft created and its 50,000 items reserved under the
allocation lock), the prepare job, the approval command and its job, the nightly checks. The remittance tables are
never analysed (their statistics forgotten before the run). Cloud session VM, 2026-11-10, local stack.

| Step | Volume | Measured | Design §19 target |
|---|---|---|---|
| « Préparer maintenant » (reserve under the allocation lock, the command) | 50,000 items | **1.34 s** | < 1 s |
| Prepare job: load the facts | 50,000 lines | 3.06 s | ≈ 1 s |
| Prepare job: deadlines, commission, documents, settlement plan (pure Python) | 50,000 lines | 4.61 s | ≈ 0.5 s (1.5–2.6 s measured in M2c-3) |
| Prepare job: COPY of the draft lines + header (its checks) | 50,000 lines | 2.28 s | ≈ 0.5 s |
| Approval command (compare and set, queue) | 1 run | **0.02 s** | < 1 s |
| Approval job (lines frozen, invoice with 50,000 charges, key states, entry, payout) | 50,000 lines | **7.9 s** | 2–4 s, counter held for the numbering only |
| Nightly checks of the servicer (payments + runs: I14–I18, R124-6) | 50,000 lines | **3.4 s** | < 5 s |

The same at 5,000 items: reserve 0.16 s, prepare 1.0 s (load 0.34, price 0.33, write 0.25), approval job 1.0 s.

- **Above target, accepted for now:** the reservation (1.3 s for 50,000 items: one UPDATE of the pending rows, the
  allocation lock held for its duration — allocations wait that long, once per run); the prepare job (10 s, outside
  every lock: the engine's pure-Python cost dominates, as M2c-3 measured; the loading is set-based by keys); the
  approval job (7.9 s in its own transaction: inserting the 50,000 frozen lines with their per-line guard against the
  entry's 4670 posting, 50,000 invoice charges and 50,000 key states from the draft's JSON). The invoice counter is
  locked only from the numbering to the commit (the documents' inserts): other servicers never wait, and a servicer's
  other runs wait at most that long. A client with 50,000 collections in one fortnight is far above the expected
  volumes; if needed, the charges and key states can be copied from typed draft tables instead of JSON.
- The plans rest on keys, not statistics: the draft lines are checked against the items by one keyed probe per item
  (`remittance_draft_line (run_id, ledger_entry_id)`), the line guard reads each entry's postings by key.

### After the review fixes (2026-11-10, same VM: 4 vCPU, 16 GB RAM, local stack)

The scale test now also cancels the approved run (an admin, the API's 8 s statement timeout; the review's perf#1)
and times the overview and the nightly checks with the 50,000-line draft waiting. Run alone right after
`supabase db reset`, as the figures above were:

| Step | Volume | Build | After the fixes | Design §19 target |
|---|---|---|---|---|
| « Préparer maintenant » (the command) | 50,000 items | 1.34 s | **1.28 s** | < 1 s |
| Prepare job: load / price / write | 50,000 lines | 3.06 / 4.61 / 2.28 s | 3.26 / 4.62 / 2.35 s (**10.4 s**) | ≈ 1 + 0.5 + 0.5 s |
| Overview (« À valider ») with the draft waiting | 50,000 reserved items | — | **0.05 s** | — |
| Nightly checks with the draft waiting | 50,000 lines | — | 4.4 s | < 5 s |
| Approval command | 1 run | 0.02 s | 0.04 s | < 1 s |
| Approval job | 50,000 lines | 7.9 s | **6.3 s** | 2–4 s, counter held for the numbering only |
| Nightly checks after the approval (payments + runs) | 50,000 lines in flight | 3.4 s | **4.0 s** | < 5 s |
| Cancellation (the command: credit note with 50,000 allocations, lines released, items back, tier history) | 50,000 lines | — | **3.97 s** | the API's 8 s statement timeout |

- **Cancellation:** 3.97 s at 50,000 lines, half the 8 s timeout. At 5,000 lines it went from 0.95 s on the build to
  0.40–0.43 s: the line guard became a `WHEN` clause, and the per-row foreign keys that only repeated the run's or the
  invoice's values became statement-level guards (one keyed lookup per run or pair). No queued job is needed.
- **The approval job's hold of the allocation lock** (perf#4): the lines, repricings, tier history and charges are now
  written before the lock. Instrumented at 5,000 lines it holds the lock for 0.09 s in the function plus 0.07 s of
  checks deferred to the commit, against ≈ 0.80 s before. By linear extrapolation that is ≈ 1.6 s at 50,000 lines
  (not instrumented at 50k), under the 2 s `lock_timeout` of the M2b commands but close to it. A remittance command
  that waits longer is refused `allocation_busy` (« réessayez »). The JSON is not the cost (the FK checks and the
  index work are), so no typed draft tables were added.
- **Nightly checks:** 3.4 → 4.0 s after the approval. The checks now do more: I21 over the in-flight lines of
  approved runs (legal#3), files with no terms version on E (legal#2), the unmeetable escalation, and the money
  waiting on files on the mandate's delay. With the 50,000 items back in the queue after the cancellation (12,018
  partly allocated payments): `run_payment_checks` 4.6 s, of which `run_remittance_checks` 2.4 s;
  `private.unallocated_payment_deadlines` takes 1.7 s (0.14 ms a partly allocated payment, keyed whatever the
  statistics) and `private.pending_item_deadlines` 0.78 s for the 50,000 items. That is under 5 s but close. If it
  grows, the next step is a set-based `unallocated_payment_deadlines` (one `group by` over the servicer's 4710
  postings) with fallbacks for missing statistics.
- **Approval job:** 7.9 → 6.3 s, the same work in a different order (above). Still above the 2–4 s target, in its own
  transaction; the counter is still locked only from the numbering to the commit.

**The CI `scale` job's command** (`RECEIPT_FILES=5000`, every `*scale_integration.py` in one pytest run after
`supabase db reset`, the remittance test at 50,000), on the merged review fixes: 5 passed and 1 failed in 987 s
(16 min 27 s; the CI job's budget is 30 min). The failure was the M2b allocation test. It paid its files on fixed
dates from 2026-10-05 under a mandate that has terms, and nothing remits them. Since legal#2 those collections are
held to one month, so on 2026-11-10 they were a real `remittance_deadline_breached`. The test now dates its
payments and returns a few business days back and keeps `violations == 0`. Run again alone: passed in 259 s
(allocation 80.8 s, 1,000 returns 29.4 s, nightly checks over 50,000 payments 4.7 s with no code; 1.8 s in M2c-1,
before the remittance checks: `run_remittance_checks` 2.3 s of 4.5 s, `unallocated_payment_deadlines` 1.6 s over
11,715 partly allocated payments). In the CI-order run, the database already holding the allocation and matching
tests' 50,000-file tenants and the receipts test's 5,000, the remittance test measured: reserve 1.33 s, prepare 12.1 s (4.07 / 5.44 / 2.37), approval job 6.7 s, nightly checks
5.7 s (6.5 s with the draft waiting; over the 5 s target in that crowded state), overview 0.05 s, cancellation 4.00 s.

### Review fixes, round 2 (2026-11-10, same VM: 4 vCPU, 16 GB RAM, local stack)

The deadline CTEs of the three readers are now `materialized` (perf#0, round 2: one deadline per distinct (E, delay)
whatever the statistics), the approval holds unmeetable lines to one month, the cancellation's corrective invoice
bears its own VAT, and the nightly checks add `invoice_overdue`. Each scale test run alone right after
`supabase db reset`:

| Step | Volume | Round 1 | Round 2 | Design §19 target |
|---|---|---|---|---|
| « Préparer maintenant » (the command) | 50,000 items | 1.28 s | 1.47 s | < 1 s |
| Prepare job: load / price / write | 50,000 lines | 3.26 / 4.62 / 2.35 s (10.4 s) | 3.39 / 4.64 / 2.36 s (**10.6 s**) | ≈ 1 + 0.5 + 0.5 s |
| Overview (« À valider ») with the draft waiting | 50,000 reserved items | 0.05 s | 0.05 s | — |
| Nightly checks with the draft waiting | 50,000 lines | 4.4 s | **3.7 s** | < 5 s |
| Approval command / job | 50,000 lines | 0.04 / 6.3 s | 0.03 / **6.1 s** | < 1 s / 2–4 s |
| Nightly checks after the approval | 50,000 lines in flight | 4.0 s | **2.7 s** | < 5 s |
| Cancellation (the command) | 50,000 lines | 3.97 s | **4.12 s** | the API's 8 s statement timeout |
| `test_remittance_scale_integration.py` | | | 1 passed in 245 s | |
| `test_allocate_50k_payments`: allocation (5 jobs of 10,000) | 50,000 payments | 80.8 s | **78.0 s** (post 11.9–12.6 s a job) | — |
| … 1,000 returns imported + linked | | 29.4 s | 29.8 s | — |
| … nightly checks over 50,000 payments | 11,956 partly allocated | 4.7 s | **3.5 s**, no code | < 5 s |
| `test_allocate_50k_payments` | | 259 s | 1 passed in 245 s | |

- The nightly checks are 0.7–1.3 s faster: `unallocated_payment_deadlines` and `pending_item_deadlines` no longer
  compute a deadline per payment or item when their tables have no statistics (the scale harness's state), so the
  estimate the previous section flagged as « under 5 s but close » now has room.
- The reservation (1.28 → 1.47 s) and the cancellation (3.97 → 4.12 s) moved within the run-to-run spread seen before
  (1.28–1.34 s, 3.97–4.00 s); neither path changed but the corrective invoice's VAT and period (one row per mandate
  and rate) and the late lines' month (computed once per distinct E, for unmeetable lines only).

## Documents (M2c-5, migration `20261113090000`)

What M2c-5 adds after an approval: the `documents` job builds the statement's payload in SQL from the run's frozen
lines (keyed lookups per line: file, borrower, mandate, portfolio, the entry's 1100 postings, the notification, the
invoice, the receipt, the late approval), renders its CSV (one row per line) and its PDF (summary, natures, one row
per file up to 2,000), renders each invoice's PDF from its frozen payload, uploads the files and records them.
Same VM (4 vCPU, 16 GB RAM, local stack), 2026-11-10.

| Step | Volume | Time | Design §19 target |
|---|---|---|---|
| Statement payload built in SQL (`remittance_statement_prepare`) | 50,000 lines, 50,000 files | **6.42 s** | — |
| Statement CSV (Python) | 50,000 rows (14.6 MB) | **1.60 s** in the job, 1.33 s in the unit guard | < 2 s |
| Statement PDF, 50,000 files (no per-file table: the CSV's SHA-256 names the detail) | 50,000 files | 1.50 s | — |
| Statement PDF with the per-file table (`test_statement_scale.py`, pure Python) | 2,000 file rows | **1.55 s** (1.4 MB) | < 15 s |
| Invoice PDF | 1–2 pages | ≈ 10 ms (the receipts' renderer: 14.3 ms a receipt with its upload) | ≈ 10 ms |
| The documents job (build, render, upload, record) | one 50,000-line run | 9.67 s render + store, record 0.03 s | — |
| Approval job then documents job (`drain()` of the scale test) | 50,000 lines | 15.9 s (approval ≈ 6.2 s, as M2c-4) | approval 2–4 s |

`test_remittance_scale_integration.py` now asserts the statement is drawn with its 50,000 lines and the run's gross,
and the invoice's PDF recorded; the other figures of the run are M2c-4's: « Préparer maintenant » 1.34 s, prepare
11.6 s (load 3.80, price 5.35, write 2.29), approval command 0.02 s, nightly checks 4.1 s (4.7 s with the draft
waiting), overview 0.04 s, cancellation 3.74 s.

- The payload's SQL build is the documents job's largest step (≈ 0.13 ms a line): one pass over the run's lines with
  keyed laterals, then the per-file and per-nature aggregates over a temporary table. It runs after the approval
  committed, outside every lock but the servicer's documents lock, so it never holds up allocations or approvals.
- The payload of a 50,000-line run is ≈ 10 MB of jsonb (lines as arrays in `line_columns` order), stored once.

### Scale tests after the migration (`RECEIPT_FILES=5000`, the CI scale job's command, right after `supabase db reset`)

6 passed in **938.6 s**.

| Run | M2c-5 |
|---|---|
| Allocation 50k (boarded 96 s, imported + matched 33.0 s) | allocated in 80.2 s; 1,000 returns imported + linked 30.7 s; nightly checks over 50,000 payments 3.5 s, no code |
| Statement 50k | 43.3 s imported + matched (ingest 9.3 s); history 13,500 credits 11.3 s |
| Receipts 5k | 25 jobs in 71.6 s (14.3 ms a receipt) |
| Remittance run 50k (with its documents) | above |
| Boarding 50k | 115 s (commit 31.4 s, confirm job 34.4 s) |

### After the review fixes (M2c-5 review, integrated; 2026-11-10, same VM: 4 vCPU, 16 GB RAM, local stack)

The review isolates each document under its own savepoint (K4: the invoice PDFs in chunks of 50, each statement
alone, a failed upload's objects removed), builds section 6 as of K (figures#2: payments created and matched by K,
their 4710 postings by K), names the credit note of a reversal line by a keyed lateral (figures#5), reads the run
`for share` (figures#6), and records the statement's gross, net and drawn status on its row (perf#4). The CI `scale`
job's command (`RECEIPT_FILES=5000`, every `*scale_integration.py` in one pytest run, right after `supabase db reset`):
**6 passed in 933.9 s** (15 min 34 s; the CI job's budget is 30 min).

| Step (the 50,000-line run's documents job) | Volume | Build | Review fixes | Design §19 target |
|---|---|---|---|---|
| Statement payload built in SQL (`remittance_statement_prepare`) | 50,000 lines, 50,000 files | 6.42 s | **6.51 s** | — |
| Statement CSV (Python, text cells neutralised) | 50,000 rows | 1.60 s | **1.30 s** | < 2 s |
| Statement PDF (no per-file table above 2,000 files) | 50,000 files | 1.50 s | **1.81 s** | — |
| The documents job (statement + invoice PDF, uploads, records; 0 failed) | one 50,000-line run | 9.67 s + record 0.03 s | **10.04 s** | — |
| Approval job then documents job (`drain()`) | 50,000 lines | 15.9 s | **16.2 s** | approval 2–4 s |

The rest of the remittance run in the same pytest session: « Préparer maintenant » 1.25 s, prepare 13.8 s (50,000
lines: load 3.62, price 5.33, write 2.34 s; then the 5,000-line run), approval command 0.02 s, nightly checks 4.1 s
(5.1 s with the draft waiting, now with `remittance_document_failed` and `remittance_document_missing`), overview
0.05 s, cancellation 3.67 s.

| Run (same pytest session) | Review fixes | Build |
|---|---|---|
| Allocation 50k (boarded 96 s, imported + matched 31.3 s) | allocated in 75.4 s (post 11.5–12.7 s a job); 1,000 returns 27.5 s; nightly checks over 50,000 payments 3.3 s, no code | 80.2 s; 30.7 s; 3.5 s |
| Statement 50k | 43.1 s imported + matched (ingest 8.8 s); history 13,500 credits 11.1 s | 43.3 s (ingest 9.3 s); 11.3 s |
| Receipts 5k | 25 jobs in 71.7 s (14.3 ms a receipt) | 71.6 s |
| Boarding 50k | 116 s (commit 31.6 s, confirm job 34.9 s) | 115 s |

- The savepoints cost nothing measurable: the job is 0.4 s slower on one run, within the spread of its three steps
  (the PDF +0.3 s, the CSV −0.3 s, the SQL build +0.1 s). The section-6 rewrite starts from the client's candidate
  payments (those holding money now, refunded or returned since K, or with entries pending since K) and the build
  stayed at ≈ 0.13 ms a line (6.51 s for 50,000).
- The 5 s nightly-check target is exceeded once, with the 50,000-line draft waiting in this crowded database
  (5.1 s; 6.5 s in the M2c-4 round-1 CI-order run); 4.1 s after the approval.

## Manual credit note (M2c-5b, migration `20261114090000`)

The remittance scale run (`worker/tests/test_remittance_scale_integration.py`, CI `scale` job's command, right after
`supabase db reset`; 2026-11-10, same VM: 4 vCPU, 16 GB RAM, local stack), with the approval job writing each key
state's waiver and what its credits absorbed, the cancellation clearing and restoring waivers, and the nightly checks'
new I22 over the 50,000 keys the approval wrote:

| Step (50,000 lines) | M2c-5 (review) | M2c-5b | M2c-5b review fixes |
|---|---|---|---|
| « Préparer maintenant » (the reserve) | 1.25 s | 1.27 s | **1.22 s** |
| Prepare job (load, price, write) | 13.8 s (3.62, 5.33, 2.34) | 10.5 s (3.13, 4.77, 2.39) | **9.9 s** (2.97, 4.43, 2.33) |
| Approval job then documents job | 16.2 s | 16.3 s (statement build 6.24 s, CSV 1.37 s, PDF 1.76 s) | **16.0 s** (documents 9.68 s: build 6.10 s, CSV 1.34 s, PDF 1.83 s) |
| Nightly checks after the approval (I22 over 50,000 keys; `credit_refund_owed`) | 4.1 s | 3.7 s | **3.6 s** (3.1 s with the draft waiting) |
| Cancellation (command) | 3.67 s | 4.15 s | **3.84 s** |
| `test_remittance_scale_integration.py` | | | 1 passed in 241.6 s |

- The engine reads one more column per earlier charge (`commission_waiver` by its (invoice, file, tier key) index:
  empty here) and simulates a key's documents once more only when the key holds a waiver.
- I22 reads, per key changed since the previous check run, its charges by `(account_id, tier_key)`, each charge's
  credits and waivers by their indexes (`private.commission_key_open`); keys are listed from
  `remittance_key_state (organization_id, created_at)`. The check stays under the 5 s target.
- Review fixes (integrated branch `m5b-integrated`, run alone right after `supabase db reset`, same VM): the prepare
  reads `private.remittance_history_seq` first (one keyed read, F5) and loads each reversal's `Retake` caps only from
  cancelled runs that credited or absorbed something for it (none here); the approval's refusal reads the run's
  `commission_blockers` (`engine_error`; removed by the review's round 2, ADR-0014); `credit_refund_owed` reads the
  servicer's credit notes by `commission_invoice_credit_note_idx` (none here); the cancellation's waiver restore reads
  the run's absorbed rows by `commission_waiver_run_idx` and each absorbing invoice and corrective invoice by key (none
  absorbed here); every credit note's `ht_after` / `vat_after` read its corrected invoices' credit notes by
  `original_invoice_id` (the run has none). No step moved beyond run-to-run noise.
- Review round 2 (`m5b-fix2`): the approval no longer reads `commission_blockers` for a refusal; the prepare reads each
  reversal's takes from every cancelled run that credited or absorbed something for it (its credit allocations and
  `absorbed` waiver rows by `entry_id`, each run's corrective invoices by key) — none here, so the timings above stand
  (not re-measured).
- `issue_credit_note` itself is keyed by the invoice: its charges by the primary key, each key's credits and waivers
  and latest state by their indexes; a credit note on an invoice charging 50,000 files is one plan and two inserts of
  50,000 rows (not measured at that size: an invoice that size is a scale artefact, not a correction ops make by hand).

## Transfers and files (M2c-6a, migration `20261115090000`)

`worker/tests/test_transfer_files_scale_integration.py` (2026-11-11, cloud session VM: 4 vCPU, 16 GB RAM, local stack,
`TRANSFER_FILE_SIZE=5000`): 5,000 unidentified credits on one statement, each refunded in the file (5,000 `RFD`
transfers ordered), the statistics of `bank_transfer`, `refund_request`, `transfer_file` and `transfer_file_item`
forgotten first (the state CI meets).

| Step (5,000 transfers) | Time |
|---|---|
| 5,000 `request_refund` in file mode (one statement, the transfers created) | 16.9 s (3.4 ms each) |
| « Générer le fichier » (command: a hold reason per transfer, the cash check, the sweep, 5,000 items, the transfers `in_file`, the job queued) | **1.69 s** |
| `transfer_file` job: write 0.69 s (lxml), structural check, upload 0.06 s, record | **0.90 s** (2.6 MB) |
| `pain001.check` of the 5,000-transaction file alone | 0.46 s |
| Download (command: the runs locked, the download recorded) | 0.06 s |
| Cash check with the 5,000 in flight (each one's debit probed by its RFD id, then by PmtInfId) | **0.13 s** |
| Cash check once a statement shows their 5,000 debits | 0.09 s |
| « Virements » (`transfer_overview`) with the file and its 5,000 transfers | 0.14 s |

- Design §19's target « pain.001 ≤ 200 transfers < 0.2 s »: 500 transfers take 0.22 s for the command and 0.10 s for
  the job (writing 0.06 s); the writer is linear (≈ 0.14 ms a transaction).
- The command reads each candidate's hold reason by keyed lookups (its run, the client's running balance, the payout
  blockers): ≈ 0.3 ms a transfer; payouts cost a little more than refunds (one more read of the payout account and of
  the client's other runs in flight).
- The cash check probes each transfer in flight by `(bank_account_id, end_to_end_id)` on the new partial index of
  debits, then its item by `(file_id, transfer_id)` and the batch debits by `(bank_account_id, payment_info_id)`:
  keyed whatever the statistics (`enable_seqscan = off`).

### The CI scale job after the migration (`RECEIPT_FILES=5000`, `tests/*scale_integration.py` in one run, right after `supabase db reset`)

7 passed in 948 s (15 min 48 s). The 5,000-transfer file in that run: generation 1.80 s, job 0.89 s (write 0.60 s),
check 0.41 s, download 0.04 s, cash check 0.13 s (0.09 s once debited), « Virements » 0.14 s.

| Step (50,000 lines, `test_remittance_scale_integration.py`) | M2c-5b review fixes (run alone) | M2c-6a (CI order) |
|---|---|---|
| « Préparer maintenant » (the reserve) | 1.22 s | 1.30 s |
| Prepare job | 9.9 s | 12.1 s (3.71, 5.86, 2.35) |
| Approval job then documents job | 16.0 s | 16.4 s |
| Nightly checks after the approval | 3.6 s | 5.6 s (5.2 s with the draft waiting) |
| « Générer le fichier » of the run's payout (command; the 50,000-line statement's closing balance) | — | **0.05 s** |
| Cancellation (command; its file, not downloaded, superseded) | 3.84 s | 3.63 s |

- The nightly figure is the whole `run_payment_checks` in CI order (the earlier scale tests' rows in the same
  database); the transfers' checks alone (`private.run_transfer_checks`, keyed) take 7 ms on that data, the runs'
  checks (`private.run_remittance_runs_checks`, unchanged) 3.1 s.

### M2c-6a review fixes (integration, 2026-11-11)

Same VM, `RECEIPT_FILES=5000`, right after `supabase db reset`, the two scale tests in one run
(`test_transfer_files_scale_integration.py` then `test_remittance_scale_integration.py`: 2 passed in 283 s).

| Step (5,000 transfers) | M2c-6a | Review fixes |
|---|---|---|
| 5,000 `request_refund` in file mode | 16.9 s | 18.2 s (also the SEPA and EPC tests, review T3) |
| « Générer le fichier » (command) | 1.69 s | **1.80 s** (1.93–2.52 s over three more cold runs; the EPC and SEPA holds, `private.transfers_in_flight`) |
| `transfer_file` job (write) | 0.90 s (0.69 s) | 0.87 s (0.65 s) |
| `pain001.check` of the file | 0.46 s | 0.51 s (one tamper check more per field) |
| Download (command) | 0.06 s | **0.21 s** (0.23–0.29 s): the first download now re-runs, under the generation's locks, every transfer's hold reason, the date rule and the cash check (review T2) |
| Cash check, 5,000 in flight | 0.13 s | **0.12 s** — 0 bank lines read |
| Cash check once their 5,000 debits are on a statement | 0.09 s | **0.11 s** (0.08–0.13 s) — 5,000 lines read, one per transfer |
| « Virements » (`transfer_overview`) | 0.14 s | 0.12 s |

- The cash check once the debits are seen first measured **1.8–2.2 s** after the review fixes, in three of five
  cold runs (0.07 s once the statistics caught up): each transfer's own-debit probe stated `direction = 'debit'`,
  which made the account's unposted-lines index (partial on the direction) usable with no condition, and with the
  statistics lagging the import the planner scanned it in full for every transfer — 12,502,500 lines read
  (auto_explain: a full scan of `bank_transaction_unposted_idx` per probe, up to 5,000 lines removed by its filter). The probes now hold
  only the end-to-end id, in a subquery that cannot be pulled up, on indexes led by the id and not partial on the
  direction or kind (ADR-0014 « M2c-6a review fixes », Integration); the scale test asserts the lines read (at most
  one per transfer).

| Step (50,000 lines, `test_remittance_scale_integration.py`, after the transfer file test) | M2c-6a (CI order) | Review fixes |
|---|---|---|
| « Préparer maintenant » (the reserve) | 1.30 s | 1.53 s |
| Prepare job | 12.1 s | 11.4 s (3.38, 5.32, 2.45) |
| Approval job then documents job | 16.4 s | 17.5 s |
| Nightly checks after the approval | 5.6 s | 4.3 s (3.5 s with the draft waiting) |
| « Générer le fichier » of the run's payout | 0.05 s | 0.05 s |
| Cancellation (its file, not downloaded, superseded) | 3.63 s | 3.81 s |

### M2c-6a review fixes, round 2 (2026-11-11)

Same VM, one run of `test_transfer_files_scale_integration.py` (5,000 transfers) after the integration suite on a
reset stack: refunds asked 18.9 s; « Générer le fichier » **2.00 s** (each payout's and refund's hold reason now
probes its own debit by end-to-end id, `already_debited`, review round 2 D4 — one keyed probe per transfer, as the
cash check's); job 1.00 s; structural check 0.44 s; download 0.25 s; cash check 0.12 s in flight (0 bank lines
read), 0.08 s once debited (5,000 read, one per transfer); « Virements » 0.12 s.

## Debit bookings (M2c-6b-1, migration `20261116090000`)

What M2c-6b-1 adds to the debit job: the M2b pass (refunds' RFD links, now also a single-refund PmtInf's batch line)
is followed by the funds pass in its own message and transaction, which reads the account's lines of ours
(`private.bank_booking_candidates`: per-branch limited unions, each transfer read once as a composite row) and books
payouts, sweeps, returns, fees, top-ups and each payout's run settlement (one `ledger_post_set` call, the set
settlement, the cover advances); the nightly checks add I19 signed by the 5120 postings, I20 `transfer_booked_once`
and the bookings' alerts. Plan targets (§1.4): each funds chunk < 60 s and the job < 120 s (the queue's visibility
timeout is 300 s), each transfer read by key a bounded number of times, 200 RMT/SWP lines ≈ 1 s, the nightly checks
< 5 s with 5,000 booked transfers and 50 cancelled.

### Result (2026-11-11, cloud session VM: 4 vCPU, 16 GB RAM, local stack right after `supabase db reset`; the scale
job's `test_transfer_files_scale_integration.py`, the new tables' statistics forgotten first)

| Step | Size | Time |
|---|---|---|
| The debit job over a statement of the file's debits: the M2b pass links each to its refund (the funds pass, in its own message, reads none of these lines: an RFD line is the M2b pass's) | 5,000 RFD debits | **9.8 s**; 10,000 `bank_transfer` rows read over both passes (2 per transfer: keyed) |
| Nightly checks with I19, I20 and the bookings' alerts over them | 5,000 booked | **1.7 s**, 0 violations |
| Generation (command) / job / download (command) of the 5,000-transfer file (unchanged from M2c-6a) | 5,000 transfers | 2.36 s / 0.95 s / 0.75 s |
| Cash check with 5,000 in flight / once their debits are seen | 5,000 | 0.11 s (0 lines read) / 0.08 s (5,000 read) |

- This row times the M2b pass only (review T6): `private.bank_booking_candidates` selects none of the RFD lines, so the
  funds pass read 0 lines here; payouts booked by the funds pass are measured below. The scale test asserts the job
  under 120 s, the checks under 5 s (plan §1.4; it said 30 s before the review), and at most 3 reads of
  `bank_transfer` per transfer over all passes; every refund executed with its `cash_out`.

### Review fixes (2026-11-12): 5,000 payouts booked by the funds pass (`test_debit_bookings_scale_integration.py`)

Same VM, the worker agent's own local stack right after `supabase db reset`, the test run alone (twice: 837.8 s, then
the committed version: 2 passed, 1 xfailed in 872.2 s). The figures below are the committed run's, the first run's in
brackets where they differ (review round 2, P4: this paragraph quoted the first run's fixture figures as the
second's). The fixture (review T6): 5,050 clients created set-based as pgTAP 035's (each its mandate
with complete terms, 15 % flat with netting, a confirmed payout account and one file with its RF reference and opening
balance) 45.3 s (43.1 s); a statement paying each file imported, matched and allocated 30.7 s (30.0 s); 5,050 runs
requested (500 commands a transaction), prepared by four consumers 127.8 s (121.3 s; 25 ms a run), approved by 26
commands 5.3 s (4.5 s) and their jobs 582.6 s (559.1 s; 115 ms a run, serialised on the servicer's allocation and remit
locks; the documents jobs they queue are taken off unrun); 50 runs cancelled before any file; « Générer le fichier » of
the 5,000 payouts 3.09 s (2.89 s); the file written and downloaded. The statistics of `bank_transfer`, `transfer_file_item`, `bank_line_booking`,
`client_advance` and `remittance_run` are forgotten before the bookings.

| Step | Size | Time | Rows read (keyed, per transfer) | Plan §1.4 |
|---|---|---|---|---|
| (b) The file's PmtInf debited as one batch line (no end-to-end id): the funds pass, one transaction (rolled back) | 5,000 members | **31.3 s**; 5,000 bookings | `bank_transfer` 65,050 of which 5,050 by a sequential scan (12 keyed), `transfer_file_item` 30,000 (6), `bank_line_booking` 15,000 (3) | < 60 s |
| (a) A statement of the file's 5,000 debits, one line per RMT end-to-end id: the import | 5,000 lines | 1.2 s (1.1 s) | | |
| … the debit job: the M2b pass, then the funds pass in three messages | 5,000 payouts | **22.6 s** (22.9 s): chunks of 2,000, 2,000 and 1,000 lines in 9.2, 9.0 and 4.2 s (9.2, 9.1, 4.4 s) | `bank_transfer` 65,153 (65,162) of which 15,150 by sequential scans (10 keyed), `transfer_file_item` 10,000 (2), `bank_line_booking` 15,000 (3) | each chunk < 60 s; < 120 s |
| … 200 RMT lines in one funds pass | 200 | not measured in these runs (an estimate of ≈ 0.9 s from the chunks' rate stood here; measured in round 2, below) | | ≈ 1 s |
| Nightly checks with the 5,000 booked payouts and the 50 cancelled transfers (I19, I20, the bookings' alerts) | 5,050 transfers | **1.05 s** (1.12 s), 0 violations | | < 5 s |

Each payout booked once (5,000 bookings of 5,000 distinct transfers), each run `booked` on the debit date with its
`client_settlement`. The test asserts the targets and the keyed reads per transfer (at most 16 of `bank_transfer`, 4 of
`transfer_file_item` — 8 for a batch line's member — and 4 of `bank_line_booking`).

Two plans that rest on the statistics (worker report to the SQL side, ARCHITECTURE §4):

- `private.post_bank_bookings`' batch rule (`update pg_temp._bb … from (select … group by …) w`): with a few hundred
  members the planner re-evaluates the grouped members' subquery once per row of the line — at 150 members 23,250 reads
  of `transfer_file_item` and about 25,000 of `bank_transfer` for one line (158,106 buffer hits in that one statement,
  `pg_stat_statements`), at 200 members 41,000 and 42,696 (n²); at 5,000 it hashes it (linear, above). A
  `MATERIALIZED` CTE would make it independent of the estimates.
- `private.bank_booking_post_rows`' `update public.bank_transfer … from pg_temp._bb …` (status `booked`) is a hash join
  over a sequential scan of `bank_transfer` once its statistics are forgotten (auto_explain), once per chunk: 15,150
  rows = 3 chunks × every transfer in the database. The test records it (a non-strict xfail: autovacuum may restore the
  statistics during the run).

The fixture makes this the longest scale test (≈ 14 min, of which ≈ 11.5 min the 5,050 runs through the jobs): with
the CI scale job measured at 15 min 48 s before and its 30-minute timeout, the job needs a longer timeout or this test
its own job (done at the integration: `scale-payouts`, below). `PAYOUT_FILE_SIZE` changes the size.

The two other scale tests the review changed, run next in the same database (`RECEIPT_FILES=5000`: 2 passed in
314.6 s):

| Step | Time |
|---|---|
| `test_transfer_files_scale_integration.py`: the debit job over the 5,000 RFD debits (the M2b pass) / the nightly checks, now held to < 5 s | 10.1 s / **1.8 s** |
| `test_remittance_scale_integration.py` (50,000 lines), after the cancellation (3.96 s): the items in a new run, prepared and approved (the approval's documents job included) | 30.3 s (prepare 12.1 s: load 4.96, price 5.70, write 2.24) |
| … its payout filed, downloaded, its debit (its RMT id, `book_payout`) imported and booked by the debit job: the remittance and the 50,000-line run's settlement | **1.0 s** (the funds pass 0.2 s: one booking) |
| … the nightly checks with that run booked (I19, I20 clean) | 4.8 s, 0 violations (4.4 s after the first approval) |

### Integration of the review fixes (2026-11-12, same VM, the main stack, each run right after `supabase db reset`)

The three fix branches merged (the database's K1–K6, the worker's K2/K5/T1–T8, the pages' texts); since then the CI
`scale` job runs every scale test but this one, which has its own job `scale-payouts` (40-minute timeout).

`scale-payouts` — `test_debit_bookings_scale_integration.py` alone, with the final migration (the index below):
**2 passed, 1 xfailed** (the non-strict record of the sequential reads) in 815.2 s; before the index, 802.9 s with the
figures in brackets.

| Step | Size | Time | Rows read (of which by sequential scans) |
|---|---|---|---|
| Fixture: clients / collections / runs requested, prepared (109.7 s) and approved (commands 4.5 s, jobs 552.1 s) / « Générer le fichier » | 5,050 runs | 44.2 s / 20.5 s / 680.7 s / 3.23 s | |
| (b) The PmtInf as one batch line, the funds pass (rolled back) | 5,000 members | **29.5 s** (31.2 s) | `bank_transfer` 65,050 (5,050), `transfer_file_item` 30,000 (0; 5,000 in the earlier run), `bank_line_booking` 15,000 (0) |
| (a) 5,000 RMT lines: import / the debit job (chunks of 2,000, 2,000, 1,000) | 5,000 payouts | 1.1 s / **21.6 s** (22.8 s): 8.8, 8.4, 4.2 s | `bank_transfer` 65,150 (15,150), `transfer_file_item` 10,000 (0), `bank_line_booking` 15,000 (0) |
| Nightly checks, 5,000 booked + 50 cancelled | 5,050 transfers | **1.10 s** (1.07 s), 0 violations | |

`scale` — the CI command (`RECEIPT_FILES=5000`, every other `*scale_integration.py` in one run): **6 passed, 1 failed**
in 989.6 s (16 min 31 s), then, with the index below, 996.2 s (16 min 38 s), the same failure:

| Step | Time |
|---|---|
| `test_remittance_scale_integration.py` (50,000 lines): the items re-run, prepared and approved / its payout filed, downloaded, debited and booked (the funds pass 0.2 s) / the nightly checks with that run booked | 30.9 s / **0.8 s** / 6.3 s (then 30.2 s / 1.0 s / 5.9 s) |
| `test_transfer_files_scale_integration.py`: the debit job over the 5,000 RFD debits (15,000 `bank_transfer` rows read, three per transfer since K1 reads the request's transfer) / the nightly checks | 11.9 s / **7.6 s** — then 12.2 s / **5.5 s**: over the < 5 s the review set (T6), **red** |

The refund file test's nightly checks, measured right after a scale run's writes (the 50,000-line run, or the payouts'
fixture), took 5.0 to 7.6 s in seven runs of nine (0.3 and 0.5 s in the other two; 0.2 to 0.4 s alone after a reset). `pg_stat_statements`
(nested statements tracked) put the time in `private.run_payment_checks`' one checks statement reading about 9,600
blocks not in shared buffers, cold after the previous run's 700 MB of writes; not in `private.refund_debit_links`
(5,000 calls, 11 ms in all). Five of those reads were sequential scans of every servicer's ledger accounts (no index
led by the organisation held the claim items' accounts: 749,680 rows read for a servicer of two):
`ledger_account_org_book_idx (organization_id, book)` (migration `20261116090000`) makes them keyed — 0 rows read by
sequential scans, which the test now asserts — but the remaining cold reads (`ledger_entry` ≈ 3,150 blocks,
`bank_transaction` ≈ 1,670 by a sequential scan, `ledger_posting` ≈ 1,300) keep the checks above 5 s in the CI order.
Left open (integration report): a plan-robustness pass over the nightly checks' remaining unkeyed reads, or the
founder's call on this test's bound (30 s before the review).


### M2c-6b-1 review fixes, round 2 (2026-11-12, same VM: 4 vCPU, 16 GB RAM, a second local stack beside the main one)

All runs on a second Supabase stack (ports 553xx) while another agent's test suites ran on the main stack: the VM was
shared, so wall times are noisier and somewhat higher than in the sections above (the 5,050 runs' fixture took
724–868 s here against 681–724 s before). Each figure below says what it was measured on. The scratch scripts named
(`mut_p1`, `mut_p2`, `bounds_probe.py`, the comparison of the two functions) are in the session's scratch area, not
the repository.

**P1 — the batch rule, linear.** `private.post_bank_bookings`' batch rule is now four `MATERIALIZED` steps (the lines,
the rows each holds, the members of each line's PmtInf by keyed laterals, the verdict per line). As one grouped
subquery joined to the line's rows it was re-run once per row. New test
`test_a_batch_line_of_200_members_reads_each_member_a_bounded_number_of_times` (200-payout fixture, the funds pass in
one transaction, rolled back, its own `pg_stat_xact_user_tables`):

| 200-member batch line, one funds pass | `bank_transfer` rows read | `transfer_file_item` | time |
|---|---|---|---|
| before (the build's rule, mutant `mut_p1`: the old rule in the new migration) | 42,400 | 41,000 | 1.08 s |
| after | **2,600** (13 a member) | **1,200** (6) | 0.56–0.64 s |

The bound is 16 and 8 reads a member (+ 50); red before, green after. At 5,000 members the reads are 65,000 / 30,000 /
15,000 (`bank_line_booking`), none by a sequential scan.

**P2 — the transfers booked, by key.** `private.bank_booking_post_rows` updates the transfers booked or returned
through `x.id = any (array(…))` (the index's condition) and joins their entries by id. Each measured pass of the
payout test now forgets the statistics of `bank_transfer`, `transfer_file_item`, `bank_line_booking`,
`client_advance` and `remittance_run` right before it and keeps them forgotten (autovacuum off on them meanwhile), so
the bounds hold in that state, not by chance; `test_the_funds_pass_reads_no_table_of_transfers_in_full` is strict (no
xfail): no table of transfers read by a sequential scan beyond a tiny table (≤ 1,000 rows: the 200-payout fixture's,
alone in a fresh database, where a sequential scan is the planner's right choice).

| Funds pass, statistics forgotten | `bank_transfer` rows read by sequential scans |
|---|---|
| (a) 5,000 RMT lines, 3 chunks — before (integration, 9537d10) | 15,150 (3 × every transfer) |
| (a) — after | **0** (55,000 keyed, 11 a transfer) |
| (b) one 5,000-member batch line — before / after | 5,050 / **0** |
| 200 RMT lines, a database holding 5,450 transfers — mutant `mut_p2` (the old update only) / after | 5,650 / **0** |

**P4 — 200 RMT lines in one funds pass** (plan §1.4 « ≈ 1 s »), `test_200_rmt_debits_in_one_funds_pass`: the
statement of the 200 payouts' debits imported, the debit job run; the funds pass (one message, the job's log to 0.1 s):
0.6, 0.8, 0.9 and 0.5 s (four runs with this migration; the whole job 0.64–1.07 s), 11 keyed `bank_transfer` reads a
transfer, none by a sequential scan. Asserted ≤ 2.0 s (twice the worst run). An SWP line takes the same rules and
reads (its transfer by its id); the sweep is ordered only once payouts are booked, so the fixture has none.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` alone, right after a reset), final
migration (2afccb5): **5 passed** in 918.8 s. Fixture 59.0 s / 24.6 s / 724.0 s (prepare jobs 125.1 s, commands 4.7 s,
approval jobs 585.7 s) / « Générer le fichier » 3.19 s; (b) the batch line **31.8 s** (29.5–31.3 s before; most of
its time is the posting — `post_run_settlements` 14.5 s, `ledger_post_set` 6.7 s —, and about 5.7 s the re-check's
statements over the line's 5,000 rows, quadratic: round 2's verifier, P1, in an emulation; linear since review round 3,
below); (a) the debit job
**21.6 s**, chunks 8.5, 9.0 and 4.0 s; the nightly checks with 5,000 booked payouts and 50 cancelled transfers
**1.12 s** (1.05–1.12 s before), 0 violations, every table read by key or, where the servicer owns the table, by a
sequential scan (`payment` 5,250 rows of which its own 5,050). The first run with ac15bd4 (the VM busier: fixture
868 s, (b) 41.1 s, checks 1.26 s) failed only the 200-member test's then-strict « no sequential scan » on a table of
200 transfers, since tolerated up to 1,000 rows. On one database, alternating the build's `run_payment_checks` and
this one (six calls each, warm): 1.21 s and 1.13 s on average.

**P3 — the nightly checks, keyed.** Profiled first (the build's SQL, the CI scale job's command in its order, each
`run_payment_checks` call of the tests under auto_explain ANALYZE BUFFERS, nested statements, its transaction's
`pg_stat_xact_user_tables`):

- The refund-file servicer (5,000 refunds): 8.0 s, 7.7 s of it in one place — the payments joined to their grouped
  entries (`pos`) by a nested loop, the statistics not knowing the servicer's payments yet (1 row estimated on each
  side): 12,497,500 rows compared by the join filter. Not cold reads: 3,123 blocks read in that branch. Most likely
  why the bound failed in 7 runs of 9 and passed in the others: a plan that rests on whether autovacuum has analysed
  `payment` and `ledger_entry` since the servicer's 5,000 payments (not proven run by run).
- The 50,000-line servicer: the checks statement 4.1–4.8 s, with whole-table sequential scans: `ledger_posting` four
  times (6.26 million rows: `receivable_negative`, `item_negative` twice, `owner_claim_mirror`), `ledger_entry` three
  times (786,066: the same and `notification_missing`), `bank_transaction` (169,500: I11 `cash_in_statement`, the
  payments' lines hashed), `client_notification` (107,000: `notification_missing`).

What each check reads now (one statement still, one snapshot; ARCHITECTURE §4: a lateral holding only a key for each
row reached from another, `EXISTS … OFFSET 0` kept as a keyed subplan):

| Check | Before | Now |
|---|---|---|
| payments' positions (`pos`: I4/I5, I19's payments, ageing, receipts, notifications) | entries tagged with a payment, grouped, then joined to the payments (hash or, misestimated, nested loop) | each payment, its entries by `payment_id`, their postings by `entry_id`, kept when on the servicer's 4710 accounts (`pe`), grouped per payment; the pending refund by the payment's key |
| `payment_negative_allocation` | the servicer's entries again | `pe` |
| I8′, I13, I19 (cash), `servicer_shortfall` | accounts × postings, joined by hash | each of the servicer's funds accounts (`(organization_id, book)`), its postings by `ledger_posting_balance_idx` (`bal`) |
| `receivable_negative`, `item_negative`, `owner_claim_mirror` | sequential scans of every servicer's postings and entries | each receivable account (`(organization_id, book)`), its postings by key, each lowering posting's entry by its id — one pass (`recv`); `item_negative` by a window, no join |
| I11 `cash_in_statement` | payments ⋈ every servicer's bank lines by hash | the servicer's 5120 accounts' postings, each entry by its id; each payment's line by its id |
| I19 (booked lines), I20 | joins by hash (refund requests, transfers, bookings) | each booking's postings, each posting's account; each transfer's bookings in one keyed scan, its request by `transfer_id`; each run's transfer by its id |
| `notification_missing` | every servicer's entries and notifications by sequential scans | the servicer's payments' entries by `payment_id`, each notification by its key; the returns from the payments (a link's payment is its servicer's: its foreign key) |
| receipts, `debit_unclassified`, `duplicate_unresolved` | the servicer's receipts grouped, joined by hash; every line of the servicer | each payment's receipts by its key; the lines of those kinds three days old at least, by the kinds' partial indexes, each test by key |

A posting's account is its entry's servicer's and an entry names a payment of its own servicer (both refused at
posting, LG002), so the accounts reach every posting the checks summed and the payments every entry tagged with a
payment: what each check finds is unchanged. Checked on two CI-order databases (8 servicers each): the build's
function and this one return the same rows (`except all` both ways: none), and pgTAP (35 files, 2,455 tests) passes.

Checks that sum the servicer's ledger by definition, so that read all of the servicer's rows of a book — not a
defect: the funds' identities I8′ (every posting of the servicer's 5120, 4710, 4670, 4679, 4689 and own books), I13
(each client's 4670), I19 (each dedicated account's 5120), `servicer_shortfall` (4679), `bank_balance_gap` (5120 up to
the last statement), I11 (the 5120 postings, the cash_in ones kept), the receivables' three checks (every 1100 and
3100 posting) and the payments' positions (every payment). Their plan: an index scan of the servicer's accounts by
`(organization_id, book)` (or its payments by `organization_id`), then each account's postings by
`ledger_posting_balance_idx` in a lateral — linear in the servicer's own postings, never another servicer's. The
largest is `recv` for the 50,000-line servicer: 150,000 accounts, 250,000 postings, 100,000 lowering entries read by
id (1.6 million rows handled).

Deterministic bounds (`test_transfer_files_scale_integration.py`: `checks_with_reads`, `assert_checks_keyed`,
`checks_work`, `assert_checks_bounded`; used by the refund-file test, the 50,000-line run's last check and the payout
test (a)):

- per table (`pg_stat_xact_user_tables` of the timed call): rows read ≤ k × the servicer's own rows + 2,000 (k from 4
  to 12 a table), and by sequential scans ≤ 2 × its own + 2,000 (a sequential scan is the right plan only where the
  servicer owns most of the table);
- per check (the same call again under auto_explain ANALYZE without timing, rolled back, its JSON plan): the rows each
  branch of the statement and each CTE handled (returned, filtered out, thrown away by join filters) and the buffers
  it touched ≤ 4 × the rows the servicer owns in those tables + 2,000 each.

The buffers bound came from a second finding. A first version of the rewrite (commit ac15bd4) kept the refund
servicer's checks at 1.9–2.4 s in the CI order (five runs: 2.04, 2.04, 1.88, 2.08 and 2.38 s), though they read only
its own 45,000 rows and took 0.25 s a minute later. Reproduced (the refund test alone, autovacuum off): each payment's
pending refund was looked up with the servicer and the status inside the lateral, and the stale statistics chose
`refund_request_waiting_idx` (the requests still requested, led by the servicer) — every request of the servicer for
each payment, the 5,000 executed ones' dead versions included until vacuum: 1.44 million buffers, no extra row (the
rows bound did not see it). Looked up by the payment's key only (the receipts' and the other debits' pending-refund
lookups too), the same state takes 0.29 s and 63,000 buffers; the buffers bound fails with the first version (1.49
million against 0.18 million) and passes with this one.

Before/after on the same data (the bounds probe, `bounds_probe.py` in the scratch area): with the build's function,
the receipts servicer (5,000 payments) read `ledger_posting` 4.7 million rows and `ledger_entry` 524,054 by sequential
scans and its `receivable_negative` handled 2.8 million rows (bound 0.42 million); the 50,000-line servicer read 7.8
million and 786,081, `item_negative` 5.4 million rows (bound 4.0 million) — both bounds red. With this one: 0 rows by
sequential scans of those tables, the largest check 1.6 times the servicer's rows — green. Also green with the
statistics of `payment` and `ledger_entry` forgotten.

Warm, same database, the build's function then this one: the refund servicer 6.0 s → 0.24 s; the receipts servicer
1.96–2.29 s → 0.50–0.63 s; the allocation servicer (50,000 payments) 5.2 s → 4.2–4.4 s; the 50,000-line servicer
5.7–6.6 s → 5.0–5.5 s (of which `run_remittance_runs_checks`, `private.pending_item_deadlines` over the 50,000 items,
≈ 2.6 s: not this statement); the payout servicer (5,050 transfers) 1.21 s → 1.13 s (six calls each).

**The CI `scale` job's command, in its order** (`RECEIPT_FILES=5000`, every `*scale_integration.py` but the payouts',
each run right after `supabase db reset`, the CI job's `pg_stat_statements` / `auto_explain` settings), five times
with the final migration (2afccb5), five times with the first version (ac15bd4) before it, and once with the build's
SQL (profiled, so its checks were instrumented):

| Run | Result | Refund servicer's nightly checks (< 5 s) | 50,000-line run's last checks | the run's checks with its draft / after approval | Allocation test's checks (50,000 payments) |
|---|---|---|---|---|---|
| build (9537d10), profiled | 6 passed, 1 failed (17 min 42 s) | **8.0 s** (instrumented) | 6.8 s (instrumented) | 6.3 / 6.6 s | 3.1 s |
| ac15bd4 ×5 | 7 passed each (17–20 min) | 2.04, 2.04, 1.88, 2.08, 2.38 s | 6.2, 5.5, 5.5, 6.8, 6.2 s | 3.9–5.1 / 4.4–5.4 s | 3.9–4.9 s |
| **2afccb5 ×5** | **7 passed each** (1,130, 1,059, 1,077, 1,099, 1,072 s) | **0.51, 0.45, 0.36, 0.32, 0.48 s** | 6.2, 5.7, 5.8, 6.0, 5.6 s | 4.1–5.2 / 4.5–5.3 s | 4.0–4.5 s |

The worst cold run of the refund servicer's checks is 0.51 s (≤ 2.5 s): the test keeps its wall bound at 5 s, beside
the deterministic bounds above. Its debit job over the 5,000 RFD debits: 11.6–13.9 s (< 120 s). The integration's
figures for the 50,000-line run's last checks were 6.3 and 5.9 s: 5.6–6.2 s now, of which this statement's own time
3.0–3.5 s (`track_functions`) and `private.run_remittance_runs_checks` most of the rest (`commission_key_open` called
50,000 times, 1.4–1.6 s, and `pending_item_deadlines`: not in this slice's statements). Warm on one database the
statement is faster for this servicer (6.6 → 5.4 s for the whole call, above).

One check got slower, and why: the allocation test's (3.1 s before, 4.0–4.5 s now). It runs first in the order, so its
servicer owns nearly every row of the database; there, hash joins over whole tables read only its own rows and beat
the keyed probes. The keyed plan is the one that holds whatever the statistics and the number of servicers
(ARCHITECTURE §4); that test bounds no time. Likewise the statement-import servicer (48,368 unallocated payments, no
entries): 0.35–0.46 s → 0.66–0.78 s warm (a few keyed probes per payment).

### Integration of round 2 (2026-11-12, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

The three round-2 branches merged (`m6b1-fix2-int`), the CI jobs' commands with the jobs' `pg_stat_statements` /
`auto_explain` settings, nothing else running on the VM.

**The CI `scale` job's command, in its order** (`RECEIPT_FILES=5000`, every `*scale_integration.py` but the payouts'),
three times:

| Run | Result | Refund servicer's nightly checks (< 5 s) | its debit job, 5,000 RFD debits | 50,000-line run's last checks | the run's checks with its draft / after approval | Allocation test's checks (50,000 payments) |
|---|---|---|---|---|---|---|
| 1 | **7 passed** (1,057 s) | **0.47 s** | 12.5 s | 5.7 s | 4.3 / 5.1 s | 4.2 s |
| 2 | **7 passed** (1,021 s) | **0.36 s** | 11.2 s | 4.9 s | 4.3 / 5.4 s | 4.3 s |
| 3 | **7 passed** (998 s) | **0.34 s** | 11.6 s | 5.3 s | 4.6 / 4.7 s | 4.2 s |

Every bound held: the refund servicer's per-table and per-check read bounds and its wall bound (0.34–0.47 s against
5 s; with the build's SQL, 5.0–8.0 s in round 1's and round 2's runs), and the 50,000-line run's. Of the 50,000-line run's last checks,
`run_payment_checks` took 2.7–2.9 s and `commission_key_open` (50,000 calls, `run_remittance_runs_checks`) 1.3–1.5 s,
as round 2 measured them. The re-run of the 50,000 items prepared and approved in 30.4–33.4 s, its payout filed,
downloaded, debited and booked in 0.7–1.0 s. The other tests as before: 50,000 files boarded in 88–95 s, 50,000
credits matched in 29.9–32.0 s and allocated in 72.8–76.8 s, the statement import 40.9–45.1 s, receipts 14.8–16.2 ms
each.

**The `scale-payouts` job's command** (`test_debit_bookings_scale_integration.py` alone), once: **5 passed** in
868.3 s. Fixture 50.1 s / 21.3 s / 690.4 s (prepare jobs 112.7 s, commands 4.6 s, approval jobs 565.4 s) /
« Générer le fichier » 2.93 s. P1, a batch line of 200 members: 0.48 s, 2,600 `bank_transfer` and 1,200
`transfer_file_item` rows read (400 transfers by a sequential scan of the 200-payout database, under the 1,000-row
tolerance). P4, 200 RMT lines: the debit job 0.65 s, its funds pass 0.5 s (≤ 2.0 s), no transfer read by a sequential
scan. (b) the 5,000-member batch line 31.8 s; (a) 5,000 RMT lines, the debit job 20.7 s, chunks 8.1, 8.5 and 4.0 s;
both with 0 rows of `bank_transfer` or `transfer_file_item` read by sequential scans. Nightly checks with 5,000 booked
payouts and 50 cancelled transfers 1.17 s, 0 violations.

### Integration of round 3 (2026-11-12, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

The two round-3 branches merged (`m6b1-fix3-int`) with the integration's two changes (the top-up rule's PmtInfId arm;
`private.post_run_settlements` posting at most 2,000 runs per `ledger_post_set` call), the CI jobs' commands with the
jobs' `pg_stat_statements` / `auto_explain` settings, nothing else running on the VM.

**The `scale-payouts` job's command.** On the merged branches, before the integration's chunking: **4 passed, 1
failed** (855 s). (b) wrote **1,980,000 bytes** of temporary files, which round 3's new assertion refuses (the database
branch had run (b) at 1,000 members only). A second run of (b) alone with `log_temp_files = 0` gave the same bytes and
named one file: the postings' insert of `private.ledger_post_set` under `private.post_run_settlements` — the batch
line's 5,000 settlements posted in one call, 30,000 postings whose statement triggers' transition table (`new_rows`,
66 bytes a posting on disk) outgrew `work_mem` (4 MB). Not the re-check: no plan node spilled. With the settlements
posted 2,000 runs per call, once on the final code: **5 passed** in 872.5 s. Fixture 49.9 s / 21.4 s / 680.5 s /
« Générer le fichier » 3.14 s.

| Step | Size | Integration of round 2 | Integration of round 3 |
|---|---|---|---|
| (P1) a batch line, the funds pass | 200 members | 0.48 s | **0.46 s**; `bank_transfer` 2,600 and `transfer_file_item` 1,200 rows read (400 transfers by a sequential scan of the 200-payout database, under the 1,000-row tolerance); temporary files **0 bytes** |
| (P4) 200 RMT lines | 200 | the job 0.65 s, its funds pass 0.5 s | the job **0.58 s**, its funds pass 0.5 s (≤ 2.0 s); no transfer read by a sequential scan |
| (b) the file's PmtInf as one batch line, one funds pass (rolled back) | 5,000 members | 31.8 s | **21.4 s** (26.0 s before the chunking); temporary files **0 bytes** (1,980,000 before); reads `bank_transfer` 65,000, `transfer_file_item` 30,000, `bank_line_booking` 15,000, none by a sequential scan |
| … again under auto_explain (rolled back) | 5,000 members | — | 23.0 s; 157 statements over 1 ms, **none spilled**, each re-check statement (keys, facts, rules) within 40 rows a member + 50 |
| (a) 5,000 RMT lines: the import; the debit job | 5,000 | 20.7 s, chunks 8.1, 8.5, 4.0 s | import 1.1 s; the job **22.0 s**, chunks 9.1, 8.5 and 4.2 s; none by a sequential scan |
| Nightly checks with 5,000 booked payouts and 50 cancelled transfers | 5,050 transfers | 1.17 s | **1.31 s**, 0 violations |

Under auto_explain the heaviest statements of (b) are not the re-check's but `private.ledger_post_set`'s matching of
pooled accounts (`_lps_dim` and `_lps_x`, `20261111090000`): 50.5 and 50.1 million rows handled for the 5,000
remittances, 40.4, 40.4 and 20.2 million for the three settlement calls — O(lines × the servicer's clients, here 5,000),
no temporary file, known since round 3's database branch (merged code, left for a later slice; the chunking neither
adds nor removes any). They are most of (b)'s 21.4 s.

**The CI `scale` job's command, in its order** (`RECEIPT_FILES=5000`, every `*scale_integration.py` but the payouts'),
twice on the merged branches before the chunking (runs 1–2) and twice on the final code (runs 3–4):

| Run | Result | Refund servicer's nightly checks (< 5 s) | its debit job, 5,000 RFD debits | 50,000-line run's last checks | the run's checks with its draft / after approval | Allocation test's checks (50,000 payments) |
|---|---|---|---|---|---|---|
| 1 | **7 passed** (1,004 s) | **0.33 s** | 11.8 s | 5.5 s | 4.0 / 5.0 s | 3.9 s |
| 2 | **7 passed** (1,024 s) | **0.35 s** | 11.0 s | 5.1 s | 4.2 / 4.8 s | 4.0 s |
| 3 | **7 passed** (991 s) | **0.42 s** | 10.9 s | 5.2 s | 4.1 / 4.6 s | 4.0 s |
| 4 | **7 passed** (985 s) | **0.32 s** | 11.2 s | 5.6 s | 4.5 / 4.7 s | 4.0 s |

Every bound held, the transfer-files test's `OWN_ROWS` with `private.client_payable_balance` included (M5: the 50,000-
line servicer's balances read by key, 1 row; the refund servicer's none). Of the 50,000-line run's last checks,
`run_payment_checks` took 2.8–3.0 s and `commission_key_open` (50,000 calls) 1.4–1.5 s, as in round 2. The re-run of
the 50,000 items prepared and approved in 30.0–32.7 s, its payout filed, downloaded, debited and booked in 0.8–1.0 s.
The other tests as before: 50,000 files boarded in 88–95 s, 50,000 credits matched in 29.2–32.6 s and allocated in
72.8–78.3 s, the statement import 39.5–45.1 s, receipts 14.4–15.3 ms each.

### M2c-6b-1 review fixes, round 4 (2026-11-12, same VM: 4 vCPU, 16 GB RAM, the main stack alone, right after `supabase db reset`, the `scale` job's settings)

Round 4 reads a credit's original end-to-end id and PmtInfId in the import's classifier
(`statement.refine_kind`, `private.bank_line_refined_kind`) and the payment's bank line in the match job
(`private.apply_match_results`, a keyed lateral). `test_statement_scale_integration.py` alone (50,000-line camt.053,
5,000 client IBANs, 48,368 payments):

| Run | Test | Parse alone | Import job (drained) | of which ingest | Same lines again (ingest) |
|---|---|---|---|---|---|
| round 3, CI command ×4 | 40.9–45.1 s | 4.0–5.1 s | 26.3–28.7 s | 9.0–9.8 s | 6.4–6.6 s (1.1–1.3 s) |
| round 4, classifier calling `private.names_our_transfer` | 45.6 s | 4.3 s | 26.2 s | 9.3 s | 7.3 s (2.3 s) |
| round 4, its three arms written out (the code) | 42.0 s | 4.1 s | 24.3 s | 8.1 s | 6.3 s (1.4 s) |

The nested call per credit (a SQL function with `SET search_path` is never inlined) cost the re-import's ingest about
1 s; the classifier now writes the predicate's arms out (the parity test and pgTAP `035` 127–128 pin both copies).

## Transfer-line foundations (M2c-6b-2a, migration `20261117090000`; 2026-11-17, cloud session VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

6b-2a redefines the import's `private.ingest_statement` (the unsplit details, counts and charges validated, and compared
on a re-import), the funds pass (`private.bank_booking_candidates`' two return facts, `private.post_bank_bookings`' two
rules), the first download's sweep re-check and the nightly checks. Each scale test that crosses them, once:

| Test | Result | Measured | Before (M2c-6b-1) |
|---|---|---|---|
| `test_debit_bookings_scale_integration.py` | **5 passed** (818 s) | the 5,000-member batch line's funds pass 20.8 s (21.7 s under auto_explain); 5,000 RMT debits imported in 1.2 s, the debit job 19.2 s in chunks of 7.5, 7.7 and 3.7 s; the nightly checks 1.02 s; 200 members 0.44 s; 200 RMT debits 0.72 s | 20.1 s; 1.0 s, 18.6 s (7.5, 7.1, 3.7 s); 1.15 s; 0.51 s; 0.54 s |
| `test_transfer_files_scale_integration.py` (5,000 refunds in one file) | **1 passed** | generation 2.31 s, job 0.78 s, **download (command) 0.76 s**, cash check 0.10 / 0.08 s, « Virements » 0.12 s, the debit job 9.6 s, the nightly checks 0.22 s | 2.36 s, 0.95 s, 0.75 s |
| `test_statement_scale_integration.py` (50,000-line camt.053) | **1 passed** | import job 26.1 s, of which ingest 8.8 s; the same lines again 6.7 s (ingest 1.4 s) | 24.3–26.2 s, 8.1–9.3 s; 6.3–7.3 s (1.4–2.3 s) |

The sweep re-check adds one keyed read of the file's sweep and one sum of the servicer's 4679 to the first download; the
return facts are read for return lines only, by key. `private.unique_subset` (no caller before
6b-2b), on 500 amounts: the worst saturating input of the bit representation (t'' below 2¹⁸ = 262,144; 5–90 €,
t' = 8,000) trips the work bound in 0.07–0.19 s (pgTAP `036` asserts < 0.5 s).

Corrected by the review fixes (CS-2, T7; 2026-11-17, same VM, `private.unique_subset_trace`, three runs each, in one
rolled-back transaction): the worst input is the row representation (t'' at or past 2¹⁸) with its partial sums
saturating just under the 10,000-sum bound, so that only the work bound or the last item stops it.

| 500 amounts | t'' (representation) | Stopped by | Time |
|---|---|---|---|
| 5–90 € (pgTAP `036`'s worst), target 80 € | 8,000 (bits) | work, item 423 | 79 / 105 / 107 ms |
| random 10–4,000 €, target 50,000 € | 5,000,000 (rows) | partial sums, item 14 | 101 / 104 / 115 ms |
| random 100,000 € ± 10 €, target 2,500,000.01 € | 250,000,001 (rows) | partial sums, item 14 | 65 / 72 / 73 ms |
| multiples of 10 € (10–200 €), target 26,000.01 € | 2,558,999 (rows) | none: all 500 items | 1,811 / 2,048 / 2,065 ms |
| multiples of 1 € (1–200 €), target 9,999.99 € | 999,999 (rows) | work, item 151 | 1,812 / 2,113 / 2,520 ms |

The last two rows are the figure 6b-2b's command budget and lot cap read (about 2.5 s at worst here, under half the API's
8 s), not the 1.4 s this section gave before (500 nearly equal amounts of about 100,000 €, whose sums trip their bound
early). Default (ADR-0014 « M2c-6b-2a review fixes »): 6b-2b's scale run times the row-mode saturating input.

The review fixes also redefine `private.transfer_late_lines` (a keyed read of `bank_duplicate_resolution` per line it
looks at), read by the funds pass's return facts and the nightly checks. `test_debit_bookings_scale_integration.py`
once, on a fresh reset: **5 passed** (842 s) — the 5,000-member batch line's funds pass 20.7 s; 5,000 RMT debits
imported in 1.2 s, the debit job 20.0 s in chunks of 7.6, 8.2 and 4.1 s; the nightly checks 1.14 s; 200 members
0.54 s; 200 RMT debits 0.62 s (the build's: 20.8 s; 1.2 s, 19.2 s; 1.02 s; 0.44 s; 0.72 s).

## The ops command (M2c-6b-2b, migration `20261117100000`; 2026-11-17, cloud session VM: 4 vCPU, 16 GB RAM, the main stack alone)

`public.book_transfer_line` and its reads (`transfer_line_options`, `transfer_line_preview`) run as an aal2 API session
(the authenticator, then `authenticated` and the JWT claims, `statement_timeout = 8s`: `debit_helpers.api`). The plan's
budget (§8.2 « Scale », critic CSO-3): options < 2 s and the command ≤ 4 s at the lot cap, the refusal of a lot above
it at once. `tests/test_transfer_line_scale_integration.py`, its fixtures through the jobs (clients, collections, runs
requested, prepared and approved, the file generated, written and downloaded), each lot one PmtInf debited as one batch
line short of one member (a random member left out: class B, the only subset over every member):

| Lot | `transfer_line_options` | `book_transfer_line` | Result | Fixture |
|---|---|---|---|---|
| 500 members (`private.transfer_line_lot_cap()`), short of one | **0.35 s** (the subset proposed: 499 parts) | **1.17 s** (499 bookings) | passed | 500 runs requested/prepared/approved 61.5 s, « Générer le fichier » 0.27 s |
| 501 members | **0.04 s** (`lot_too_large`, `member_count` 501, no member list, no proposal) | — | passed | 501 runs 69.0 s, generation 0.33 s |

The lot above the cap is refused by `private.transfer_line_pre` before any subset is searched. Not measured here (left
to the review): the worst saturating input of the command (500 small payouts short of one 80 € member, the row
representation's 1.8–2.5 s of `unique_subset` above), the requeue of a 50,000-item draft, and the time the allocation
lock is held; the 2× headroom of the cap under 8 s therefore rests on 6b-2a's `unique_subset` measurement plus this
run's 1.17 s for a 500-member booking.

Review fixes (CSR-3; 2026-11-17, same VM): the options no longer search the lot's subset twice (their pre-read serves
the preview of their proposal: `private.transfer_line_preview_of`; pgTAP `037` counts one search). The same test file
(the last run end to end, 4 passed in 155.5 s): the lot short of one member 0.21 / 0.26 s (options) and 1.45 / 1.39 s
(499 bookings); the lot above the cap 0.02 s; and
the saturating inputs at the cap (`test_a_saturating_lot_at_the_cap_runs_its_search_once_within_budget`: the lot's 500
payouts re-amounted in a rolled-back transaction, its PmtInf debited by an amount no subset makes, then as the API's
session):

| 500 amounts (row representation) | Stopped by | `transfer_line_options` (`batch_ambiguous`) | `book_transfer_line` (`parts_do_not_add_up`, after the search) |
|---|---|---|---|
| multiples of 10 € (10–200 €), target 26,000.01 € | none: all 500 items | 2.05 / 1.99 / 1.89 / 2.05 s | 2.16 / 2.24 / 2.39 / 2.29 s |
| multiples of 1 € (1–200 €), target 9,999.99 € | the work bound | 2.14 / 2.31 / 2.20 / 2.42 s | 2.16 / 2.27 / 2.17 / 2.40 s |

The cap's rule (2× headroom under the API's 8 s) holds; the options' < 2 s budget is missed by up to 0.42 s at these
two inputs, where one search alone takes about 2 s — set by the work bound, not by the cap (ADR-0014 « M2c-6b-2b
review fixes », CSR-3: known limit and default; the test asserts ≤ 4 s there, < 2 s for the ordinary lot).

The review fixes also redefine `private.post_bank_bookings` (`payments:` taken for a batch holding a sweep's return:
one more list member, no read) and add the per-transfer bound to P (a keyed read of the transfer's unplanned bookings
and their advances). `test_debit_bookings_scale_integration.py` once, on a fresh reset: **5 passed** — the fixture's
approval jobs 526.1 s; the 5,000-member batch line's funds pass 20.1 s (21.0 s under auto_explain); 5,000 RMT debits
imported in 1.3 s, the debit job 18.6 s in chunks of 7.3, 7.7 and 3.3 s; the nightly checks 0.96 s; 200 members
0.57 s; 200 RMT debits 0.74 s (the build's: 21.1 s; 1.3 s, 21.0 s; 1.13 s; 0.69 s; 0.70 s). The download did not
change: the transfer-files scale test was not run again.

The command adds two `UPDATE … where true` and a third branch to `private.pending_item_deadlines` (keyed: the reversed
remittance, then `private.unplanned_paid_item` by its booking, then each item's live line) and keys its planned branch
on the transfer's own remittance. `test_debit_bookings_scale_integration.py` once, on a fresh reset: **5 passed**
(830.7 s) — the fixture's approval jobs 521.9 s (552.1 s before); the 5,000-member batch line's funds pass 21.1 s;
5,000 RMT debits imported in 1.3 s, the debit job 21.0 s in chunks of 8.4, 8.2 and 4.2 s; the nightly checks 1.13 s;
200 members 0.69 s; 200 RMT debits 0.70 s (6b-2a's: 20.7 s; 1.2 s, 20.0 s; 1.14 s; 0.54 s; 0.62 s). The download did
not change: the transfer-files scale test was not run again.

### CI scale fix — the command after the 50,000-line runs (2026-11-17)

PR #33's dispatched `scale` run failed the lot-cap file's three booking cases: `transfer_line_options` 1.60 / 1.68 s,
`book_transfer_line` cancelled at the API's 8 s in `private.transfer_line_locks` step 4 (the GitHub runner). The CI
order (one fresh database; the allocation, matching, receipts, 50,000-item remittance, boarding, statement and
transfer-file scale tests, then this file) on a third local stack of the cloud session VM (4 vCPU, two other stacks
running beside it: the receipts ran at 17.9 ms each against CI's 9.3) failed the same three, at the same line
(saturating inputs: options 2.35 / 2.56 s, the command 8.00 s). What the 50,000-line runs leave: remittance_line
101,000 rows, two runs holding 100,000 of them (n_distinct of `run_id` 2 once analysed), so each run's key is estimated
at 50,000 rows and each member's run was read whole-table (ADR-0014 « M2c-6b-2b review fixes », CI scale fix). At the
failing point (the lot's committed line), each call rolled back:

| The lot of 500, short of one, after the 50k runs | `transfer_line_options` | `book_transfer_line` |
|---|---|---|
| before, as the API's session (8 s) | — | cancelled at 8 s (lock step 4) |
| before, under EXPLAIN ANALYZE (no timeout) | 6.52 s: the check's late flag, 494 × 13 ms (a whole scan of `remittance_line_account_idx`, 51,000 rows, per part) | 53.97 s: lock step 4 21.1 s (500 sequential scans of remittance_line, 101,000 rows each), the posting's late lines 20.9 s (499 more) |
| after, the fixed functions applied in place, as the API (five calls) | 0.19 – 0.27 s | 1.42 – 1.72 s (instrumented: the lock step 26 ms, the rest the posting — the settlements 0.73 s, the remittances 0.36 s) |

Then the CI order again from `supabase db reset`, with the fix: **12 passed** in 1,684 s (the eleven of the failed run
and `test_the_command_reads_a_lot_by_key`):

| Lot-cap file, after the 50k runs | `transfer_line_options` | `book_transfer_line` |
|---|---|---|
| short of one, rolled back (the new case: no sequential scan of remittance_line, remittance_run, bank_transfer, transfer_file, transfer_file_item; 1,997 remittance_line rows read) | 0.29 s | 1.84 s (499 bookings) |
| short of one (`test_a_lot_at_the_cap_short_of_one_member_is_booked_within_budget`) | 0.29 s | 1.76 s (499 bookings) |
| saturating, multiples of 10 € | 2.08 s (`batch_ambiguous`) | 2.36 s (`parts_do_not_add_up`) |
| saturating, multiples of 1 € | 3.40 s (`batch_ambiguous`) | 2.37 s (`parts_do_not_add_up`) |
| 501 members | 0.03 s (`lot_too_large`) | — |

On a fresh database alone (CI's « 1.4–2.4 s ») the lot's runs' lines were read by key before the fix too, each run's
key estimated at its one line: the fix makes those plans independent of the statistics, not a fresh database faster.
The saturating options are the subset search's CPU (1.9–2.4 s on a quiet VM above; 3.40 s here, two other stacks
loading the VM), under the test's 4 s. The posting the job shares (`private.bank_booking_post_rows`) changed with
the fix, so `test_debit_bookings_scale_integration.py` ran once on a fresh reset of the same stack: **5 passed**
(1,066.8 s) — the 5,000-member batch line's funds pass 22.5 s (23.5 s under auto_explain), 5,000 RMT debits imported in
1.6 s and booked by the debit job in 20.9 s (chunks of 9.1, 7.6 and 3.9 s), 200 members 0.46 s, 200 RMT debits 0.90 s
(the loaded VM's; the quiet VM's above: 21.1 s, 1.3 s, 21.0 s, 0.69 s, 0.70 s).

### M2c-6b-2b deferred tests (2026-11-17, same VM: 4 vCPU, 16 GB RAM, the main stack alone, right after `supabase db reset`; measured at the 6b-2c integration)

Track B first measured these on a second stack beside track A's runs (load average 5–7: options 0.23 s, the command
1.61 s and the lock 1.40 s at the lot of 500; 0.026 / 0.024 s at 5,000 members; 0.09 / 0.25 / 0.20 s for the draft);
the figures below replace them, taken at the integration of 6b-2b's deferred tests with 6b-2c and PR #33's CI scale
fix, the main stack alone. `tests/test_transfer_line_scale_integration.py`, the whole file once: **7 passed** (160.2 s,
the two lot fixtures 65.3 s and 62.3 s of it). The three items 6b-2b left unmeasured (above), each as the aal2 API
session:

| Item | `transfer_line_options` | `book_transfer_line` | The allocation lock (`payments:`) held | Fixture |
|---|---|---|---|---|
| 500-member lot short of one (499 bookings) | **0.26 s** | **1.43 s** | **1.17 s** (`pg_locks` polled every 2 ms from a second connection) | 500 runs through the jobs 65.3 s |
| 5,000-member lot (one PmtInf of a downloaded file, 4,998 members added in a rolled-back transaction) | **0.013 s** (`lot_too_large`, `member_count` 5000, the subset search replaced by a raising function: never called) | **0.016 s** (`lot_too_large`) | — | the file of two payouts through the jobs |
| a client's draft of 50,000 reserved items, re-prepared by the command booking that client's unplanned payout | **0.06 s** | **0.16 s** | **0.12 s** | 50,000 advances posted set-based 15.9 s, the draft requested 0.88 s |

The same run's other cases: the lot read by key (rolled back) — options 0.25 s, the command 1.25 s, no sequential scan
of the per-member tables, 2,496 remittance_line rows read for 500 members; the saturating lots at the cap — multiples
of 10 €: options 1.88 s, command 1.74 s; multiples of 1 € (the work bound): 2.16 s and 1.88 s (`parts_do_not_add_up`);
the lot above the cap 0.02 s (`lot_too_large`).

What the figures say: the lock is held for most of a 500-member booking (its postings run under it: ≈ 0.82 of the
command), so a second command of the same servicer waits about that long for it — inside the command's own 2 s
`lock_timeout` (beyond it: `busy`, nothing booked); the requeue of a large draft is not the cost
(`private.remittance_draft_requeue` reserves the client's unreserved items, recounts the draft's 50,000 items by
`remittance_pending_run_idx` and queues the prepare job; the draft's prepared lines are cleared by
`private.remittance_prepare_begin` under the run lock when that job starts, not under `payments:`); and a lot far
above the cap is answered from the keyed count of `transfer_file_item` by PmtInfId, whatever its size. The tests
assert the budgets (options < 2 s at the cap's ordinary lot, ≤ 4 s at the saturating inputs; the command ≤ 4 s; the
lock held no longer than the command; the 5,000-member options and command < 0.5 s each; the requeue's command ≤ 4 s and its lock
< 1 s).

## The pages (M2c-6b-2c, migration `20261117110000`; 2026-11-17, cloud session VM: 4 vCPU, 16 GB RAM, the main stack alone)

The nightly checks change (`private.run_remittance_runs_checks` reads `private.transfer_debit_suppression` for each
in-flight transfer whose file was downloaded and whose statements cover its date, only when it is not yet seen;
`private.run_transfer_checks`' `bank_line_unbooked` adds the reference-less other debits with a rule-3b candidate),
and rule 3b's probe moves to the non-partial `bank_transfer_account_amount_idx`. `test_debit_bookings_scale_integration.py`
once, on a fresh reset: **5 passed** — the fixture's approval jobs 730.9 s (521.9 s in 6b-2b's run: the fixture, not
a timed path); the 5,000-member batch line's funds pass 21.5 s (22.3 s under auto_explain); 5,000 RMT debits imported
in 1.3 s, the debit job 19.4 s in chunks of 8.1, 7.7 and 3.3 s; the nightly checks 0.94 s (1.15 s warm with row
counts on); 200 members 0.42 s; 200 RMT debits 0.69 s (6b-2b's: 21.1 s; 1.3 s, 21.0 s; 1.13 s; 0.69 s; 0.70 s).
`test_transfer_line_scale_integration.py` right after (rule 3b's candidates and the options redefined): **4 passed** in
176.2 s — the 500-member lot short of one: options 0.35 s, booking 1.27 s (499 bookings); the saturating lots at the
cap: options 2.23 / 2.11 s, the command 2.54 / 2.01 s (`parts_do_not_add_up`); the lot above the cap 0.03 s
(`lot_too_large`). « À classer »'s new reads are bounded by pgTAP `037` P `p_queue_reads` (40 reference-less debits,
300 cancelled payouts of the account in a file: fewer than 200 `bank_transfer` reads, no sequential scan, the lines by
key). The download did not change: the transfer-files scale test was not run again.

### Integration (6b-2c with 6b-2b's deferred tests and PR #33's CI scale fix; 2026-11-17, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

The later files now carry the CI scale fix (`20261117105000`'s locks and options copied again from it; `20261117110000`'s
options body with it; the run's lines and each transfer's bookings in 6b-2c's new reads by key alone — ADR-0014
« M2c-6b-2c integration »). The funds pass, the debit job, the nightly checks and the command all run through that code.

`test_debit_bookings_scale_integration.py` once: **5 passed** (766.3 s) — the fixture's approval jobs 489.3 s; the
5,000-member batch line's funds pass 20.3 s (20.4 s under auto_explain); 5,000 RMT debits imported in 1.1 s, the debit
job 18.7 s in chunks of 7.5, 7.4 and 3.5 s; the nightly checks 1.00 s (1.10 s warm with row counts on); 200 members
0.47 s; 200 RMT debits imported in 0.3 s and booked in 0.57 s.

`test_transfer_line_scale_integration.py` alone: **7 passed** (160.2 s; « M2c-6b-2b deferred tests » above holds its
figures).

CI's `scale` job as `.github/workflows/ci.yml` runs it — `supabase db reset`, auto_explain at 60 s, `RECEIPT_FILES=5000`,
`pytest -m integration -s` over `tests/*scale_integration.py` but the payouts file, in `ls` order, one database (the
50,000-line runs first, the transfer-line file last): **14 passed** in 1,239.5 s, no statement over 60 s logged (PR
#33's dispatched run failed here, before its fix: three lot-cap cases cut off at the API's 8 s):

| File (test time) | Timings |
|---|---|
| allocation (211.2 s) | 50,000 files boarded 80 s; 50,000 credits imported and matched 28.5 s; allocated 69.3 s |
| matching (138.9 s) | 50,000 files boarded 83 s; history 13,500 credits 10.4 s; the statement's 50,000 credits imported and matched 38.8 s |
| receipts (93.7 s) | 5,000 files boarded, credited, matched and allocated 26 s; 25 receipt jobs 66.4 s (13.3 ms a receipt) |
| remittance (284.5 s) | nightly checks 5.78 s; 50,000 items reserved 1.25 s, prepared 11.9 s; approval command 0.03 s, job and documents 14.4 s; nightly checks 4.4 s (the draft waiting 3.9 s); transfer file 0.05 s; cancellation 3.69 s; 6b-1's re-run prepared and approved 28.9 s, its payout filed, downloaded, debited and booked 0.8 s; nightly checks with the run booked 5.8 s (5.17 s warm) |
| boarding (100.3 s) | 50,000 loans 100 s (commit 26.8 s, confirm job 31.4 s); 50,000 references backfilled 4.1 s |
| statement (43.7 s) | 50,000-line camt.053 (35 MB): parse 3.9 s, import job 26.1 s (ingest 8.8 s); the same lines again 6.8 s |
| transfer files (37.1 s) | 5,000 refunds asked 18.0 s; generation 2.14 s, job 0.79 s, check 0.49 s, download 0.82 s; cash check 0.12 / 0.10 s; « Virements » 0.13 s; the debit job booking the 5,000 debits 10.2 s; nightly checks 0.40 s (0.33 s warm) |
| transfer lines, after the 50k runs (lot fixtures 147.1 s each) | the lot read by key (rolled back): options 0.15 s, command 1.32 s, no sequential scan of the per-member tables, 2,496 remittance_line rows read; short of one: 0.17 s and 1.40 s (499 bookings), the allocation lock held 1.26 s; saturating, multiples of 10 €: 2.08 s and 2.06 s, of 1 €: 2.11 s and 2.18 s (`parts_do_not_add_up`); 501 members 0.03 s; 5,000 members 0.011 s and 0.018 s (`lot_too_large`); the 50,000-item draft: options 0.07 s, command 0.17 s, lock 0.13 s |

The preview inside the options and the command reads 500 payout parts' run facts (`transfer_line_parts_json`'s
latest execution date, new in 6b-2c): with the run's key alone inside its subquery, its reads stay within the keyed-read
test's bound (2,496 remittance_line rows for 500 members, as on a fresh database) after the 50,000-line runs.

### Review fixes, round 1 (2026-11-18, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

ADR-0014 « M2c-6b-2c review fixes ». The nightly check's suppression counts two more shapes of lines (a debit of the
payout's amount to its payee's IBAN whatever its references; an entry kept unsplit whose stored details name its debit)
inside the same keyed read of the account's lines by booking date; the command's check reads the late date through
`private.remittance_run_late_on` (the run's lines by its key); « À classer » and « Frais » probe rule 3b only for a line
of the amount of a transfer of ours put in a file (cs-1).

- « Débits et retours » on a backlog of 10,000 other debits without our reference (the reviewer's fixture, set local
  `statement_timeout` 8 s as the API): « À classer » 0.29 s, « Frais » 0.34 s (before: 7.0 s and 7.7 s; 12,000 lines
  cut off at 8 s). pgTAP `037` `p_queue_backlog` holds each tab under 3 s.
- `test_debit_bookings_scale_integration.py` once: **5 passed** (728.9 s) — the fixture's approval jobs 460.2 s; the
  5,000-member batch line's funds pass 19.1 s (20.2 s under auto_explain); 5,000 RMT debits imported in 1.2 s, the
  debit job 18.6 s in chunks of 7.5, 7.4 and 3.5 s; the nightly checks 1.01 s (1.07 s warm with row counts on); 200
  members 0.38 s; 200 RMT debits imported in 0.3 s and booked in 0.56 s.
- `test_transfer_line_scale_integration.py` alone: **7 passed** (157.8 s) — the 500-member lot short of one: options
  0.28 to 0.32 s, booking 1.18 to 1.42 s (499 bookings, the allocation lock held 1.25 s); the saturating lots at the
  cap: options 1.97 / 1.88 s, the command 1.94 / 2.22 s (`parts_do_not_add_up`); 501 and 5,000 members 0.02 s
  (`lot_too_large`); the 50,000-item draft: options 0.06 s, command 0.21 s, lock 0.16 s.

### Review fixes, round 3 (2026-11-18, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

ADR-0014 « M2c-6b-2c review fixes », round 3. The nightly check's suppression reads one more condition on the lines its
legal-deadlines-1 branch keeps (the line's class, `private.transfer_line_class`, by key, only for a debit of the
payout's amount to its payee's IBAN); « Lier »'s guard reads the run of a cancelled candidate by key. Nothing else the
volume runs time changed.

- `test_debit_bookings_scale_integration.py` once: **5 passed** (736.7 s) — the fixture's approval jobs 460.4 s; the
  5,000-member batch line's funds pass 19.1 s (19.6 s under auto_explain); 5,000 RMT debits imported in 1.1 s, the
  debit job 18.7 s in chunks of 7.6, 7.6 and 3.3 s; the nightly checks 1.02 s (1.11 s warm with row counts on); 200
  members 0.40 s; 200 RMT debits imported in 0.3 s and booked in 0.59 s.
- `test_transfer_line_scale_integration.py` alone: **7 passed** (153.6 s) — the 500-member lot short of one: options
  0.28 to 0.32 s, booking 1.07 to 1.26 s (499 bookings, the allocation lock held 1.09 s); the saturating lots at the
  cap: options 1.91 / 1.92 s, the command 1.74 / 1.91 s (`parts_do_not_add_up`); 501 and 5,000 members 0.01 to 0.03 s
  (`lot_too_large`); the 50,000-item draft: options 0.06 s, command 0.20 s, lock 0.15 s.

### 6b-2c carry-overs, in 6b-2d (2026-11-18, same VM: 4 vCPU, 16 GB RAM, the main stack beside 6b-2d's second stack `collectoo_t`, load average 2.5 to 3.8; each run right after `supabase db reset`)

ADR-0014 « M2c-6b-2c carry-overs (in 6b-2d) », migration `20261117113000`. The nightly check's suppression reads one
more condition on the lines its legal-deadlines-1 branch keeps (whether a debit's PmtInfId names another lot of the
account: `private.pmt_inf_names_account_lot`, keyed, read last); the command's pre-read checks, on a class-E0 debit
only, each rule-3b candidate's item by key; « Lier »'s refund link reads the run of a cancelled candidate as the return
already did. The lot and unsplit paths these runs time are unchanged; the slower figures than round 3's follow the
shared VM (the second stack up, the load average 2.5 to 3.8 while they ran).

- `test_debit_bookings_scale_integration.py` once: **5 passed** (896.5 s) — the fixture's approval jobs 555.2 s; the
  5,000-member batch line's funds pass 23.4 s (24.7 s under auto_explain); 5,000 RMT debits imported in 1.4 s, the
  debit job 22.4 s in chunks of 8.8, 9.3 and 4.1 s; the nightly checks 1.20 s (1.24 s warm with row counts on); 200
  members 0.54 s; 200 RMT debits imported in 0.3 s and booked in 0.73 s.
- `test_transfer_line_scale_integration.py` alone: **7 passed** (181.7 s) — the 500-member lot short of one: options
  0.41 to 0.43 s, booking 1.51 to 1.65 s (499 bookings, the allocation lock held 1.39 s); the saturating lots at the
  cap: options 2.28 / 2.36 s, the command 2.23 / 2.39 s (`parts_do_not_add_up`); 501 and 5,000 members 0.02 to 0.03 s
  (`lot_too_large`); the 50,000-item draft: options 0.11 s, command 0.20 s, lock 0.15 s.

## « Suivi » with the carry-overs (M2c-6b-2d integration, migrations `20261117113000` and `20261117120000`; 2026-11-18, cloud session VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

Branch `m6b2d-int`: 6b-2d's « Suivi » (ADR-0014 « M2c-6b-2d ») merged with the 6b-2c carry-overs (« M2c-6b-2c
carry-overs (in 6b-2d) »). The two migrations redefine disjoint functions. What the volume runs time and the merge
changes: the statement build (`private.remittance_statement_build` with `private.remittance_statement_previous_payouts`
and the late cause's `private.remittance_statement_paid_by_unplanned`), drawn by the approval's documents job; the nightly
check's suppression (`private.transfer_debit_suppression`) and the command's pre-read (`private.transfer_line_pre`, its
new read on class-E0 lines only). The second stack `collectoo_t` was down: these runs had the VM to themselves. Paths
neither migration touches are slower than at 6b-2c's integration as well (boarding 109 s against 100 s, allocation
73.6 s against 69.3 s, the statement's import job 27.2 s against 26.1 s; the 5,000-member funds pass 23.1 s against
19.1 s in round 3); every budget held.

- `test_debit_bookings_scale_integration.py` once: **5 passed** (768.5 s) — the fixture's approval jobs 476.0 s; the
  5,000-member batch line's funds pass 23.1 s (24.8 s under auto_explain); 5,000 RMT debits imported in 1.1 s, the
  debit job 21.7 s in chunks of 8.4, 8.8 and 4.3 s; the nightly checks 1.02 s (1.13 s warm with row counts on); 200
  members 0.60 s; 200 RMT debits imported in 0.3 s and booked in 0.70 s.
- `test_transfer_line_scale_integration.py` alone: **7 passed** (165.4 s) — the 500-member lot short of one: options
  0.36 to 0.48 s, booking 1.50 to 1.60 s (499 bookings, the allocation lock held 1.35 s); the saturating lots at the
  cap: options 2.33 / 2.65 s, the command 2.23 / 2.23 s (`parts_do_not_add_up`); 501 and 5,000 members 0.01 to 0.02 s
  (`lot_too_large`); the 50,000-item draft: options 0.06 s, command 0.25 s, lock 0.19 s.

CI's `scale` job as `.github/workflows/ci.yml` runs it — `supabase db reset`, auto_explain at 60 s (the job's
`alter system` settings, reset afterwards on this stack), `RECEIPT_FILES=5000`, `pytest -m integration -s` over
`tests/*scale_integration.py` but the payouts file, in `ls` order, one database (the 50,000-line runs first, the
transfer-line file last): **14 passed** in 1,356.8 s (1,239.5 s at 6b-2c's integration), no statement over 60 s logged:

| File | Timings |
|---|---|
| allocation | 50,000 files boarded 93 s; 50,000 credits imported and matched 29.9 s; allocated 73.6 s (5 chunks of 10,000, post 11.4 to 12.0 s); 1,000 returns imported and linked 26.1 s; nightly checks 4.1 s |
| matching | 50,000 files boarded 93 s; history 13,500 credits 10.8 s; the statement's 50,000 credits imported and matched 41.1 s (48,423 automatic, 0 wrong) |
| receipts | 5,000 files boarded, credited, matched and allocated 27 s; 25 receipt jobs 68.0 s (13.6 ms a receipt) |
| remittance | nightly checks 5.39 s; 50,000 items reserved 1.31 s, prepared 12.3 s; approval command 0.02 s, job and documents 16.5 s (the statement build 6.56 s, CSV 1.81 s, PDF 1.53 s; the re-run's statement build 6.78 s); nightly checks 4.5 s (the draft waiting 4.2 s); transfer file 0.04 s; cancellation 3.97 s; 6b-1's re-run prepared and approved 30.0 s, its payout filed, downloaded, debited and booked 0.8 s; nightly checks with the run booked 5.4 s (5.77 s warm) |
| boarding | 50,000 loans 109 s (commit 29.2 s, confirm job 32.6 s); 50,000 references backfilled 4.0 s |
| statement | 50,000-line camt.053 (35 MB): parse 4.8 s, import job 27.2 s (ingest 9.3 s); the same lines again 6.9 s |
| transfer files | 5,000 refunds asked 17.7 s; generation 2.74 s, job 0.92 s, check 0.49 s, download 0.85 s; cash check 0.12 / 0.09 s; « Virements » 0.13 s; the debit job booking the 5,000 debits 11.8 s; nightly checks 0.32 s (0.32 s warm) |
| transfer lines, after the 50k runs (lot fixtures' approval jobs 145.9 s and 141.5 s) | the lot read by key (rolled back): options 0.38 s, command 2.05 s, no sequential scan of the per-member tables, 1,997 remittance_line rows read; short of one: 0.47 s and 2.26 s (499 bookings), the allocation lock held 2.01 s; saturating, multiples of 10 €: 2.36 s and 2.45 s, of 1 €: 2.40 s and 2.68 s (`parts_do_not_add_up`); 501 members 0.02 s; 5,000 members 0.014 s and 0.014 s (`lot_too_large`); the 50,000-item draft: options 0.07 s, command 0.16 s, lock 0.12 s |

The statement build on the 50,000-line run, 6.56 s here (6.78 s for the re-run's), was 6.10 to 6.24 s before « Suivi »
(« Manual credit note (M2c-5b) » above, an earlier day on this VM); 6b-2d's track timed both builds alternately on one
run of its second stack (4.8 to 5.5 s against 4.8 to 5.3 s for `20261117100000`'s, ADR-0014 « M2c-6b-2d »), and pgTAP
`038`'s second R asserts that no late-cause helper call is made for a line that is not late.

### Review fixes, round 1 (2026-11-18, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

What the round changes on a timed path: the statement build (`private.remittance_statement_previous_payouts` reads
the earlier runs' chain bookings posted by K and ranks their executions; the late cause's test) and the documents
job's record step (one guard). The funds pass, the debit job, the nightly checks and the command are unchanged.

- `test_debit_bookings_scale_integration.py` once: **5 passed** (844.9 s) — the fixture's approval jobs 525.2 s; the
  5,000-member batch line's funds pass 26.4 s (27.6 s under auto_explain); 5,000 RMT debits imported in 1.4 s, the
  debit job 24.2 s in chunks of 9.7, 9.8 and 4.4 s; the nightly checks 1.18 s (1.35 s warm with row counts on); 200
  members 0.62 s; 200 RMT debits imported in 0.3 s and booked in 0.79 s (no path of these changed; the VM is slower
  than at the integration's run throughout, the fixture's approval jobs too).
- `test_transfer_line_scale_integration.py` alone: **7 passed** (177.4 s) — the 500-member lot short of one: options
  0.38 to 0.41 s, booking 1.42 to 1.54 s (499 bookings, the allocation lock held 1.30 s); the saturating lots: options
  2.15 / 2.45 s, the command 2.35 / 2.40 s (`parts_do_not_add_up`); 501 and 5,000 members 0.014 to 0.02 s
  (`lot_too_large`); the 50,000-item draft: options 0.06 s, command 0.18 s, lock 0.14 s.
- `test_remittance_scale_integration.py` alone: **1 passed** (322.2 s) — 50,000 items reserved 1.27 s, prepared 9.4 s;
  approval job and documents 15.9 s, the statement build **6.05 s** (6.56 s at the integration), CSV 1.46 s, PDF 1.73 s;
  the re-run's build 6.02 s; cancellation 4.06 s; nightly checks 5.63 s (5.57 s warm).

### M2c-6b-3a: switch-on prerequisites, the switch off (2026-11-18, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

What the slice changes on a timed path: the holds read at generation and at a generated file's first download (M's
`private.transfer_sibling_debited_late` per payout and refund, A's sweep hold), the re-download's re-check, the nightly
`run_transfer_checks` (a shared set of the cancelled filed transfers, two new branches), `private.transfer_debited_before`
(L's arm, for chain members and cancelled transfers only), rule 3b's candidates (K) and the cancellation evidence (N).
The funds pass, the debit job and the command's booking path are unchanged.

- `test_transfer_files_scale_integration.py` (5,000 refunds in one file): **1 passed** — generation (command) **2.83 s**,
  job 0.88 s, download (command) **1.14 s**, cash check 0.14 / 0.09 s, « Virements » 0.13 s, the debit job 10.2 s, the
  nightly checks 0.28 s (0.27 s warm), every row read by index (was 2.31 s, 0.78 s, 0.76 s, …, 0.22 s). Its first run
  showed M's lookup of a refund's request quadratic — generation 7.98 s, download 6.27 s; then, on a fresh reset, past
  the API's 8 s (`statement timeout`) — with the servicer and the status beside the key a fresh table's statistics read
  every waiting refund by `refund_request_waiting_idx`, once per refund (4.6 s for the 5,000 holds alone): the probe
  holds its key alone (the 5,000 sibling holds 0.16 s, the 5,000 holds 1.19 s). *Review round 1 (CSC-2) corrects this
  paragraph:* the build also added `refund_request_transfer_idx`, believing no index was led by
  `refund_request.transfer_id`; `refund_request_transfer_id_key` (the column's unique index) already was, and the probe
  uses it once the duplicate is dropped — the index is removed (timings below).
- `test_transfer_line_scale_integration.py` (with the scale file above, before that fix; neither path touched by it):
  **8 passed** — the 500-member lot short of one: options 0.36 to 0.42 s, booking 1.53 to 1.56 s (499 bookings, the
  allocation lock held 1.33 s); the saturating lots: options 2.33 / 2.42 s, the command 2.46 / 2.58 s
  (`parts_do_not_add_up`); 501 and 5,000 members 0.014 to 0.02 s (`lot_too_large`); the 50,000-item draft: options
  0.09 s, command 0.16 s, lock 0.13 s.
- `test_debit_bookings_scale_integration.py` once (before that fix, which touches refunds only): **5 passed** (782.2 s)
  — the fixture's approval jobs 482.8 s, « Générer le fichier » for 5,000 payouts (+50 cancelled) 3.56 s; the
  5,000-member batch line's funds pass 24.1 s (24.7 s under auto_explain); 5,000 RMT debits imported in 1.4 s, the debit
  job 22.7 s in chunks of 9.0, 9.3 and 4.1 s; the nightly checks 1.13 s (1.13 s warm with row counts on); 200 members
  0.64 s; 200 RMT debits imported in 0.3 s and booked in 0.79 s.

### M2c-6b-3a review fixes, round 1 (2026-11-18, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

What the round changes on a timed path: rule 3b's candidates (two exclusions over the candidates already read: a
cancelled payout beside the payout re-issuing it or re-paying its run's items, a cancelled sweep beside the sweep made
after it — each keyed, the run's lines by its key, an item's live line by `remittance_line_live_uq`), the refund link's
guard, D's helper (`private.refund_line_barred_by`: the request by its key, the payment's requests by
`refund_request_payment_idx`), `private.debited_cancelled_sweeps` (CSC-1: by `bank_transfer_cancelled_filed_idx`'s own
key), « Virements »' sweep hold (once per currency) and `refund_request_transfer_idx` removed (CSC-2). The funds pass and
the debit job are unchanged.

- `test_transfer_files_scale_integration.py` (5,000 refunds in one file), without `refund_request_transfer_idx`:
  **1 passed** — generation (command) **2.88 s**, job 0.90 s, download (command) **1.01 s**, cash check 0.12 / 0.07 s,
  « Virements » 0.12 s, the debit job 9.7 s, the nightly checks 0.23 s (0.24 s warm), every row read by index but the
  payments' known sequential read (as before: 2.83 s, 1.14 s, 0.13 s, 0.28 s with the duplicate index) — the probe by
  `refund_request_transfer_id_key` keeps the plan linear.
- `test_transfer_line_scale_integration.py`: **7 passed** (156.1 s) — the 500-member lot short of one: options 0.32 /
  0.33 s, booking 1.42 / 1.55 s (499 bookings, the allocation lock held 1.35 s); the saturating lots: options 2.27 /
  2.37 s, the command 2.13 / 2.39 s (`parts_do_not_add_up`); 501 and 5,000 members 0.012 to 0.02 s (`lot_too_large`);
  the 50,000-item draft: options 0.09 s, command 0.16 s, lock 0.12 s.
- `test_debit_bookings_scale_integration.py`: **5 passed** (793.0 s) — « Générer le fichier » of 5,000 payouts 3.66 s;
  the batch line of 5,000 members: the funds pass 24.2 s (27.1 s under auto_explain); 5,000 RMT debits: import 1.3 s,
  the debit job 23.0 s; the nightly checks 1.29 s (1.32 s warm).
- Not timed here (tests-7, ADR-0014 « M2c-6b-3a review fixes » round 1, left to 6b-3a-2): the nightly checks,
  generation's holds and the cancellation evidence over tens of transfers cancelled out of a downloaded file and
  re-issued — the scale fixtures' only cancelled transfers are runs cancelled before any file.

### M2c-6b-3a-2: the late predecessor, the switch off (2026-11-18, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

What the slice changes on a timed path: the nightly checks (`run_payment_checks`' I20 exemption and its « run booked
by its late predecessor » probe, `run_transfer_checks`' `payout_returned`, `run_remittance_runs_checks`' chained runs),
the deadlines' planned branch (`pending_item_deadlines`, the worker's `HELD_TO_SQL`), the booking command's check,
options, locks, text and post, the debit job's `bank_booking_post_rows` (its booked update skips a cancelled transfer),
the release of a file (`transfer_file_release`). Generation and download are unchanged.

- **New:** `test_transfer_cancellation_scale_integration.py` (tests-7, left by 6b-3a's review round 1): 5,000 refunds in
  a downloaded file never executed, beside 40 refunds cancelled with their downloaded file and re-issued, 20 of them
  debited late; the switch on inside one forced-rollback transaction: **1 passed** — set-up 21.7 s; the confirmation of
  the file's cancellation (40 transfers re-issued) **0.11 s**; the evidence of the 5,000-transfer file **0.36 s** (one
  of its transfers 0.10 s); its page with the switch on **0.56 s**; generation with the holds **0.14 s** (20 held
  `already_debited`, 20 in the file); the nightly checks **0.40 s** (41,370 `bank_transfer` rows read for 5,080
  transfers; 20 `cancelled_transfer_debited`, 20 `transfer_already_debited`).
- `test_transfer_files_scale_integration.py` (5,000 refunds in one file): **1 passed** — generation (command) 2.69 s,
  job 0.83 s, download (command) 0.99 s, cash check 0.11 / 0.08 s, « Virements » 0.13 s, the debit job booking the
  5,000 debits 9.8 s (15,000 transfer rows read), the nightly checks 0.26 s, every row read by index but the payments'
  known sequential read (6b-3a: 2.83 s, 1.14 s, …, 10.2 s, 0.28 s).
- `test_transfer_line_scale_integration.py`: **7 passed** (156.4 s) — the 500-member lot short of one: options 0.35 /
  0.39 s, booking 1.41 / 1.53 s (499 bookings, the allocation lock held 1.30 s); the saturating lots: options 2.15 /
  2.34 s, the command 2.19 / 2.33 s (`parts_do_not_add_up`); 501 and 5,000 members 0.013 to 0.02 s (`lot_too_large`);
  the 50,000-item draft: options 0.06 s, command 0.18 s, lock 0.14 s.
- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (318.5 s) — reserved 1.27 s, prepared 10.2 s,
  approval command 0.39 s, job and documents 16.9 s; nightly checks 4.4 s (the draft waiting 5.2 s); cancellation
  3.76 s; 6b-1's re-run prepared and approved 27.7 s, its payout filed, downloaded, debited and booked 0.7 s; the
  nightly checks with the run booked **5.2 s** (5.15 s warm; 6b-2d: 5.4 s / 5.77 s) — `run_payment_checks` 2.7 s and
  `commission_key_open` (50,000 calls) 1.5 s, `run_remittance_runs_checks` 0.55 s.
- `test_debit_bookings_scale_integration.py` (the debit job's booked update changed): **5 passed** (764.7 s) — the
  fixture's approval jobs 479.4 s, « Générer le fichier » for 5,000 payouts (+50 cancelled) 3.26 s; the 5,000-member
  batch line's funds pass 22.4 s (23.8 s under auto_explain); 5,000 RMT debits imported in 1.2 s, the debit job 20.9 s
  in chunks of 8.5, 8.6 and 3.7 s; the nightly checks 1.02 s (1.11 s warm with row counts on); 200 members 0.53 s; 200
  RMT debits imported in 0.3 s and booked in 0.68 s (6b-3a: 782.2 s; 24.1 s, 22.7 s, 1.13 s).

### M2c-6b-3a-2 review fixes, round 1 (2026-11-19, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

What the round changes on a timed path: the hold of a re-issue (`transfer_debited_before`: generation's holds, the
download's re-checks), the late debits' readers (`transfer_late_lines`: the nightly P0, A, B, C and M), the cancellation
evidence, the nightly chained branch (`run_remittance_runs_checks`: `transfer_named_debit_on` per chain transfer of a
chained run), the debit job's R124-6 rows (`bank_booking_post_rows`: the run's chain read per booked payout) and the
booking command's check (the class-U derivation, an unplanned payout's pool, a payout's late date). Each new probe is
keyed: a detail by `bank_transaction_unsplit_details_idx` (GIN `jsonb_path_ops`), the rest by their existing keys.

- `test_transfer_cancellation_scale_integration.py` (CSC-3, tests-6: one client's chained payout run added, SIZE more
  refunds ordered and filed with the re-issues): **1 passed** — set-up 37.9 s; the confirmation of the cancellation
  (41 transfers re-issued) **0.12 s**; the evidence of the 5,000-transfer file **0.40 s** (one of its transfers 0.11 s);
  its page with the switch on **0.55 s**; generation with the holds **2.87 s** (20 held `already_debited`, 5,021 in the
  file); the nightly checks **0.63 s** (86,438 `bank_transfer` rows read for 10,082 transfers; 146,726 in an earlier
  run of the same fixture); the late predecessor's options **0.02 s** and its booking **2.00 s** (its re-issue's
  generated 5,021-transfer file withdrawn, 5,040 refunds ordered again; 1.49 s in an earlier run), under the 4 s bound
  the review asked for (the booking holds the payments and remit locks for its length).
- `test_transfer_files_scale_integration.py` (5,000 refunds in one file): **1 passed** — generation (command) 2.68 s,
  job 0.83 s, download (command) 1.04 s, cash check 0.12 / 0.07 s, « Virements » 0.12 s, the debit job booking the
  5,000 debits 9.4 s (15,000 transfer rows read), the nightly checks 0.22 s (6b-3a-2: 2.69 s, 0.83 s, 0.99 s, …,
  9.8 s, 0.26 s).
- `test_transfer_line_scale_integration.py`: **7 passed** (149.8 s) — the 500-member lot short of one: options 0.41 /
  0.43 s, booking 1.33 / 1.47 s (499 bookings, the allocation lock held 1.23 s); the saturating lots: options 1.99 /
  2.03 s, the command 2.13 / 2.15 s (`parts_do_not_add_up`); 501 and 5,000 members 0.013 to 0.02 s (`lot_too_large`);
  the 50,000-item draft: options 0.06 s, command 0.15 s, lock 0.11 s.
- `test_debit_bookings_scale_integration.py` (the debit job's R124-6 rows now read the run's chain per booked payout):
  **5 passed** (715.3 s) — « Générer le fichier » for 5,000 payouts (+50 cancelled) 3.16 s; the 5,000-member batch
  line's funds pass 21.5 s (23.0 s under auto_explain); 5,000 RMT debits imported in 1.2 s, the debit job 19.9 s in
  chunks of 8.1, 8.0 and 3.6 s; the nightly checks 0.97 s (1.04 s warm with row counts on); 200 members 0.50 s; 200 RMT
  debits imported in 0.3 s and booked in 0.68 s (6b-3a-2: 764.7 s; 22.4 s, 20.9 s, 1.02 s).
- `test_remittance_scale_integration.py` (50,000 lines; its re-run's payout booked by the debit job, the nightly checks
  with a booked run): **1 passed** (257.1 s) — reserved 1.19 s, prepared 9.2 s; nightly checks 4.2 s (the draft waiting
  3.6 s); cancellation 3.50 s; 6b-1's re-run prepared and approved 25.4 s, its payout filed, downloaded, debited and
  booked 0.6 s; the nightly checks with the run booked **4.5 s** (4.72 s warm; 6b-3a-2: 5.2 s / 5.15 s) —
  `run_payment_checks` 2.4 s and `commission_key_open` (50,000 calls) 1.3 s, `run_remittance_runs_checks` 0.37 s.

### M2c-6b-3a-2 review fixes, round 2 (2026-11-19, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

What the round changes on a timed path: `private.transfer_unplanned_open` and `private.transfer_line_open_unplanned`
read the run's payout chain of a return's transfer (`private.transfer_chain_unplanned`: the transfer, its run, the chain,
each one's bookings by key) — the debit job's facts of a return, its SQL re-check, a lot credit's returnable members, the
options of a return; and the nightly checks take the booked runs whose chain holds a payout cancelled out of a downloaded
file (`bank_transfer_cancelled_filed_idx`), each judged at `private.remittance_run_paid_on` once a return of its chain is
seen.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (50.7 s) — set-up 37.9 s; the confirmation 0.11 s; the
  evidence of the 5,000-transfer file 0.51 s (one transfer 0.11 s); its page 0.57 s; generation with the holds 3.00 s (20
  held, 5,021 in the file); the nightly checks **0.67 s** (86,479 `bank_transfer` rows read; round 1: 0.63 s, 86,438);
  the late predecessor's options 0.02 s, its booking 1.89 s.
- `test_transfer_files_scale_integration.py`: **1 passed** (35.5 s) — generation (command) 2.74 s, job 0.80 s, download
  (command) 1.19 s, cash check 0.11 / 0.08 s, « Virements » 0.13 s, the debit job booking the 5,000 debits 9.8 s (15,000
  transfer rows read), the nightly checks 0.25 s (round 1: 2.68 s, 0.83 s, 1.04 s, …, 9.4 s, 0.22 s).
- `test_transfer_line_scale_integration.py`: **7 passed** (156.4 s) — the 500-member lot short of one: options 0.43 /
  0.47 s, booking 1.40 / 1.77 s (499 bookings, the allocation lock held 1.51 s); the saturating lots: options 2.25 /
  2.13 s, the command 2.20 / 2.27 s (`parts_do_not_add_up`); 501 and 5,000 members 0.03 / 0.012 s (`lot_too_large`); the
  50,000-item draft: options 0.06 s, command 0.17 s, lock 0.12 s (round 1: 0.41 / 0.43, 1.33 / 1.47, 1.99 / 2.03, 2.13 /
  2.15 s; every budget held).
- `test_debit_bookings_scale_integration.py`: **5 passed** (748.9 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 3.46 s; the 5,000-member batch line's funds pass 23.0 s (23.6 s under auto_explain); 5,000 RMT debits
  imported in 1.2 s, the debit job 20.9 s in chunks of 8.3, 8.4 and 4.0 s; the nightly checks **1.10 s** (1.20 s warm;
  `run_remittance_runs_checks` 0.22 s); 200 members 0.46 s; 200 RMT debits booked in 0.68 s (round 1: 715.3 s; 21.5 s,
  19.9 s, 0.97 s).
- `test_remittance_scale_integration.py` (50,000 lines; the nightly checks with a booked run): **1 passed** (309.6 s) —
  reserved 1.21 s, prepared 9.5 s; nightly checks 4.3 s (the draft waiting 3.5 s); cancellation 3.59 s; the re-run
  prepared and approved 26.3 s, its payout filed, downloaded, debited and booked 0.7 s; the nightly checks with the run
  booked **5.0 s** (4.83 s warm; round 1: 4.5 s / 4.72 s) — `run_payment_checks` 2.7 s, `commission_key_open` (50,000
  calls) 1.4 s, `run_remittance_runs_checks` 0.50 s (its booked-chain branch reads the servicer's cancelled filed
  transfers by key: none booked in this fixture).

### M2c-6b-3a-2 review fixes, round 3 (2026-11-19, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

What the round changes on a timed path: the nightly checks' booked-chain branch (`run_remittance_runs_checks`) reads
`private.transfer_return_known` for each transfer of the chains it takes (a run booked whose chain holds a payout
cancelled out of a downloaded file, by `bank_transfer_cancelled_filed_idx`): `transfer_return_seen`, one probe of
`bank_transaction_unsplit_details_idx` for a credit detail and the transfer's return bookings by
`bank_line_booking_transfer_idx`; `remittance_run_paid_on` reads it too, and a booked line's other bookings no longer
drop it. Nothing else timed changed.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (49.7 s) — set-up 37.1 s; the confirmation 0.15 s; the
  evidence of the 5,000-transfer file 0.47 s (one transfer 0.14 s); its page 0.65 s; generation with the holds 2.79 s
  (20 held, 5,021 in the file); the nightly checks **0.65 s** (86,479 `bank_transfer` rows read; round 2: 0.67 s,
  86,479); the late predecessor's options 0.03 s, its booking 1.89 s.
- `test_transfer_files_scale_integration.py`: **1 passed** (36.3 s) — generation (command) 2.68 s, job 0.82 s, download
  (command) 1.10 s, cash check 0.12 / 0.07 s, « Virements » 0.18 s, the nightly checks 0.23 s (0.27 s warm; round 2:
  2.74 s, 0.80 s, 1.19 s, …, 0.25 s).
- `test_transfer_line_scale_integration.py`: **7 passed** (155.8 s) — the 500-member lot short of one: options 0.45 /
  0.45 s, booking 1.55 / 1.57 s (499 bookings, the allocation lock held 1.35 s); the saturating lots: options 2.19 /
  2.16 s, the command 2.24 / 2.16 s (`parts_do_not_add_up`); 501 and 5,000 members 0.02 / 0.013 s (`lot_too_large`);
  the 50,000-item draft: options 0.07 s, command 0.18 s, lock 0.14 s (round 2: 156.4 s; every budget held).
- `test_debit_bookings_scale_integration.py`: **5 passed** (747.5 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 3.57 s; the 5,000-member batch line's funds pass 22.3 s (23.6 s under auto_explain); 5,000 RMT debits
  imported in 1.2 s, the debit job 21.1 s in chunks of 8.5, 8.4 and 4.0 s; the nightly checks **1.22 s** (1.20 s warm;
  `run_remittance_runs_checks` 0.23 s); 200 members 0.47 s; 200 RMT debits booked in 0.73 s (round 2: 748.9 s; 23.0 s,
  20.9 s, 1.10 s).
- `test_remittance_scale_integration.py` (50,000 lines; the nightly checks with a booked run): **1 passed** (307.0 s) —
  reserved 1.26 s, prepared 9.3 s; nightly checks 4.1 s (the draft waiting 3.4 s); cancellation 3.62 s; the re-run
  prepared and approved 25.7 s, its payout filed, downloaded, debited and booked 0.7 s; the nightly checks with the run
  booked **4.7 s** (4.74 s warm; round 2: 5.0 s / 4.83 s) — `run_payment_checks` 2.6 s, `commission_key_open` (50,000
  calls) 1.3 s, `run_remittance_runs_checks` 0.47 s.

### M2c-6b-3a-2 review fixes, round 4 (2026-11-19, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

What the round changes on a timed path: one rule for the date a run's client stayed paid
(`private.remittance_chain_events`, `private.remittance_chain_paid`) replaces `transfer_named_debit_on` and
`transfer_return_known`. Its events are read per transfer of a run's payout chain by key (the transfer's id lines by
`bank_transaction_end_to_end_idx` and `bank_transaction_return_e2e_idx`, its details by
`bank_transaction_unsplit_details_idx`, its PmtInf lines, its bookings by `bank_line_booking_transfer_idx`), only for
runs whose chain holds another transfer: the booking (`bank_booking_post_rows`) and the sheet's late flag keep the
line's date for a run with no other transfer (the 5,000 payouts of the scale fixture), the nightly reads it for the
chained branch's runs and for the booked runs whose chain holds a payout cancelled out of a downloaded file. Nothing
else timed changed.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (52.5 s) — set-up 39.0 s; the confirmation 0.14 s; the
  evidence of the 5,000-transfer file 0.41 s (one transfer 0.15 s); its page 0.61 s; generation with the holds 3.24 s
  (20 held, 5,021 in the file); the nightly checks **0.65 s** (86,479 `bank_transfer` rows read; round 3: 0.65 s,
  86,479); the late predecessor's options 0.03 s, its booking 2.13 s (round 3: 1.89 s).
- `test_transfer_files_scale_integration.py`: **1 passed** (37.8 s) — generation (command) 2.80 s, job 0.90 s, download
  (command) 1.41 s, cash check 0.13 / 0.08 s, « Virements » 0.13 s, the nightly checks 0.25 s (0.29 s warm; round 3:
  2.68 s, 0.82 s, 1.10 s, …, 0.23 s).
- `test_transfer_line_scale_integration.py`: **7 passed** (170.4 s) — the 500-member lot short of one: options 0.49 /
  0.48 s, booking 1.72 / 1.62 s (499 bookings, the allocation lock held 1.40 s); the saturating lots: options 2.29 /
  2.50 s, the command 2.28 / 2.53 s (`parts_do_not_add_up`); 501 and 5,000 members 0.03 / 0.014 s (`lot_too_large`);
  the 50,000-item draft: options 0.07 s, command 0.17 s, lock 0.13 s (round 3: 155.8 s; every budget held).
- `test_debit_bookings_scale_integration.py`: **5 passed** (773.5 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 3.55 s; the 5,000-member batch line's funds pass 23.3 s (24.7 s under auto_explain); 5,000 RMT debits
  imported in 1.2 s, the debit job 22.5 s in chunks of 9.0, 8.9 and 4.5 s; the nightly checks **1.13 s** (1.12 s warm;
  `run_remittance_runs_checks` 0.21 s); 200 members 0.50 s; 200 RMT debits booked in 0.68 s (round 3: 747.5 s; 22.3 s,
  21.1 s, 1.22 s).
- `test_remittance_scale_integration.py` (50,000 lines; the nightly checks with a booked run): **1 passed** (301.2 s) —
  reserved 1.24 s, prepared 9.7 s; nightly checks 4.2 s; cancellation 3.74 s; the re-run prepared and approved 27.6 s,
  its payout filed, downloaded, debited and booked 0.7 s; the nightly checks with the run booked **5.0 s** (5.42 s warm;
  round 3: 4.7 s / 4.74 s) — `run_payment_checks` 2.5 s, `commission_key_open` (50,000 calls) 1.5 s,
  `run_remittance_runs_checks` 0.50 s.

### M2c-6b-3b part 1: the last switch-on prerequisites, the switch off (2026-11-20, same VM: 4 vCPU, 16 GB RAM, the main stack alone, each run right after `supabase db reset`)

What the slice changes on a timed path: for a run whose payout chain holds another transfer only, the booking of its
payout (`bank_booking_post_rows`), its sheet's late flag (`transfer_line_check`) and the nightly check's booked branch
(`run_remittance_runs_checks`) read the two holds (`private.remittance_chain_holds`: `statement_covers` over [least(e0,
L), L] and, per other transfer of the chain handed out, `private.transfer_debit_lines` — the predicate
`transfer_debit_suppression` has read since 6b-2c, moved — against the chain's events, by key); the booked branch now
takes every booked run whose chain holds a payout cancelled out of a downloaded file and that has a late line without a
row, not only those with a return seen. A run with no other transfer (the 5,000 payouts, the 50,000-line run) keeps
its line's date and reads no hold. Nothing else timed changed.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (49.2 s) — set-up 37.0 s; the confirmation 0.13 s; the
  evidence of the 5,000-transfer file 0.38 s (one transfer 0.10 s); its page 0.60 s; generation with the holds 2.62 s
  (20 held, 5,021 in the file); the nightly checks **0.63 s** (86,479 `bank_transfer` rows read; round 4: 0.65 s,
  86,479); the late predecessor's options 0.03 s, its booking **1.86 s** (round 4: 2.13 s).
- `test_debit_bookings_scale_integration.py`: **5 passed** (780.6 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 3.38 s; the 5,000-member batch line's funds pass 20.5 s (20.8 s under auto_explain); 5,000 RMT debits
  imported in 1.2 s, the debit job 18.7 s in chunks of 7.9, 7.2 and 3.5 s; the nightly checks **1.06 s** (1.08 s warm;
  `run_remittance_runs_checks` 0.21 s); 200 members 0.53 s; 200 RMT debits booked in 0.76 s (round 4: 773.5 s; 23.3 s,
  22.5 s, 1.13 s).
- `test_remittance_scale_integration.py` (50,000 lines; the nightly checks with a booked run): **1 passed** (253.6 s) —
  reserved 1.16 s, prepared 9.4 s; nightly checks 4.1 s (the draft waiting 3.7 s); cancellation 3.73 s; the re-run
  prepared and approved 25.3 s, its payout filed, downloaded, debited and booked 0.8 s; the nightly checks with the run
  booked **4.8 s** (4.84 s warm; round 4: 5.0 s / 5.42 s) — `run_payment_checks` 2.5 s, `commission_key_open` (50,000
  calls) 1.3 s, `run_remittance_runs_checks` 0.54 s.

### M2c-6b-3b part 1 review fixes, round 1 (2026-11-21, same VM, the main stack alone, each run right after `supabase db reset`)

What the round changes on a timed path: the nightly check's in-flight branch judges each run in flight with an overdue
line through `private.remittance_inflight_judge` (its facts read by `private.remittance_inflight_facts` in one
snapshot — the same functions the branch read inline: `statement_covers`, `transfer_debit_seen`,
`transfer_debit_lines`, the chain's paid date for a chained run — and read again only when a proof rests on the options
of an old line); the holds of a chained run read their facts once (`private.remittance_chain_hold_facts`) and again only
after an 'expired'; the booked branch also reads the standing payout's line date. A run with no other transfer reads no
hold at its booking, as before.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (50.1 s) — set-up 37.8 s; the confirmation 0.11 s;
  the evidence of the 5,000-transfer file 0.34 s; its page 0.51 s; generation with the holds 2.63 s (20 held, 5,021 in
  the file); the nightly checks **0.80 s** (86,479 `bank_transfer` rows read, as before; part 1: 0.63 s, a single run
  each); the late predecessor's options 0.04 s, its booking **1.94 s** (part 1: 1.86 s).
- `test_debit_bookings_scale_integration.py`: **5 passed** (743.7 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 3.36 s; the 5,000-member batch line's funds pass 19.7 s (20.0 s under auto_explain); 5,000 RMT debits
  imported in 1.0 s, the debit job 18.1 s in chunks of 7.7, 6.9 and 3.4 s; the nightly checks **1.03 s** (1.01 s warm;
  `run_remittance_runs_checks` 0.22 s; part 1: 1.06 s).
- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (262.7 s) — reserved 1.18 s, prepared 9.3 s;
  nightly checks 3.8 s (the draft waiting 3.4 s); the re-run prepared and approved 24.9 s, its payout booked 0.7 s; the
  nightly checks with the run booked **4.4 s** (4.53 s warm; part 1: 4.8 s) — `run_payment_checks` 2.3 s,
  `commission_key_open` (50,000 calls) 1.2 s, `run_remittance_runs_checks` 0.41 s.

### M2c-6b-3b part 1 — CI round (PR #38) (2026-11-21, same VM, the main stack alone, the run right after `supabase db reset`)

What the round changes on a timed path: `private.post_bank_bookings`' re-check (the keys, the locks, the facts and the
verdicts) runs in `private.bank_booking_recheck` under `enable_seqscan = off` — the same statements, every keyed read a
probe of its index whatever the statistics; the posting keeps its callers' settings (ADR-0014 « M2c-6b-3b part 1 — CI
round (PR #38) »). The db suite's 2,000-member batch line: the facts 22,012 rows, the keys 32,010, the batch rule 40,014
(36,015 before: sorted and merged, no longer hashed), the bank-account lock 24,016 (16,012) — the same under a probe
priced at 1,000 pages, where the old body's facts handled 8.0 million rows.

- `test_debit_bookings_scale_integration.py`: **5 passed** (782.8 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 3.20 s; the 5,000-member batch line's funds pass **20.3 s** (21.6 s under auto_explain; round 1: 19.7 s /
  20.0 s), no sequential read of a table of transfers, no temporary file; 5,000 RMT debits imported in 1.3 s, the debit
  job **19.1 s** in chunks of 7.9, 7.3 and 3.6 s (round 1: 18.1 s; 7.7, 6.9, 3.4 s); the nightly checks 1.14 s (1.03 s
  warm; `run_remittance_runs_checks` 0.22 s); 200 members 0.52 s; 200 RMT debits' job 0.60 s. Within the run-to-run
  spread of the earlier rounds (19.1 to 26.4 s for the funds pass, 18.1 to 23.0 s for the debit job): no timing changed.

### M2c-6b-3b part 2: the held-rows alert, the booking guard keyed (2026-11-21, same VM, the main stack alone, each run right after `supabase db reset`)

What the slice changes on a timed path: the nightly checks read the booked branch's runs through
`private.remittance_booked_chain_runs` (its CTEs moved there unchanged) and, in the results' statement, the held rows'
alert (`private.remittance_breach_held`: the same runs again, then, for a run with a late line still without a row, the
holds' facts per date held to and the uncovered days one by one) — only chained runs reach the second read; the booking
guard (`private.bank_line_booking_guard()`, a statement trigger on every booking) runs under `enable_seqscan = off`
with its one join read by key. The db suite's 2,000-member batch line posted in one statement, a probe priced at 1,000
pages and the guard's tables' statistics forgotten: the guard's statement **48,001 rows** (the old body 36,258,001;
`enable_seqscan = off` alone 12,052,001).

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (51.4 s) — set-up 38.9 s; the confirmation 0.12 s; the
  evidence of the 5,000-transfer file 0.41 s (one transfer 0.097 s); its page 0.52 s; generation with the holds 2.64 s
  (20 held, 5,021 in the file); the nightly checks **0.67 s** (86,520 `bank_transfer` rows read; part 1 round 1: 0.80 s);
  the late predecessor's options 0.05 s, its booking **1.84 s** (part 1 round 1: 1.94 s).
- `test_remittance_scale_integration.py` (50,000 lines; the nightly checks with a booked run): **1 passed** (262.1 s) —
  reserved 1.12 s, prepared 9.9 s; nightly checks 4.0 s (the draft waiting 3.6 s); cancellation 3.30 s; the re-run
  prepared and approved 26.1 s, its payout filed, downloaded, debited and booked 1.0 s; the nightly checks with the run
  booked **4.4 s** (4.70 s warm; part 1 round 1: 4.4 s) — `run_payment_checks` 2.5 s, `commission_key_open` (50,000
  calls) 1.1 s, `run_remittance_runs_checks` 0.31 s.
- `test_debit_bookings_scale_integration.py`: **5 passed** (812.0 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 3.35 s; the 5,000-member batch line's funds pass **23.1 s** (22.2 s under auto_explain); 5,000 RMT debits
  imported in 1.3 s, the debit job **20.5 s** in chunks of 8.1, 7.9 and 4.2 s (each posting its bookings through the
  guard); the nightly checks **1.06 s** (0.92 s warm; `run_remittance_runs_checks` 0.21 s); 200 members 0.52 s; 200 RMT
  debits' job 0.68 s. Within the run-to-run spread of the earlier rounds (19.1 to 26.4 s for the funds pass, 18.1 to
  23.0 s for the debit job).

### M2c-6b-3b part 2, review round 1: the funds pass's posting under enable_seqscan off (2026-11-21, same VM, the main stack alone, each run right after `supabase db reset`)

What the round changes on a timed path: `private.bank_booking_post_rows` (the funds pass's posting: entries, bookings,
transfers, runs, R124-6 rows) runs under `enable_seqscan = off` (its body unchanged), and so do the statements its
triggers run (the booking guard inherits it). It was found by the guard's test once that test stores a first batch
line: the posting's last-seq read of `bank_line_booking`, a correlated subquery per new booking, read the table whole
per row when priced below a probe — **4,024,001 rows** for the second 2,000-member line (2,000 stored rows each time);
now a probe of the primary key, the statement within its bound. The alert's texts changed, not its SQL.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (49.8 s) — set-up 37.7 s; the evidence of the
  5,000-transfer file 0.39 s; generation with the holds 2.82 s (20 held, 5,021 in the file); the nightly checks
  **0.50 s** (86,520 `bank_transfer` rows read; part 2: 0.67 s); the late predecessor's options 0.03 s, its booking
  **1.44 s** (part 2: 1.84 s).
- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (258.5 s) — prepared 9.3 s; nightly checks 3.9 s
  (the draft waiting 3.6 s); cancellation 3.51 s; the re-run prepared and approved 26.5 s, booked 0.8 s; the nightly
  checks with the run booked **4.7 s** (4.23 s warm; part 2: 4.4 s) — `run_payment_checks` 3.0 s, `commission_key_open`
  (50,000 calls) 1.1 s, `run_remittance_runs_checks` 0.35 s.
- `test_debit_bookings_scale_integration.py`: **5 passed** (802.0 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 2.79 s; the 5,000-member batch line's funds pass **21.6 s** (21.8 s under auto_explain, the same heaviest
  statements as before: the ledger's own `_lps_dim` and `_lps_x`); 5,000 RMT debits imported in 1.2 s, the debit job
  **19.4 s** in chunks of 8.1, 7.7 and 3.5 s; the nightly checks **1.29 s** (1.23 s warm; `run_remittance_runs_checks`
  0.30 s); 200 members 0.46 s; 200 RMT debits' job 0.60 s. Within the earlier rounds' spread (19.1 to 26.4 s for the
  funds pass, 18.1 to 23.0 s for the debit job).

### M2c-6b-3b part 3: the held rows' alert at volume (2026-11-21, same VM, the main stack alone)

What the slice changes on a timed path: the nightly checks read the booked chained runs once (`pg_temp._rc_runs`) and
every line due at their dates with its hold's findings once (`private.remittance_chain_judged`, `pg_temp._rc_lines`; the
holds now return the possible debits they judged on); « remittance_breach_held » reads those two tables, its uncovered
days once per paying account and window. The booking path's `private.remittance_chain_rows` filters
`private.remittance_chain_judged` (the same rows, one more function layer).

**The volume case** (new, `test_breach_held_scale_integration.py`, CI's `scale-payouts` job): 2,000 payouts of one downloaded
file cancelled whole and re-issued, the re-issues filed, downloaded and debited today under their own ids (the debit
job's funds pass books them: each run booked by its re-issue), each run's lines held to L, the business day M after the
evidence statement on no statement and, for half the runs (their x dated a business day earlier, W), W too: every run
held, alerted; then W's and M's statements imported, every row written the next night. Measured on one committed
fixture (the scenario rolled back each time), each value from two runs:

| | before the dedups (part 2) | after |
|---|---|---|
| nightly checks, 2,000 held chained runs, two windows | **28.5 s**, 29.1 s | **12.8 s**, 13.0 s |
| the standalone reading (`private.remittance_breach_held`, part 2's alert alone) | 13.4 s, 13.6 s | (not called by the checks) |
| the next night, every row written (no alert) | 20.3 s, 23.4 s | 14.6 s, 15.1 s |
| the funds pass booking the 2,000 re-issues | 21.3 s, 20.6 s | 17.9 s, 18.8 s |
| calls in the nightly checks: `remittance_booked_chain_runs` | 2 | **1** |
| `remittance_chain_hold_facts` | 4,000 | **2,000** |
| `remittance_chain_paid` / `remittance_chain_events` | 8,000 / 8,000 (19.3 s own) | 4,000 / 4,000 (7.3 s own) |
| `remittance_run_late_lines` | 8,000 | **4,000** |
| `statement_covers` | 15,000 | **2,013** (2,000 holds + 2 windows + 11 days) |
| `transfer_chain` | 18,000 | 10,000 |

What remains (12.8 s) is the booked branch's own reading of each chain — the chain's paid date and events read for the
runs and again in the holds' one-snapshot facts (part 1's race fix) — above plan §1.4's 5 s, which is for 5,000 booked
payouts without chains: recorded in ADR-0014 « M2c-6b-3b part 3 », left open (low). The test's bound: 37 s for each
night (twice the worst after, the scale file's own run on a freshly reset stack below: 18.1 s), and the calls exactly.

The scale files that time what the slice changes, each once, each right after `supabase db reset` (same VM, the main
stack alone):

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (51.0 s) — set-up 38.5 s; the evidence of the
  5,000-transfer file 0.36 s; generation with the holds 2.66 s (20 held, 5,021 in the file); the nightly checks
  **0.68 s** (86,479 `bank_transfer` rows read; part 2's round 1: 0.50 s); the late predecessor's options 0.03 s, its
  booking **1.76 s** (part 2's round 1: 1.44 s).
- `test_breach_held_scale_integration.py` (new, 2,000 held chained runs): **1 passed** (363.2 s) — the fixture's runs
  requested, prepared and approved 248.0 s; the cancellation confirmed 6.51 s; the funds pass booking the 2,000
  re-issues 22.4 s; the nightly checks **18.14 s** (2,000 alerts; `remittance_chain_events` 4,000 calls, 9.0 s own;
  `remittance_chain_hold_facts` 2,000 calls) against the standalone reading's 12.91 s; once W and M are imported, the
  nightly checks **18.11 s** (2,000 rows written, no alert). Slower than the fixture measured again above (12.8–13.0
  s): here the scenario runs right after the fixture is written, as in CI, where the remeasure ran on a fixture
  committed long before (its tables analysed by autovacuum: the likely difference); the bound (37 s) keeps twice this
  run.
- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (302.5 s) — prepared 11.2 s; nightly checks
  4.2 s (the draft waiting 3.9 s); cancellation 3.33 s; the re-run prepared and approved 26.0 s, booked 0.8 s; the
  nightly checks with the run booked **4.73 s** (5.15 s warm; part 2's round 1: 4.7 s) — `run_payment_checks` 2.6 s,
  `commission_key_open` (50,000 calls) 1.2 s, `run_remittance_runs_checks` 0.51 s.
- `test_debit_bookings_scale_integration.py`: **5 passed** (858.8 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 4.59 s; the 5,000-member batch line's funds pass **24.1 s** (26.2 s under auto_explain, the same heaviest
  statements: the ledger's own `_lps_dim` and `_lps_x`); 5,000 RMT debits imported in 1.3 s, the debit job **22.5 s** in
  chunks of 9.2, 8.6 and 4.5 s; the nightly checks **1.28 s** (1.38 s warm; `run_remittance_runs_checks` 0.28 s); 200
  members 0.48 s; 200 RMT debits' job 0.63 s. Within the earlier rounds' spread (19.1 to 26.4 s for the funds pass,
  18.1 to 23.0 s for the debit job).

CI's `scale-payouts` job now runs the held runs' file after the payouts' bookings (the `scale` job took 27.6 of its 30
minutes on `main`, the run of 2026-11-21 08:13 UTC; `scale-payouts` 12.4 of its 40). Its command, after `supabase db
reset`: **6 passed** in 1,178.5 s (19.6 min) — the 5,000-member line's funds pass 24.0 s, the debit job 19.9 s, the
nightly checks 1.13 s; then the 2,000 held chained runs: the funds pass 18.2 s, the nightly checks **13.41 s** (the
standalone reading 11.35 s), once the days are imported **12.57 s**.

### M2c-6b-3b part 3 review fixes (2026-11-21, same VM, the main stack alone)

What the round changes on a timed path: the alert aggregates its days and waiting lines once per run (cost-1) and
reads the waiting lines' bookings and links by key; its details gain `last_uncovered_day`; and
`private.transfer_line_offers` reads its answer in a subtransaction rolled back once read (the options' working tables
and their locks released at once).

**The waiting lines' variant** (new, in `test_breach_held_scale_integration.py`'s scenario, rolled back to a savepoint
after the first night): x requested from W, W's statement holding two debits without our references of x's amount for
each run of the half dated back (and one credit of their total), M's: every window covered; 1,000 runs alerted with
their two lines each, 1,000 runs' rows written. **Before the offers fix it failed the whole check** — « out of shared
memory », `max_locks_per_transaction` (64) exhausted by the options' working tables, dropped and created again at each
of the 1,000 calls, each dropped table's lock held to the end of the check's transaction (60 relation locks per call:
`042` #26 measures 180 for three calls before, 0 after). After it: **52.8 s** and **55.3 s** (two runs, each right after a reset) — the holds asking the options of each
run's first line (1,000 calls of `private.transfer_line_check`, 11.5 s own; `private.remittance_chain_events` 5,000
calls, 10.1 s; `private.transfer_debit_lines` 2,000 calls, 6.4 s), the alert itself a fraction of a second. Its bound:
110 s (twice the first measure, 52.8 s; the holds' own cost, not the alert's, is what it guards).

**Option 1 of dt3-race, measured, not built**: each alerted run's paid date read again
(`private.remittance_chain_paid` for the 2,000 runs) **4.21 s** and **4.71 s** — against the night's 14.68 s and
15.48 s (about 30 %).

The scale files that time what the round changes, each once, each right after `supabase db reset`:

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (50.3 s) — set-up 38.3 s; generation with the holds
  2.64 s; the nightly checks **0.67 s** (86,479 `bank_transfer` rows read; part 3: 0.68 s); the late predecessor's
  booking 1.67 s.
- `test_breach_held_scale_integration.py` (2,000 held chained runs; after the offers fix and its variant's bound): **1
  passed** (449.0 s) — the fixture's runs requested, prepared and approved 267.1 s; the cancellation confirmed 6.10 s;
  the funds pass booking the 2,000 re-issues 18.8 s; the nightly checks **15.48 s** (2,000 alerts;
  `remittance_chain_events` 4,000 calls, 8.6 s own; part 3: 18.14 s) against the standalone reading's 11.94 s; the
  waiting lines' variant **55.25 s** (1,000 alerts with two lines each, 1,000 runs' rows written; `transfer_line_check`
  1,000 calls, 12.2 s own); once W and M are imported, the nightly checks **18.07 s** (2,000 rows written, no alert;
  part 3: 18.11 s). Its first run (before the variant had its own bound) measured 14.68 s, 52.80 s and 16.32 s.
- `test_remittance_scale_integration.py` (50,000 lines; before the offers fix, which it does not call): **1 passed**
  (259.7 s) — prepared 9.8 s; nightly checks 4.0 s (the draft waiting 3.7 s); cancellation 3.73 s; the re-run prepared
  and approved 28.1 s; the nightly checks with the run booked **4.6 s** (4.69 s warm; part 3: 4.73 s) —
  `run_payment_checks` 2.5 s, `commission_key_open` (50,000 calls) 1.26 s, `run_remittance_runs_checks` 0.44 s.
- `test_debit_bookings_scale_integration.py`: **5 passed** (802.7 s) — « Générer le fichier » for 5,000 payouts (+50
  cancelled) 2.83 s; the 5,000-member batch line's funds pass **22.6 s**; 5,000 RMT debits imported in 1.2 s, the debit
  job **19.4 s** in chunks of 7.8, 8.0 and 3.3 s; the nightly checks **1.23 s** (1.24 s warm; `run_remittance_runs_checks`
  0.27 s); 200 members 0.53 s; 200 RMT debits' job 0.77 s. Within the earlier rounds' spread.

### M2c-6b-3b part 3 — CI round (PR #40) (2026-11-21, same VM, the main stack alone)

What the round changes on a timed path: in the nightly checks, `private.run_transfer_checks` reads a cancelled
refund's chain forward by key (`private.transfer_reissues`) instead of every waiting refund of the servicer, with its
transfer and chain, once per cancelled refund debited late (ADR-0014 « M2c-6b-3b part 3 — CI round (PR #40) »).

The transfer-cancellation file's world after the scale job's six earlier files (5,000 + 5,040 refunds, 40 cancelled
out of a downloaded file, 20 debited late), its nightly checks on one committed state, each variant in the same
rolled-back transaction: `bank_transfer` rows read **486,480** with `refund_request` analysed (CI run 44909449352:
486,480, 3.41 s) and 86,480 with it never analysed (main's CI run: 86,521, 0.88 s) — **75,850** fixed, either way.

The scale job's command as `ci.yml` runs it, right after `supabase db reset` with CI's logging settings: **15 passed**
(1,421.5 s):

- `test_transfer_cancellation_scale_integration.py`: the nightly checks **0.63 s**, **75,850** `bank_transfer` rows (its
  bound 183,008; part 3 review fixes, alone: 0.67 s, 86,479); set-up 40.6 s; the cancellation confirmed 0.11 s;
  generation with the holds 2.76 s; the late predecessor's booking 1.87 s.
- `test_remittance_scale_integration.py` (50,000 lines): nightly checks with the run booked **5.4 s**
  (`run_payment_checks` 2.86 s own, `run_remittance_runs_checks` 0.61 s; main's CI run 5.1 s, this PR's 4.9 s; part 3
  review fixes 4.6 s).
- `test_transfer_files_scale_integration.py`: nightly checks 0.32 s, 25,083 `bank_transfer` rows (its bound 32,000;
  this PR's CI run 25,084, main's 10,001 — replayed afterwards on the committed world, 16,046 with this round's bodies,
  main's and PR #40's alike: the statistics', not the bodies').
- The others within the earlier spread: 50,000 credits imported and matched 30.6 s, allocated 73.2 s; the statement
  50,000 credits 44.0 s; 25 receipt jobs 71.7 s (14.3 ms per receipt); the 50k boarding 111 s; the camt.053 import job
  28.2 s; 500 runs' approval jobs 136.7 s, the 500-member lot short of one 0.41 s / 1.78 s.

The `scale-payouts` job's command, right after `supabase db reset` with CI's logging settings: **6 passed** (1,348.8 s)
— the 5,000-member batch line's funds pass **22.9 s**, the debit job **23.0 s** in chunks of 9.2, 8.8 and 4.8 s, the
nightly checks **1.08 s**; the 2,000 held chained runs: the nightly checks **14.89 s** (the standalone reading 11.09 s),
the night the rows are written **14.90 s**, the waiting lines' variant **64.03 s** (bound 110 s; part 3 review fixes
52.8 and 55.3 s), each run's paid date read again 5.15 s. This round's change is not on those paths (no cancelled
refund in them); the 10 to 20 % over part 3's figures on the debit job and the variant is this VM's run-to-run spread
(18.1 to 23.0 s for the debit job across the earlier rounds).

### M2c-7a: remitted reversals covered, and the backstop (2026-11-21, same VM, the main stack alone, each run right after `supabase db reset`)

What the slice changes on a timed path: the funds pass's booking (`private.bank_booking_post_rows` step 3b: the booked
runs' reversed lines covered, keyed by each run's live lines and each line's reversal; then the deferred
`remittance_run_booked_cover` check on each run set booked), the approval of an N = 0 run (the same cover), the nightly
checks (`private.run_advance_checks` after `run_transfer_checks`: the day's reversals by
`ledger_entry_reversal_posted_idx`, the runs booked since by `remittance_run_booked_idx`, the attributions since by
`unplanned_paid_item_org_idx`, the covers since; `advance_ledger` and `advance_open` per servicer), an unplanned
payout's return (`private.transfer_line_post`: the release), « Désimputer » and the M2b returns (the cover in the
reversal's transaction; no scale file reverses at volume: their cost is one keyed read per reversal). None of the
scale files posts a reversal of a remitted entry, so their numbers measure what the new reads and checks add to the
paths they already time.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (51.0 s) — set-up 39.0 s; the evidence of the
  5,000-transfer file 0.31 s; generation with the holds 2.82 s (20 held, 5,021 in the file); the nightly checks
  **0.66 s** (75,849 `bank_transfer` rows read; 6b-3b part 3: 0.68 s); the late predecessor's options 0.03 s, its
  booking **1.69 s** (6b-3b part 3: 1.76 s).
- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (299.7 s) — reserved 1.05 s, prepared 9.6 s;
  nightly checks 3.9 s (the draft waiting 3.7 s); cancellation 3.30 s; the re-run prepared and approved 26.2 s, its
  payout booked **0.9 s** (the funds pass 0.3 s); the nightly checks with the run booked **4.49 s** (4.58 s warm;
  6b-3b part 3: 4.73 s) — `run_payment_checks` 2.4 s, `commission_key_open` (50,000 calls) 1.2 s,
  `run_remittance_runs_checks` 0.47 s; `run_advance_checks` is not among the five costliest functions (each of those
  above 40 ms own): the run booked today and its 50,000 lines read once, each line's reversal by key — `ledger_entry`
  211,627 rows read by index, none by a sequential scan.
- CI's `scale-payouts` command as the workflow runs it (`test_debit_bookings_scale_integration.py` then
  `test_breach_held_scale_integration.py`), after `supabase db reset`: **6 passed** in 1,251.1 s (20.9 min) — 200
  members' batch line 0.54 s, 200 RMT debits' job 0.72 s; « Générer le fichier » for 5,000 payouts (+50 cancelled)
  3.24 s; the 5,000-member batch line's funds pass **22.6 s** (22.2 s under auto_explain; 6b-3b part 3: 24.0–24.1 s);
  the nightly checks **0.98 s** (1.10 s warm); 5,000 RMT debits imported in 1.2 s, the debit job **20.2 s** in chunks
  of 8.0, 8.5 and 3.6 s (6b-3b part 3: 19.9–22.5 s); then the 2,000 held chained runs: the funds pass 19.5 s, the
  nightly checks **13.98 s** (the standalone reading 12.10 s; part 3: 13.41 s), once the days are imported **15.87 s**
  (part 3: 12.57 s; its review fixes 14.90 s). Within the earlier rounds' spread on this VM (no line of these runs is
  reversed: the at-booking cover reads each run's lines and finds nothing to cover; the funds pass reads no
  `client_advance` row).

`test_allocation_scale_integration.py` (50,000 allocations) is not run: the allocation path is unchanged (the cover is
posted by the reversals only).

### M2c-7a review fixes, round 1 (2026-11-22, same VM, the main stack alone, each run right after `supabase db reset`)

What the round changes on a timed path: the nightly checks' `private.run_advance_checks` (CC-1: the runs whose payout
booking was recorded since the last check run, read by `bank_line_booking_org_idx` and each transfer's run by key,
beside the runs booked since; CC-2: every window a key range — `-infinity` for the full pass — instead of a
`v_full or …` filter a cached generic plan cannot use as an index condition). `private.run_settled_at` (an N = 0 run's
own return not followed) is read by `advance_open` for advances over 30 days only, none in these files; « Désimputer »,
`allocation_remitted` and `request_full_advance_check` are not on a timed path.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (51.2 s) — set-up 38.6 s; the evidence of the
  5,000-transfer file 0.37 s; generation with the holds 2.99 s (20 held, 5,021 in the file); the nightly checks
  **0.61 s** (75,849 `bank_transfer` rows read; 7a: 0.66 s); the late predecessor's options 0.03 s, its booking
  **1.73 s** (7a: 1.69 s).
- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (258.3 s) — reserved 1.11 s, prepared 10.2 s;
  nightly checks 4.2 s (the draft waiting 3.7 s); cancellation 3.02 s; the re-run prepared and approved 25.6 s, its
  payout booked **0.8 s** (the funds pass 0.2 s); the nightly checks with the run booked **4.46 s** (4.82 s warm; 7a:
  4.49 s) — `run_payment_checks` 2.47 s, `commission_key_open` (50,000 calls) 1.21 s, `run_remittance_runs_checks`
  0.36 s, `run_advance_checks` **51 ms** own (the run booked today read once through both branches of the window, its
  50,000 lines and each line's reversal by key; the whole night's reads: `bank_line_booking` 7 rows by index,
  `ledger_entry` 211,664 by index, none of either by a sequential scan).
- CI's `scale-payouts` command as the workflow runs it (`test_debit_bookings_scale_integration.py` then
  `test_breach_held_scale_integration.py`), after `supabase db reset`: **6 passed** in 1,209.3 s (20.2 min) — 200
  members' batch line 0.40 s, 200 RMT debits' job 0.66 s; « Générer le fichier » for 5,000 payouts (+50 cancelled)
  3.00 s; the 5,000-member batch line's funds pass **22.2 s** (22.3 s under auto_explain; 7a: 22.6 s); the nightly
  checks **1.03 s** (1.12 s warm; 7a: 0.98 s); 5,000 RMT debits imported in 1.2 s, the debit job **20.4 s** in chunks
  of 8.2, 8.0 and 4.0 s (7a: 20.2 s); then the 2,000 held chained runs: the funds pass 18.8 s, the nightly checks
  **13.48 s** (the standalone reading 12.06 s; 7a: 13.98 s), once the days are imported **12.76 s** (7a: 15.87 s).
  Within this VM's spread: the round adds one keyed read of the day's payout bookings to the nightly (5,000 here, each
  transfer's run by key, the runs then read once with those booked today).

### M2c-7a review fixes, round 2 (2026-11-23, same VM, the main stack alone, each run right after `supabase db reset`)

On a timed path, the round changes only the nightly's `advance_open`. Its `settled_on_depth` detail now reads the
reversed item through `private.item_settled_at` (the run's own settlement, then each unplanned payout that paid the item
and came back, by `unplanned_paid_item_entry_idx` and `ledger_entry_reversed_once_uq`) instead of `run_settled_at`. It
is read for remitted-reversal advances over 30 days old, and these files have none. The other changed reads
(`private.entry_remitted`, `public.allocation_remitted`: « Désimputer » and « Débits et retours ») are not on a timed
path. The files are run once each as the round's check.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (64.1 s). Set-up took 47.6 s, the evidence of the
  5,000-transfer file 0.50 s, and generation with the holds 3.56 s (20 held, 5,021 in the file). The nightly checks took
  **0.95 s** (75,849 `bank_transfer` rows read; round 1: 0.61 s). The late predecessor's options took 0.03 s and its
  booking **2.63 s** (round 1: 1.73 s). The VM ran slower this session on paths the round does not touch: set-up
  38.6 → 47.6 s, generation 2.99 → 3.56 s.
- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (364.6 s). Reserved in 1.54 s, prepared in
  12.9 s. Nightly checks 5.4 s (the draft waiting 4.9 s). Cancellation 4.82 s. The re-run prepared and approved in
  37.1 s, its payout booked in **1.1 s** (the funds pass 0.4 s). The nightly checks with the run booked took **6.3 s**
  (6.12 s warm; round 1: 4.46 s): `run_payment_checks` 3.42 s, `commission_key_open` (50,000 calls) 1.59 s,
  `run_remittance_runs_checks` 0.62 s, `run_advance_checks` **126 ms** own. The night's reads were the same rows as round
  1: `ledger_entry` 211,626 by index, `bank_line_booking` 7 by index, and none of either by a sequential scan. Every step
  ran about 25–45 % slower than round 1 on paths the round does not touch: prepare 10.2 → 12.9 s, the re-run
  25.6 → 37.1 s, `run_payment_checks` 2.47 → 3.42 s. The servicer has no `client_advance` row, so `advance_open`'s
  changed detail reads nothing. To separate the change from the VM, `run_advance_checks` was timed on the same data
  right after the run, five calls each inside one rolled-back transaction: this round's body gave full 103.8 / 62.9 /
  62.5 / 59.4 / 59.8 ms and delta 64.6 / 62.0 / 62.0 / 62.4 / 87.5 ms; `756dc1b`'s body, swapped in by `create or
  replace`, gave full 71.3 / 64.9 / 62.8 / 61.5 / 61.4 ms and delta 62.8 / 63.1 / 63.1 / 62.5 / 63.0 ms. The two are the
  same within noise (the 126 ms above is the night's first, cold call).
- CI's `scale-payouts` command as the workflow runs it (`test_debit_bookings_scale_integration.py` then
  `test_breach_held_scale_integration.py`), after `supabase db reset`: **6 passed** in 1,382.1 s (23.0 min).
  - The 200 members' batch line took 0.62 s and the 200 RMT debits' job 0.91 s. « Générer le fichier » for 5,000
    payouts (+50 cancelled) took 4.26 s.
  - The 5,000-member batch line's funds pass took **27.7 s** (29.8 s under auto_explain; round 1: 22.2 s). The nightly
    checks took **1.42 s** (1.30 s warm; round 1: 1.03 s).
  - 5,000 RMT debits were imported in 1.6 s, and the debit job took **26.1 s** in chunks of 10.9, 10.2 and 4.7 s (round
    1: 20.4 s).
  - Then the 2,000 held chained runs: the funds pass took 22.5 s and the nightly checks **14.93 s** (the standalone
    reading 13.06 s; round 1: 13.48 s). Once the days were imported, they took **15.13 s** (round 1: 12.76 s).
  - None of these paths changed in the round: the funds pass and the debit job read 0 `client_advance` rows, as in round
    1, and every table they read was read by index (no sequential scan). They are 20–35 % slower than round 1, as
    everything else ran this session (the fixture alone: 5,050 runs' approval jobs 557.7 s).

`test_allocation_scale_integration.py` (50,000 allocations) is not run: the allocation path is unchanged, as in round 1.

### M2c-7a review fixes, round 3 (2026-11-23, same VM, the main stack alone, each run right after `supabase db reset`)

No timed path changes in the round. `private.item_settled_at` reads, for an item whose run's own payout came back,
what the unplanned payouts that stayed paid paid of it (its attributions by `unplanned_paid_item_entry_idx`, each
booking by its key and its reversal by `ledger_entry_reversed_once_uq`, the item's line by `remittance_line_live_uq`).
On a timed path it is read only by the nightly's `advance_open` detail, for remitted-reversal advances over 30 days old;
these files have none. `043` #50 proves the new read scans no table sequentially under statistics that price a scan
lowest. The files are run once each as the round's check.

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (65.8 s). Set-up took 48.7 s, the evidence of the
  5,000-transfer file 0.49 s, and generation with the holds 3.90 s (20 held, 5,021 in the file). The nightly checks
  took **0.84 s** (75,849 `bank_transfer` rows read; round 2: 0.95 s). The late predecessor's options took 0.03 s and
  its booking **2.95 s** (round 2: 2.63 s).
- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (370.4 s). Reserved in 1.35 s, prepared in
  11.4 s. Nightly checks 4.9 s (the draft waiting 4.6 s). Cancellation 4.57 s. The re-run prepared and approved in
  35.1 s, its payout booked in **1.0 s** (the funds pass 0.4 s). The nightly checks with the run booked took **6.8 s**
  (5.95 s warm; round 2: 6.3 s): `run_payment_checks` 3.59 s, `commission_key_open` (50,000 calls) 1.73 s,
  `run_remittance_runs_checks` 0.61 s, `run_advance_checks` **108 ms** own (round 2: 126 ms). The night read
  `ledger_entry` 211,528 rows by index (round 2: 211,626) and `bank_line_booking` 7 by index, and neither by a
  sequential scan.
- CI's `scale-payouts` command as the workflow runs it (`test_debit_bookings_scale_integration.py` then
  `test_breach_held_scale_integration.py`), after `supabase db reset`: **6 passed** in 1,432.5 s (23.9 min).
  - The 200 members' batch line took 0.76 s and the 200 RMT debits' job 0.81 s. « Générer le fichier » for 5,000
    payouts (+50 cancelled) took 3.86 s.
  - The 5,000-member batch line's funds pass took **30.2 s** (29.8 s under auto_explain; round 2: 27.7 s). The nightly
    checks took **1.20 s** (1.36 s warm; round 2: 1.42 s).
  - 5,000 RMT debits were imported in 1.9 s, and the debit job took **26.1 s** in chunks of 10.7, 10.3 and 4.8 s (round
    2: 26.1 s).
  - Then the 2,000 held chained runs: the funds pass took 22.5 s and the nightly checks **15.80 s** (the standalone
    reading 13.28 s; round 2: 14.93 s). Once the days were imported, they took **15.66 s** (round 2: 15.13 s).
  - None of these paths changed in the round: the funds pass and the debit job read 0 `client_advance` rows, as in
    rounds 1 and 2, and every table they read was read by index (no sequential scan). The differences from round 2 are
    within this VM's run-to-run spread (the fixture alone: 5,050 runs' approval jobs 593.9 s; round 2: 557.7 s).

`test_allocation_scale_integration.py` (50,000 allocations) is not run: the allocation path is unchanged, as in rounds 1
and 2.

### M2c-7a — CI round (main) (2026-11-23, same VM, a second local stack beside the main one — 7b's build ran its suites on the main stack meanwhile —, each run right after `supabase db reset` with CI's logging settings)

What the round changes on a timed path: `private.cover_booked_run_reversals` (each payout booking: the booked runs'
reversed lines), `private.run_booked_cover_check` (each run set booked, fired by `ledger_check_now`) and the nightly's
runs booked since in `private.run_advance_checks` read each run's lines by the run's key alone, their conditions outside
the fence (ADR-0014 « M2c-7a — CI round (main) »).

The failure first, on 245296d in the scale job's order (CI run 45206756541: 25,202,495 `remittance_line` rows, the
booking 6.18 s): **2 failed, 13 passed** (1,694.1 s) — both lot tests past the API's 8 s, cancelled in the cover's
statement. `remittance_line` analysed at the two 50,000-line runs (`n_distinct(run_id)` 2): that statement alone for
the lot's 499 runs **8.7 s** (a bitmap of `remittance_line_live_uq` whole per run, 51,004 rows each), **5.8 ms** with
the fixed body; the nightly's booked-runs read for the lot's 500 runs 8.9 s on 245296d.

The scale job's command as `ci.yml` runs it (its nine files), on the fix: **15 passed** (1,603.1 s):

- `test_transfer_line_scale_integration.py`, `remittance_line` analysed exactly as in the failing run (`n_distinct(run_id)`
  2, MCV 0.501 / 0.499): the 500-member lot short of one, rolled back — options 0.60 s, booking **2.10 s**, **2,995**
  `remittance_line` rows read (about 6 per member; bound 5,000; CI on 245296d: 25.2 million), no sequential scan of a
  per-member table; through the API — options 0.58 s, booking **2.39 s**, the allocation lock held 2.11 s (budget 4 s;
  PR #40's round: 0.41 s / 1.78 s, before 7a's per-run checks); the saturating lots: options 2.40 / 2.63 s, the command
  2.47 / 2.78 s (`parts_do_not_add_up`); 501 and 5,000 members 0.04 / 0.014 s (`lot_too_large`); the 50,000-item draft:
  options 0.09 s, command 0.23 s, lock 0.18 s.
- `test_remittance_scale_integration.py` (50,000 lines): reserved 1.43 s, prepared 12.4 s; nightly checks 4.9 s (the
  draft waiting 4.3 s); cancellation 4.13 s; the re-run prepared and approved 35.6 s, its payout booked 1.1 s; the
  nightly checks with the run booked **6.3 s** (`run_payment_checks` 3.04 s own, `commission_key_open` 1.90 s,
  `run_remittance_runs_checks` 0.62 s, `run_advance_checks` **101 ms** own; 7a round 3: 108 ms).
- The others: 50,000 credits imported and matched 36.3 s, allocated 86.5 s; the statement 50,000 credits 47.3 s; 25
  receipt jobs 79.9 s (16.0 ms per receipt); the 50k boarding 133 s; the camt.053 import job 31.9 s; the transfer
  cancellation file's nightly checks 0.91 s (75,850 `bank_transfer` rows), the late predecessor's booking 2.74 s; the
  5,000-transfer file's debit job 12.8 s, its nightly checks 0.37 s; 500 runs' approval jobs 154.2 s.

This VM ran about 15–20 % slower than in PR #40's round on paths no change since touches (the 500 runs' approval jobs
136.7 → 154.2 s, the 50k boarding 111 → 133 s, a receipt 14.3 → 16.0 ms), the other stack's suites running meanwhile.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), on another fresh reset: **6 passed** (1,418.6 s, 23.6 min) — 200 members'
batch line 0.59 s, 200 RMT debits' job 0.76 s; « Générer le fichier » for 5,000 payouts (+50 cancelled) 4.19 s; the
5,000-member batch line's funds pass **29.2 s** (29.1 s under auto_explain; 20,000 `remittance_line` rows, 4 per
member, none by a sequential scan; 7a round 3: 30.2 s); the nightly checks **1.28 s** (1.40 s warm; round 3: 1.20 s);
5,000 RMT debits imported in 1.6 s, the debit job **26.3 s** in chunks of 11.0, 10.2 and 4.8 s (round 3: 26.1 s);
then the 2,000 held chained runs: the funds pass 21.8 s, the nightly checks **14.97 s** (the standalone reading
12.91 s; round 3: 15.80 s), once the days are imported **15.24 s** (round 3: 15.66 s). Within the spread of the
earlier rounds: there `remittance_line` holds about one line per run, so its statistics priced the run's key below the
live index before the round too.

### M2c-7a — CI round (main), the second read (2026-11-23, same VM, the second local stack — the main stack in use by another build meanwhile)

What changes on a timed path: `private.transfer_line_post` (every `book_transfer_line`) runs under
`enable_seqscan = off`, so the double payout's advance reads its run's lines by `remittance_line_pkey`'s prefix
(ADR-0014 « M2c-7a — CI round (main) », « A second read »). Reached when the bank debits a PmtInf twice.

The verifier's figure, before: a 500-member lot debited twice, on the state the scale files leave — **51,502,500**
`remittance_line` rows in 500 sequential scans, **14.28 s** (past the API's 8 s); the setting alone 2.94 s, 1,000 rows.

A probe at 500 members (the scale file's fixture; each command rolled back; 2 × 50,000 lines planted with
`n_distinct(run_id)` 2, or the statistics as left; 7a's body and the fix, two repeats in alternating order,
`pg_stat_statements` with `track = all`):

| Command | 7a's body | fixed |
|---|---|---|
| second debit (500 unplanned payouts with advances), planted | 5.58 s, 18.54 s; 50,286,500 rows, 500 seq scans | 2.69 s, 2.79 s; 1,000 rows, none |
| second debit, as left | 2.81 s, 2.74 s | 2.81 s, 2.67 s |
| first debit (500 payouts), planted / as left | 1.69, 1.84 s / 1.73, 1.98 s | 1.81, 1.83 s / 1.73, 1.79 s |
| the lot short of one (499 payouts), planted / as left | 1.90, 2.00 s / 1.83, 1.83 s | 1.85, 1.83 s / 1.87, 1.85 s |

No nested statement slower under the fix in both repeats by more than 10 % and 2 ms; the only consistent plan change
outside the mandate read, `ledger_post_set`'s client check by key, 0.5 → 0.9 ms for 1,000 entries.

On the fix, `test_transfer_line_scale_integration.py` alone on a fresh `supabase db reset`: **7 passed** (187.6 s) —
the 500-member lot short of one, rolled back: options 0.58 s, booking **1.72 s**, 2,995 `remittance_line` rows, no
sequential scan of a per-member table; through the API 0.54 s / **1.76 s**, the allocation lock held 1.53 s; the
saturating lots: options 2.33 / 2.60 s, the command 2.49 / 2.92 s; 501 and 5,000 members 0.03 / 0.014 s; the
50,000-item draft: options 0.10 s, command 0.19 s, lock 0.14 s. Then the verifier's probe on that state, a new
500-member lot debited twice: the second debit **3.67 s** planted (2 × 10,000 lines), **3.23 s** as left, 1,000 rows,
no sequential scan (the same body recreated in the transaction: 2.69 / 2.91 s, this VM's spread); the first debit 1.80
to 2.70 s.

### M2c-7b (2026-11-23, same VM, the main stack, each run right after `supabase db reset`)

What 7b puts on the timed paths: the prepare reads, per item, its advance's mandate (`client_advance` by its unique
entry, a hash join over a table of a few rows) and the client's open advances (`client_advance_client_idx`, each open by
`private.advance_open`: its reversal by `ledger_entry_reversed_once_uq`, its settlements by
`commission_settlement_document_idx`); the approval's line insert guard filters the statement's lines by kind (an
advance's: one keyed lookup each); the settlement guard reads the statement's rows of document_kind advance (the
debit's `post_run_settlements` inserts thousands of invoice settlements in one statement: two scans of its transition
table, no table read for them); `private.transfer_line_check`'s `double_payout` rule one keyed lookup more
(`client_advance_cause_idx`, then `private.advance_in_flight_run`) on an unplanned return; the nightly's `advance_open`
one `mandate_terms` read per open advance over 30 days old. These files hold no advance (the 50,000-line run's client
none), so they time the added reads' cost on the ordinary path. Another session's scale files ran on the same VM, on a
stack of their own, during these runs (CPU shared).

- `test_transfer_cancellation_scale_integration.py`: **1 passed** (59.4 s). Set-up 44.2 s, the evidence of the
  5,000-transfer file 0.45 s, generation with the holds 3.47 s (20 held, 5,021 in the file). The nightly checks took
  **0.89 s** (75,849 `bank_transfer` rows read; 7a round 3: 0.84 s). The late predecessor's options took 0.04 s and its
  booking — `private.transfer_line_check` and the post — **2.39 s** (7a round 3: 2.95 s).
- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (355.8 s; 7a round 3: 370.4 s). Reserved in
  1.43 s, prepared in **11.3 s** (the facts loaded in 3.50 s, priced in 5.19 s, written in 2.44 s; 7a round 3: 11.4 s
  prepared). The approval job and documents 18.1 s. Nightly checks 4.9 s (the draft waiting 4.3 s). Cancellation
  4.04 s. The re-run prepared and approved in **32.1 s** (7a round 3: 35.1 s), its payout booked in **1.0 s** (the funds
  pass 0.3 s). The nightly checks with the run booked took **5.9 s** (7a round 3: 6.8 s). The night read `ledger_entry`
  211,525 rows by index and `commission_settlement` 5 by index, neither by a sequential scan.
- CI's `scale-payouts` command as the workflow runs it (`test_debit_bookings_scale_integration.py` then
  `test_breach_held_scale_integration.py`), after `supabase db reset`: **6 passed** in 1,560.5 s (26.0 min; 7a round 3:
  23.9 min).
  - The 200 members' batch line took 0.64 s and the 200 RMT debits' job 0.80 s. « Générer le fichier » for 5,000
    payouts (+50 cancelled) took 4.07 s.
  - The 5,000-member batch line's funds pass took **30.2 s** (35.3 s under auto_explain; 7a round 3: 30.2 s). The
    nightly checks took **1.70 s** (1.86 s warm; 7a round 3: 1.20 s): `document_open`'s 5,100 calls 135 ms own. Timed
    against 7a's body on the same 7,300 invoices in one transaction, three calls each, its sum took 169–221 ms with 7b's
    body and 180–217 ms with 7a's: the redefinition costs nothing measurable; the difference from round 3 is the VM
    (another session's scale files ran beside these, and the fixture's 5,050 approval jobs took 606.0 s against
    593.9 s).
  - 5,000 RMT debits were imported in 1.6 s, and the debit job took **29.3 s** in chunks of 12.4, 11.5 and 5.1 s (7a
    round 3: 26.1 s). The funds pass and the debit job read 0 `client_advance` rows, as before, and every table they
    read was read by index.
  - Then the 2,000 held chained runs: the funds pass took 21.5 s and the nightly checks **14.53 s** (the standalone
    reading 13.52 s; 7a round 3: 15.80 s). Once the days were imported, they took **15.66 s** (7a round 3: 15.66 s).

`test_allocation_scale_integration.py` (50,000 allocations) is not run: the allocation path is unchanged.

### M2c-7b review fixes, round 1 (2026-11-23, same VM, the main stack, each run right after `supabase db reset`)

What round 1 puts on the timed paths: the prepare's item read takes one column more of the same keyed join
(`client_advance.cause`); its new read of the run's unplanned payouts' attributions (`private.unplanned_paid_item` by
its primary key, the booking's reversal by `ledger_entry_reversed_once_uq`) runs only when the run holds an
`unplanned_payout` row — none in these files; the approval's line insert guard reads the advance's cause with its
mandate (the same keyed lookup, advance lines only); the nightly's `advance_open` reads, per open advance over 30 days
old, the client's opening (`client_status_event_client_idx`) and the advance's birth (two keyed lookups) — these files
hold no advance. No plan shape changes on a scale path, so no forced-statistics test is added. Another session's stack
(its own scale files) ran on the same VM during these runs.

- `test_remittance_scale_integration.py` (50,000 lines): **1 passed** (344.8 s; 7b: 355.8 s). Reserved in 1.37 s,
  prepared in **11.9 s** (the facts loaded in 3.59 s, priced in 5.61 s, written in 2.51 s; 7b: 11.3 s). The approval job
  and documents 18.9 s. Nightly checks 4.9 s (the draft waiting 4.2 s). Cancellation 3.94 s. The re-run prepared and
  approved in **33.0 s** (7b: 32.1 s), its payout booked in **0.9 s** (the funds pass 0.3 s). The nightly checks with the
  run booked took **5.6 s** (7b: 5.9 s); they read `ledger_entry` 211,652 rows by index and `commission_settlement` 5 by
  index, neither by a sequential scan.
- `test_transfer_cancellation_scale_integration.py`: **1 passed** (60.4 s; 7b: 59.4 s). Set-up 44.5 s, the evidence of
  the 5,000-transfer file 0.45 s, generation with the holds 3.64 s (20 held, 5,021 in the file). The nightly checks took
  **0.76 s** (75,849 `bank_transfer` rows read; 7b: 0.89 s). The late predecessor's options took 0.03 s and its booking
  — `private.transfer_line_check` and the post — **2.69 s** (7b: 2.39 s).
- CI's `scale-payouts` command as the workflow runs it (`test_debit_bookings_scale_integration.py` then
  `test_breach_held_scale_integration.py`), after `supabase db reset`: **6 passed** in 1,427.9 s (23.8 min; 7b: 26.0
  min).
  - The 200 members' batch line took 0.68 s and the 200 RMT debits' job 0.74 s. « Générer le fichier » for 5,000
    payouts (+50 cancelled) took 4.01 s (the fixture's 5,050 approval jobs 568.1 s; 7b: 606.0 s).
  - The 5,000-member batch line's funds pass took **28.0 s** (28.6 s under auto_explain; 7b: 30.2 s). The nightly
    checks took **1.25 s** (1.40 s warm; 7b: 1.70 s): `document_open`'s 5,100 calls 135 ms own, as in 7b.
  - 5,000 RMT debits were imported in 1.6 s, and the debit job took **24.9 s** in chunks of 10.3, 10.0 and 4.4 s (7b:
    29.3 s). The funds pass and the debit job read 0 `client_advance` rows, as before, and every table they read was
    read by index.
  - Then the 2,000 held chained runs: the funds pass took 21.8 s and the nightly checks **15.81 s** (the standalone
    reading 13.13 s; 7b: 14.53 s). Once the days were imported, they took **14.99 s** (7b: 15.66 s).

`test_allocation_scale_integration.py` (50,000 allocations) is not run: the allocation path is unchanged.

### M2c-7b review fixes, round 2 (2026-11-23, same VM, the main stack, each run right after `supabase db reset`; another session's verifier ran its own scale files on a second stack meanwhile)

What round 2 puts on the timed paths (ADR-0014 « M2c-7b review fixes » round 2):

- The nightly's runs booked since are read by each run's key again. 7b's copy of `private.run_advance_checks` from
  `20261122090000` had undone the CI round; it is rebuilt on `20261123080000`'s body.
- The prepare reads the client's open advances through `private.client_open_advances` and its unplanned payouts'
  attributions through `private.unplanned_paid_live`, both keyed with seq scans off. Each item's advance is a fenced
  lateral probe by its entry.
- « Avances » and the client space read each advance's birth once.

Under the planted statistics (`worker/tests/test_advance_reads_integration.py`, db job, about 8 s; the table is in the
ADR), every 7b SQL read takes a few rows per advance. The worker's three 7b statements fell from 20,008 / 10,005 /
10,000 rows to 6 / 5 / 0. After the scale job, the tables those statements read hold 1 `client_advance` row and 0
`unplanned_paid_item` rows. No scale path read a planted-size table before the fix or after it.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`): **15 passed** (1,543.0 s).

- `test_transfer_line_scale_integration.py`:
  - The 500-member lot short of one, rolled back: options 0.45 s, booking **1.93 s**, **2,995** `remittance_line`
    rows read and no sequential scan of a per-member table (CI round: 2.10 s, 2,995).
  - The same through the API: options 0.52 s, booking **2.08 s**, the allocation lock held 1.93 s (CI round: 0.58 /
    2.39 / 2.11 s).
  - The saturating lots: options 2.34 / 2.54 s, the command 2.44 / 2.63 s (`parts_do_not_add_up`).
  - 501 members 0.02 s and 5,000 members 0.014 / 0.014 s (`lot_too_large`).
  - The 50,000-item draft: options 0.08 s, command 0.26 s, lock 0.21 s.
  - The approval jobs took 149.0 s for 500 runs and 151.4 s for 501 (CI round: 154.2 s).
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 1.52 s, prepared in **12.7 s** (load 4.38 s, price 5.72 s, write 2.41 s; round 1: 11.9 s). The
    approval job and documents took 18.5 s.
  - The nightly checks took 5.0 s (the draft waiting 4.8 s), and the cancellation 4.28 s.
  - The re-run was prepared and approved in **33.5 s** (round 1: 33.0 s), and its payout booked in 0.9 s (the funds
    pass 0.3 s).
  - The nightly checks with the run booked took **5.5 s** (round 1: 5.6 s). `run_advance_checks` took **90 ms** own
    (CI round: 101 ms). They read `ledger_entry` 211,635 rows and `commission_settlement` 5, by index.
- The others:
  - 50,000 credits imported and matched in 33.9 s, allocated in 79.8 s.
  - The statement: 50,000 credits in 44.4 s (the 13,500-credit history in 11.7 s).
  - 25 receipt jobs in 76.2 s (15.2 ms per receipt).
  - The 50k boarding in 121 s (commit 32.3 s, confirm job 36.3 s).
  - The camt.053 import job in 31.8 s (the same lines again in 8.1 s).
  - The transfer cancellation file: set-up 45.0 s, generation with the holds 3.78 s, nightly checks **0.88 s**
    (75,850 `bank_transfer` rows), the late predecessor's booking **2.31 s** (round 1: 2.69 s).
  - The 5,000-transfer file: the debit job 12.1 s, its nightly checks 0.35 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,390.5 s, 23.2 min; round 1:
23.8 min).

- The 200 members' batch line's funds pass took 0.65 s, and the 200 RMT debits' job 0.78 s.
- « Générer le fichier » for 5,000 payouts (+50 cancelled) took 4.01 s (the fixture's 5,050 approval jobs 554.8 s).
- The 5,000-member batch line's funds pass took **28.0 s** (28.4 s under auto_explain; round 1: 28.0 s). It read
  20,000 `remittance_line` rows and 0 `client_advance` rows, none by a sequential scan.
- The nightly checks took **1.27 s** (1.32 s warm; round 1: 1.25 s); `document_open`'s 5,100 calls took 118 ms own.
- 5,000 RMT debits were imported in 1.4 s, and the debit job took **24.4 s** in chunks of 9.8, 9.9 and 4.5 s (round
  1: 24.9 s).
- Then the 2,000 held chained runs: the funds pass took 21.6 s and the nightly checks **14.60 s** (the standalone
  reading 12.77 s; round 1: 15.81 s). Once the days were imported, they took **15.18 s** (round 1: 14.99 s).

### M2c-7c-1: client payments and refunds (2026-11-24, same VM, the main stack alone, each run right after `supabase db reset`)

What 7c-1 puts on the timed paths (ADR-0014 « M2c-7c-1 »): every posting goes through `private.ledger_post_set`, whose
book lists gain 419 and 7714 (no new read), and `private.ledger_entry_verify`, whose per-entry aggregate counts two more
books (no new read); every insert into `commission_settlement` fires the new statement guard of a credit's refunds (two
scans of its transition table for rows of document_kind `client_credit`: the debit's `post_run_settlements` inserts
thousands of invoice settlements in one statement, none of that kind); the nightly's `run_advance_checks` adds three
statements (the servicer's credits by `client_credit_org_idx`, its 419 and 7714 accounts by `(organization_id, book)`
and their postings by account), which find nothing in these files. The new commands and reads are on no scale path:
they are bounded under planted statistics instead (below).

**Stale statistics** (`worker/tests/test_client_payment_reads_integration.py`, the db job; plan class of 7a's main
break). In one rolled-back transaction, 10,000 rows planted in each table the slice reads by a parameter or a
correlated key (`commission_settlement`, `commission_invoice`, `client_advance`, `client_credit`,
`advance_write_off_recovery`, `client_payout_account`, `client_status_event`), over two values of each key and, where a
statement also filters on the servicer, the tenant's own servicer for other clients; each analysed with n_distinct 2
(the servicer's −1); every plan generic. Then each read and command as its caller runs it, on a client owing one
invoice; the rows each read from the planted tables (index entries returned and sequential reads), bounded at 12 per
document + 60 — `client_open_documents` 7, `client_payment_preview` 6, `record_client_payment` 7, `client_space_credits` 2, `record_client_refund` 4, `client_payment_line` 7, `book_client_payment_line` 5 (bound 72 each). The night's `run_advance_checks` full pass reads the servicer's own planted credits twice (`client_credit_owed` and `client_credit_ledger`: 20,004 rows) and its recoveries once (`written_off_recovery_ledger`: 10,000), once per statement and never per row, its per-credit probes by key (7b's two advance checks read the 20,000 planted advances the same way); `run_payment_checks` as a whole is printed, not bounded — its earlier slices' checks read the servicer's planted invoices 18 times (180,012 rows), not 7c-1's (7f's hardening). Carried low 3: `public.client_space_advances` read 10,005 `client_advance` rows on 7b's
body under 10,000 planted advances of the servicer's other clients, 3 on 7c-1's
(`test_advance_reads_integration.py`).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`): **15 passed** (1,526.1 s; 7b round
2: 1,543.0 s).

- `test_transfer_line_scale_integration.py`:
  - The 500-member lot short of one, rolled back: options 0.54 s, booking **1.89 s**, **2,995** `remittance_line`
    rows read and no sequential scan of a per-member table (7b round 2: 1.93 s, 2,995).
  - The same through the API: options 0.51 s, booking **1.96 s**, the allocation lock held 1.74 s (round 2: 0.52 /
    2.08 / 1.93 s).
  - The saturating lots: options 2.29 / 2.51 s, the command 2.51 / 2.75 s (`parts_do_not_add_up`).
  - 501 members 0.03 s and 5,000 members 0.019 / 0.017 s (`lot_too_large`).
  - The 50,000-item draft: options 0.10 s, command 0.21 s, lock 0.16 s.
  - The approval jobs took 146.5 s for 500 runs and 151.6 s for 501 (round 2: 149.0 / 151.4 s). No Paris date
    change fell in these runs, so none was refused for one and carried low 4's helper validated none again.
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 1.54 s, prepared in **12.9 s** (load 4.33 s, price 6.09 s, write 2.30 s; round 2: 12.7 s). The
    approval job and documents took 17.7 s.
  - The nightly checks took 5.0 s (the draft waiting 4.5 s), and the cancellation 4.02 s.
  - The re-run was prepared and approved in **33.1 s** (round 2: 33.5 s), and its payout booked in 1.0 s (the funds
    pass 0.4 s).
  - The nightly checks with the run booked took **5.9 s** (round 2: 5.5 s; 6.18 s warm with row counts on).
    `run_advance_checks` took **91 ms** own (round 2: 90 ms), its three new statements included. They read
    `ledger_entry` 211,616 rows and `commission_settlement` 5, by index.
- The others:
  - 50,000 credits imported and matched in 35.7 s, allocated in 77.7 s; 1,000 returns in 30.1 s, their nightly
    checks 4.3 s.
  - The statement: 50,000 credits in 44.6 s (the 13,500-credit history in 11.9 s).
  - 25 receipt jobs in 73.1 s (14.6 ms per receipt).
  - The 50k boarding in 121 s (commit 32.6 s, confirm job 37.6 s).
  - The camt.053 import job in 30.5 s.
  - The transfer cancellation file: set-up 44.3 s, generation with the holds 3.27 s, nightly checks **0.98 s**
    (75,850 `bank_transfer` rows), the late predecessor's booking **2.44 s** (round 2: 2.31 s).
  - The 5,000-transfer file: the debit job 11.9 s, its nightly checks 0.48 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,298.6 s, 21.6 min; 7b round 2:
23.2 min).

- The 200 members' batch line's funds pass took 0.54 s, and the 200 RMT debits' job 0.83 s.
- « Générer le fichier » for 5,000 payouts (+50 cancelled) took 4.06 s (the fixture's 5,050 approval jobs 524.9 s; no
  Paris date change fell in them, so carried low 4's helper validated none again).
- The 5,000-member batch line's funds pass took **27.7 s** (28.6 s under auto_explain; round 2: 28.0 s). It read
  20,000 `remittance_line` rows and 0 `client_advance` rows, none by a sequential scan.
- The nightly checks took **1.21 s** (1.27 s warm; round 2: 1.27 s); `document_open`'s 5,100 calls took 132 ms own.
- 5,000 RMT debits were imported in 1.4 s, and the debit job took **24.9 s** in chunks of 9.7, 10.3 and 4.6 s (round
  2: 24.4 s): its settlements' statements fire the new credit guard, which finds no credit row.
- Then the 2,000 held chained runs: the funds pass took 21.5 s and the nightly checks **14.52 s** (the standalone
  reading 12.64 s; round 2: 14.60 s). Once the days were imported, they took **14.51 s** (round 2: 15.18 s).

### M2c-7c-1 review fixes, round 1 (2026-11-24, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What the round puts on the timed paths (ADR-0014 « M2c-7c-1 review fixes », round 1): nothing. The payability of a
named loss (`private.client_payment_recoveries`, one keyed call per loss named) and of the page's written-off rows, and
the commands' `credits` (built from the plan's rows in memory), are on the client payment commands and the page only;
no scale file runs them. Their reads are bounded under planted statistics instead: `test_advance_reads_integration.py`
(10,000 rows per planted table, n_distinct 2, generic plans) — `client_open_documents` with a loss to recover 23 rows
(bound 84), `client_payment_recoveries` 7 (bound 72), a recovery's `client_payment_preview` 16 (bound 84).
`test_client_payment_reads_integration.py` passes as before (its client has no loss: the new branch is not on its path).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`): **15 passed** (1,488.1 s; 7c-1:
1,526.1 s).

- `test_transfer_line_scale_integration.py`:
  - The 500-member lot short of one, rolled back: options 0.53 s, booking **1.61 s**, **2,995** `remittance_line`
    rows read and no sequential scan of a per-member table (7c-1: 1.89 s, 2,995).
  - The same through the API: options 0.50 s, booking **2.43 s**, the allocation lock held 2.13 s (7c-1: 0.51 / 1.96 /
    1.74 s).
  - The saturating lots: options 2.31 / 2.40 s, the command 2.20 / 2.82 s (`parts_do_not_add_up`).
  - 501 members 0.03 s and 5,000 members 0.016 / 0.015 s (`lot_too_large`).
  - The 50,000-item draft: options 0.08 s, command 0.21 s, lock 0.15 s.
  - The approval jobs took 139.7 s for 500 runs and 135.0 s for 501 (7c-1: 146.5 / 151.6 s). No Paris date change fell
    in these runs (05:29–05:54 UTC), so carried low 4's helper validated none again.
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 1.41 s, prepared in **15.7 s** (load 4.47 s, price 7.07 s, write 3.92 s; 7c-1: 12.9 s — the round
    changes nothing the prepare reads or writes: the VM's variance, its budget kept). The approval job and documents
    took 18.2 s.
  - The nightly checks took 4.9 s (the draft waiting 4.8 s), and the cancellation 3.83 s.
  - The re-run was prepared and approved in **34.5 s** (7c-1: 33.1 s), and its payout booked in 1.3 s.
  - The nightly checks with the run booked took **6.0 s** (7c-1: 5.9 s; 6.26 s warm with row counts on).
    `run_advance_checks` took **119 ms** own (7c-1: 91 ms; its statements unchanged but a comment). They read
    `ledger_entry` 211,643 rows by index.
- The others:
  - 50,000 credits imported and matched in 33.9 s, allocated in 81.0 s; 1,000 returns in 33.0 s, their nightly
    checks 4.1 s.
  - The statement: 50,000 credits in 45.3 s (the 13,500-credit history in 11.8 s).
  - 25 receipt jobs in 75.5 s (15.1 ms per receipt).
  - The 50k boarding in 114 s (commit 31.1 s, confirm job 34.9 s).
  - The camt.053 import job in 28.6 s.
  - The transfer cancellation file: set-up 45.1 s, generation with the holds 2.89 s, nightly checks **0.67 s**
    (75,850 `bank_transfer` rows), the late predecessor's booking **2.23 s** (7c-1: 2.44 s).
  - The 5,000-transfer file: the debit job 12.2 s, its nightly checks 0.45 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,430.0 s, 23.8 min; 7c-1:
21.6 min — the fixtures' approval jobs took the difference, 617.4 s for 5,050 runs against 524.9 s; no timed step grew).

- The 200 members' batch line's funds pass took 0.46 s, and the 200 RMT debits' job 0.55 s.
- « Générer le fichier » for 5,000 payouts (+50 cancelled) took 3.64 s (the fixture's 5,050 approval jobs 617.4 s; no
  Paris date change fell in them, about 06:00 UTC, so carried low 4's helper validated none again).
- The 5,000-member batch line's funds pass took **21.2 s** (24.3 s under auto_explain; 7c-1: 27.7 s). It read 20,000
  `remittance_line` rows and 0 `client_advance` rows, none by a sequential scan.
- The nightly checks took **1.05 s** (1.25 s warm; 7c-1: 1.21 s); `document_open`'s 5,100 calls took 85 ms own.
- 5,000 RMT debits were imported in 1.4 s, and the debit job took **23.3 s** in chunks of 9.4, 9.7 and 3.8 s (7c-1:
  24.9 s).
- Then the 2,000 held chained runs: the funds pass took 20.3 s and the nightly checks **13.67 s** (the standalone
  reading 11.85 s; 7c-1: 14.52 s). Once the days were imported, they took **13.85 s** (7c-1: 14.51 s).

### M2c-7c-1 review fixes, round 2 (2026-11-24, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What the round puts on the timed paths (ADR-0014 « M2c-7c-1 review fixes », round 2): nothing. The client's opening
(`private.client_opening_date`, one keyed read of `client_status_event` per call) is read by what the client may pay —
the client payment commands, their preview and « Ce que le client doit au cabinet » —, which no scale file runs. Its
reads are bounded under planted statistics instead (10,000 rows per planted table, n_distinct 2, generic plans):
`test_client_payment_reads_integration.py`, half its planted events now liquidations, reads none of them in any read or
command (`client_open_documents` 7 rows, bound 72, as before); `test_advance_reads_integration.py` measures
`client_opening_date` at 0 planted rows (bound 72). Unkeyed (a mutant), it read 9,824 to 39,296.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`): **15 passed** (1,338.9 s; round 1:
1,488.1 s — the VM's variance, no timed path changed). No Paris date change fell in it (07:39–08:02 UTC).

- `test_transfer_line_scale_integration.py`:
  - The 500-member lot short of one, rolled back: options 0.47 s, booking **1.95 s**, **2,995** `remittance_line`
    rows read and no sequential scan of a per-member table (round 1: 1.61 s, 2,995).
  - The same through the API: options 0.46 s, booking **1.72 s**, the allocation lock held 1.50 s (round 1: 0.50 /
    2.43 / 2.13 s).
  - The saturating lots: options 2.11 / 2.10 s, the command 2.25 / 2.06 s (`parts_do_not_add_up`).
  - 501 members 0.03 s and 5,000 members 0.013 / 0.013 s (`lot_too_large`).
  - The 50,000-item draft: options 0.09 s, command 0.18 s, lock 0.13 s.
  - The approval jobs took 126.2 s for 500 runs and 129.5 s for 501 (round 1: 139.7 / 135.0 s).
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 1.10 s, prepared in **11.8 s** (load 4.01 s, price 5.51 s, write 2.11 s; round 1: 15.7 s). The
    approval job and documents took 15.6 s.
  - The nightly checks took 4.2 s (the draft waiting 3.6 s), and the cancellation 3.69 s.
  - The re-run was prepared and approved in **29.8 s** (round 1: 34.5 s), and its payout booked in 0.8 s.
  - The nightly checks with the run booked took **4.6 s** (round 1: 6.0 s; 4.58 s warm with row counts on).
    `run_advance_checks` took **72 ms** own (round 1: 119 ms). They read `ledger_entry` 211,633 rows by index.
- The others:
  - 50,000 credits imported and matched in 31.2 s, allocated in 70.7 s; 1,000 returns in 30.6 s, their nightly
    checks 3.6 s.
  - The statement: 50,000 credits in 43.2 s (the 13,500-credit history in 10.9 s).
  - 25 receipt jobs in 71.3 s (14.3 ms per receipt).
  - The 50k boarding in 100 s (commit 26.0 s, confirm job 31.3 s).
  - The camt.053 import job in 26.2 s.
  - The transfer cancellation file: set-up 40.8 s, generation with the holds 2.86 s, nightly checks **0.62 s**
    (75,850 `bank_transfer` rows), the late predecessor's booking **1.79 s** (round 1: 2.23 s).
  - The 5,000-transfer file: the debit job 10.8 s, its nightly checks 0.44 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,348.5 s, 22.5 min; round 1:
23.8 min). No Paris date change fell in it (08:02–08:25 UTC), so carried low 4's helper validated none again.

- The 200 members' batch line's funds pass took 0.61 s, and the 200 RMT debits' job 0.59 s.
- « Générer le fichier » for 5,000 payouts (+50 cancelled) took 3.02 s (the fixture's 5,050 approval jobs 560.3 s;
  round 1: 617.4 s).
- The 5,000-member batch line's funds pass took **22.5 s** (23.1 s under auto_explain; round 1: 21.2 s). It read 20,000
  `remittance_line` rows and 0 `client_advance` rows, none by a sequential scan.
- The nightly checks took **1.15 s** (1.06 s warm; round 1: 1.05 s); `document_open`'s 5,100 calls took 120 ms own.
- 5,000 RMT debits were imported in 1.6 s, and the debit job took **21.0 s** in chunks of 8.8, 8.3 and 3.6 s (round 1:
  23.3 s).
- Then the 2,000 held chained runs: the funds pass took 20.8 s and the nightly checks **13.21 s** (the standalone
  reading 11.69 s; round 1: 13.67 s). Once the days were imported, they took **14.28 s** (round 1: 13.85 s).

### M2c-7c-1 review fixes, round 3 (2026-11-24, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What the round puts on the timed paths (ADR-0014 « M2c-7c-1 review fixes », round 3): nothing new that a scale file
times.
- `private.advance_recovery_of` now reads `client_opening_date`, instead of `client_opening_on`, for an advance without
  a claw-back clause. It is still one keyed read of `client_status_event` per call. The nightly's `advance_open`
  calls it once per advance older than 30 days, and the 50,000-line run's nightly checks read no such advance.
- The credits' `received_on` (one `ledger_entry` read by primary key per credit shown) is read only by the client
  space and « Ce que le client doit au cabinet », which no scale file runs.

Both are bounded under planted statistics instead (10,000 rows per planted table, n_distinct 2, generic plans):
- `test_client_payment_reads_integration.py`, `ledger_entry` now planted with 10,000 of the servicer's own entries,
  reads 1 `ledger_entry` row in `client_space_credits` and in `client_open_documents` with a credit (bound 72). The
  entry read unkeyed (a mutant): 10,064 and 10,069.
- `test_advance_reads_integration.py`: every read through `advance_recovery_of` reads 0 planted `client_status_event`
  rows, as before.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`): **15 passed** (1,411.7 s; round 2:
1,338.9 s — the VM's variance, no timed path changed). No Paris date change fell in it (09:38–10:01 UTC).

- `test_transfer_line_scale_integration.py`:
  - The 500-member lot short of one, rolled back: options 0.51 s, booking **1.72 s**, **2,995** `remittance_line`
    rows read, and no sequential scan of a per-member table (round 2: 1.95 s, 2,995).
  - The same through the API: options 0.51 s, booking **1.81 s**, the allocation lock held 1.57 s (round 2: 0.46 /
    1.72 / 1.50 s).
  - The saturating lots: options 1.97 / 2.20 s, the command 2.46 / 2.47 s (`parts_do_not_add_up`).
  - 501 members 0.03 s and 5,000 members 0.012 / 0.013 s (`lot_too_large`).
  - The 50,000-item draft: options 0.07 s, command 0.17 s, lock 0.13 s.
  - The approval jobs took 133.7 s for 500 runs and 138.0 s for 501 (round 2: 126.2 / 129.5 s).
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 1.27 s, prepared in **12.1 s** (load 3.48 s, price 6.15 s, write 2.34 s; round 2: 11.8 s). The
    approval job and documents took 17.2 s.
  - The nightly checks took 4.3 s (the draft waiting 4.4 s), and the cancellation 3.68 s.
  - The re-run was prepared and approved in **31.2 s** (round 2: 29.8 s), and its payout booked in 1.0 s.
  - The nightly checks with the run booked took **5.0 s** (round 2: 4.6 s; 4.91 s warm with row counts on).
    `run_advance_checks` took **83 ms** own (round 2: 72 ms). They read `ledger_entry` 211,530 rows by index.
- The others:
  - 50,000 credits imported and matched in 31.7 s, allocated in 71.4 s; 1,000 returns in 29.4 s, their nightly
    checks 4.1 s.
  - The statement: 50,000 credits in 43.2 s (the 13,500-credit history in 11.1 s).
  - 25 receipt jobs in 69.0 s (13.8 ms per receipt).
  - The 50k boarding in 110 s (commit 28.9 s, confirm job 35.6 s).
  - The camt.053 import job in 27.4 s.
  - The transfer cancellation file: set-up 43.8 s, generation with the holds 3.26 s, nightly checks **0.81 s**
    (75,850 `bank_transfer` rows), the late predecessor's booking **2.09 s** (round 2: 1.79 s).
  - The 5,000-transfer file: the debit job 12.4 s, its nightly checks 0.33 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,333.5 s, 22.2 min; round 2:
22.5 min). No Paris date change fell in it (10:02–10:24 UTC), so carried low 4's helper validated none again.

- The 200 members' batch line's funds pass took 0.46 s, and the 200 RMT debits' job 0.77 s.
- « Générer le fichier » for 5,000 payouts (+50 cancelled) took 3.72 s (the fixture's 5,050 approval jobs 540.3 s;
  round 2: 560.3 s).
- The 5,000-member batch line's funds pass took **23.8 s** (23.4 s under auto_explain; round 2: 22.5 s). It read 20,000
  `remittance_line` rows and 0 `client_advance` rows, none by a sequential scan.
- The nightly checks took **1.18 s** (1.16 s warm; round 2: 1.15 s); `document_open`'s 5,100 calls took 127 ms own.
- 5,000 RMT debits were imported in 1.4 s, and the debit job took **20.8 s** in chunks of 8.5, 8.4 and 3.8 s (round 2:
  21.0 s).
- Then the 2,000 held chained runs: the funds pass took 19.6 s and the nightly checks **13.77 s** (the standalone
  reading 12.50 s; round 2: 13.21 s). Once the days were imported, they took **15.79 s** (round 2: 14.28 s; the
  VM's variance: the round changes none of those checks' reads).

### M2c-7c-2: repayment requests (2026-11-24, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What 7c-2 puts on the timed paths (ADR-0014 « M2c-7c-2 »):
- The prepare's open advances (`jobs/remittances.py` `_open_advances`) add one read, `private.client_requested_advances`:
  7b's `client_open_advances` again and one probe of `advance_repayment_request_item` by `advance_id` per open
  advance of the run's client.
- The approval's re-check (`remittance_approval_refusal`) adds one keyed probe per advance its plan settles.
- The nightly's `run_advance_checks`: `advance_open` adds one probe per alert (`requested_on`), and one statement reads
  the servicer's letters not drawn by `advance_repayment_request_undrawn_idx`.
- The storage policy and the document scope gain one kind and one key prefix, and `advance_row` (« Avances ») one
  probe per row: on no scale path.

**Stale statistics** (`worker/tests/test_repayment_request_reads_integration.py`, the db job; not a scale file). In one
rolled-back transaction, 10,000 rows planted in each of the two request tables (over two values of each key, the
requests the servicer's own for other clients, their letters drawn) beside 7c-1's planted tables (settlements,
invoices, advances, credits, recoveries, payout accounts, status events, entries); each analysed with n_distinct 2
(the servicer's −1); every plan generic. Then each read and command as its caller runs it, on design §7.2's Martin
with the claw-back clause (A1 open, RV-3's draft taking it back): the rows each read from the planted tables (index
entries returned and sequential reads), bounded at 12 per advance + 60 for 7c-2's own reads, on 7c-2's tables only for
the earlier slices' reads they sit in, the night's `client_advance` at four reads of the planted table (4 × 10,000 + 60).
Measured:
- 7c-2's own reads and commands, each bounded at 72: `advance_repayment_preview` 12 (`client_advance` 10,
  `ledger_entry` 2; the same when it refuses `clawback_applies`), `request_advance_repayment` 20 (the request 1,
  `client_advance` 13, `ledger_entry` 6), `client_repayment_requests` 2 (the request 1, its item 1), the prepare's
  `client_requested_advances` 7, `repayment_request_job` 1, `withdraw_advance_repayment_request` 3 (the request, by
  its primary key, three statements).
- In the earlier slices' reads they sit in, 7c-2's tables at most 1 row each: the approval's re-check (« Valider »,
  then the approval job: `documents_changed`) 1 + 1 (and `client_advance` 1, `ledger_entry` 4); « Avances » (7b's
  `public.client_advances`, whose totals read the servicer's 20,010 planted advances by design, ADR-0014 7b « Left
  open », CCS-2) 1 + 1; the night's `run_advance_checks` full pass at d + 31 1 + 1 — its earlier statements read the
  servicer's planted advances once each (40,005 `client_advance` rows: 7b's `advance_ledger`, `advance_open` with its
  per-advance birth, 7a's full pass): once per statement, never per advance.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`): **15 passed** (1,433.1 s; 7c-1
round 3: 1,411.7 s). No Paris date change fell in it (13:55–14:19 UTC).

- `test_transfer_line_scale_integration.py`:
  - The 500-member lot short of one, rolled back: options 0.46 s, booking **1.70 s**, **2,995** `remittance_line`
    rows read, and no sequential scan of a per-member table (round 3: 1.72 s, 2,995).
  - The same through the API: options 0.50 s, booking **1.81 s**, the allocation lock held 1.58 s (round 3: 0.51 /
    1.81 / 1.57 s).
  - The saturating lots: options 2.08 / 1.98 s, the command 2.11 / 2.29 s (`parts_do_not_add_up`).
  - 501 members 0.03 s and 5,000 members 0.013 / 0.014 s (`lot_too_large`).
  - The 50,000-item draft: options 0.10 s, command 0.18 s, lock 0.14 s.
  - The approval jobs took 135.5 s for 500 runs and 131.9 s for 501 (round 3: 133.7 / 138.0 s).
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 1.28 s, prepared in **14.9 s**: the 50,000-line prepare 12.07 s (load 3.89 s, price 5.97 s, write
    2.21 s; round 3: 11.97 s, load 3.48 s) and a 5,000-line prepare the same worker drained 1.47 s. The approval job
    and documents took 17.0 s.
  - The nightly checks took 4.6 s (the draft waiting 4.4 s), and the cancellation 3.74 s.
  - The re-run was prepared and approved in **31.2 s** (round 3: 31.2 s), and its payout booked in 1.0 s.
  - The nightly checks with the run booked took **7.1 s** (round 3: 5.0 s; 9.04 s warm with row counts on).
    `run_advance_checks` took **114 ms** own (round 3: 83 ms). They read `ledger_entry` 211,587 rows by index (round
    3: 211,530). The functions 7c-2 does not touch slowed by
    the same factor in that run (`commission_key_open` 2,230 ms own for its 50,000 calls, round 3: 1,165;
    `run_remittance_runs_checks` 897 ms, round 3: 484), so a second reading followed: the file alone right after a fresh
    reset (14:49–14:54 UTC) prepared the 50,000 lines in **11.2 s**, re-ran in 31.9 s, and took **5.7 s** for these
    nightly checks (5.45 s warm), `run_advance_checks` **58 ms** own — the VM's variance.
- The others:
  - 50,000 credits imported and matched in 29.7 s, allocated in 73.0 s; 1,000 returns in 29.2 s, their nightly
    checks 3.6 s.
  - The statement: 50,000 credits in 44.2 s (the 13,500-credit history in 11.4 s).
  - 25 receipt jobs in 69.7 s (13.9 ms per receipt).
  - The 50k boarding in 117 s (commit 28.9 s, confirm job 34.8 s).
  - The camt.053 import job in 29.2 s.
  - The transfer cancellation file: set-up 45.1 s, generation with the holds 3.33 s, nightly checks **0.88 s**
    (75,850 `bank_transfer` rows), the late predecessor's booking **2.51 s** (round 3: 2.09 s).
  - The 5,000-transfer file: the debit job 12.1 s, its nightly checks 0.36 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,298.1 s, 21.6 min; round 3:
22.2 min). No Paris date change fell in it (14:20–14:42 UTC), so carried low 4's helper validated none again.

- The 200 members' batch line's funds pass took 0.42 s, and the 200 RMT debits' job 0.63 s.
- « Générer le fichier » for 5,000 payouts (+50 cancelled) took 3.79 s (the fixture's 5,050 approval jobs 548.2 s;
  round 3: 540.3 s).
- The 5,000-member batch line's funds pass took **22.5 s** (23.3 s under auto_explain; round 3: 23.8 s). It read
  20,000 `remittance_line` rows and 0 `client_advance` rows, none by a sequential scan.
- The nightly checks took **1.32 s** (1.22 s warm; round 3: 1.18 s); `document_open`'s 5,100 calls took 117 ms own.
- 5,000 RMT debits were imported in 1.3 s, and the debit job took **21.0 s** in chunks of 8.6, 8.3 and 3.9 s (round 3:
  20.8 s).
- Then the 2,000 held chained runs: the funds pass took 19.2 s and the nightly checks **13.42 s** (the standalone
  reading 11.54 s; round 3: 13.77 s). Once the days were imported, they took **12.94 s** (round 3: 15.79 s).

### M2c-7c-2 review fixes, round 1 (2026-11-24, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What round 1 puts on the timed paths (ADR-0014 « M2c-7c-2 review fixes », round 1):
- `private.transfer_line_check` (every transfer line's preview and booking) gains one rule on the double payout's
  return: one probe of `private.advance_live_request` per such advance (its items by advance, each request by key);
  `private.remitted_cover_release` the same per cover it would reverse.
- `public.client_payment_line` and `public.book_client_payment_line` read the label's `DRA-…` numbers: the requests by
  their number (`advance_repayment_request_number_uq`), their items and advances by key; the client's documents read
  once in the line's read (they were twice).
- `private.remittance_approval_refusal` (every approval job) runs with `enable_seqscan = off`.
- The nightly's `repayment_request_document_missing` reads the partial `advance_repayment_request_undrawn_idx`.

**Stale statistics** (`worker/tests/test_repayment_request_reads_integration.py`, the db job; not a scale file). As
7c-2's, with two additions: the queue of other drafts planted (`private.remittance_pending`, 10,000 rows over two
draft runs, `draft_run_id` at n_distinct 2) and watched; Martin's dedicated-account credit of 200 000 labelled with the
request's number, read and booked at the end. Measured (bound 72 each):
- The approval's re-check (« Valider », then the approval job: `documents_changed`): `private.remittance_pending`
  **3** rows (without the setting: **10,003** at the review, 10,057 in this test's mutant — a sequential scan of the
  queue), 7c-2's tables 1 + 1.
- `client_payment_line` (its label names the DRA) 20 rows (the requests 2, the item 1, `client_advance` 13,
  `commission_settlement` 2, `ledger_entry` 2); `book_client_payment_line` 24 (2, 1, 9, 2, 10).
- `withdraw_advance_repayment_request` (with `still_requested_by`) 6 (the request 3, its items 2, `client_advance` 1).
- The night's full pass: the requests 1 (it read **10,002** with a 4-column plain index, which lost to
  `advance_repayment_request_number_uq` priced at one row under the servicer's key analysed as unique; the partial
  index fixed it), the items 1. The other reads as 7c-2's.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`): **15 passed** (1,334.1 s; 7c-2:
1,433.1 s). No Paris date change fell in it (16:47–17:09 UTC).

- `test_transfer_line_scale_integration.py` (the path `transfer_line_check`'s new rule sits on):
  - The 500-member lot short of one, rolled back: options 0.44 s, booking **1.59 s** (499 bookings), no sequential
    scan of a per-member table (7c-2: 1.70 s).
  - The same through the API: options 0.45 s, booking **1.69 s**, the allocation lock held 1.50 s (7c-2: 0.50 / 1.81
    / 1.58 s).
  - The saturating lots: options 2.09 / 1.91 s, the command 2.31 / 2.31 s (`parts_do_not_add_up`).
  - 501 members 0.03 s and 5,000 members 0.016 / 0.029 s (`lot_too_large`).
  - The 50,000-item draft: options 0.08 s, command 0.23 s, lock 0.17 s.
  - The approval jobs (`remittance_approval_refusal` with the setting) took **129.0 s** for 500 runs and 128.5 s for
    501 (7c-2: 135.5 / 131.9 s).
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 1.30 s, prepared in **12.0 s** (the 50,000-line prepare: load 4.18 s, price 5.60 s, write 2.03 s;
    7c-2: 14.9 s). The approval job and documents took 14.6 s (7c-2: 17.0 s).
  - The nightly checks took 4.3 s (the draft waiting 4.2 s), and the cancellation 3.24 s.
  - The re-run was prepared and approved in **30.3 s** (7c-2: 31.2 s), and its payout booked in 1.1 s.
  - The nightly checks with the run booked took **5.4 s** (5.98 s warm with row counts on; 7c-2: 7.1 s, its second
    reading 5.7 s); `run_advance_checks` **89 ms** own (7c-2: 114 ms, second reading 58 ms). They read `ledger_entry`
    211,598 rows by index.
- The others:
  - 50,000 credits imported and matched in 28.9 s, allocated in 69.6 s; 1,000 returns in 29.1 s, their nightly checks
    3.8 s.
  - The statement: 50,000 credits in 39.9 s (the 13,500-credit history in 10.4 s).
  - 25 receipt jobs in 64.7 s (12.9 ms per receipt).
  - The 50k boarding in 103 s (commit 27.6 s, confirm job 32.7 s).
  - The camt.053 import job in 27.3 s.
  - The transfer cancellation file: set-up 40.6 s, generation with the holds 2.72 s, nightly checks **0.64 s** (75,850
    `bank_transfer` rows), the late predecessor's booking **1.98 s** (7c-2: 2.51 s).
  - The 5,000-transfer file: the debit job 12.5 s, its nightly checks 0.39 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,299.2 s, 21.7 min; 7c-2: 21.6
min). No Paris date change fell in it (17:10–17:32 UTC).

- The 200 members' batch line's funds pass took 0.54 s, and the 200 RMT debits' job 0.64 s (their approval jobs 20.5 s).
- « Générer le fichier » for 5,000 payouts (+50 cancelled) took 3.01 s (the fixture's 5,050 approval jobs **533.9 s**,
  `remittance_approval_refusal` with `enable_seqscan = off`; 7c-2: 548.2 s).
- The 5,000-member batch line's funds pass took **22.4 s** (22.6 s under auto_explain; 7c-2: 22.5 s). It read 20,000
  `remittance_line` rows and 0 `client_advance` rows, none by a sequential scan.
- The nightly checks took **1.00 s** (1.19 s warm; 7c-2: 1.32 s); `document_open`'s 5,100 calls took 101 ms own.
- 5,000 RMT debits were imported in 1.3 s, and the debit job took **19.9 s** in chunks of 7.6, 8.0 and 4.1 s (7c-2:
  21.0 s).
- Then the 2,000 held chained runs (their approval jobs 228.2 s): the funds pass took 18.5 s and the nightly checks
  **13.65 s** (the standalone reading 11.31 s; 7c-2: 13.42 s). Once the days were imported, they took **13.23 s**
  (7c-2: 12.94 s).

### M2c-7d-1: client events, payees and recipients (2026-11-24, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What 7d-1 puts on the timed paths (ADR-0014 « M2c-7d-1 »):
- `private.remittance_payout_blockers` (every prepare's blockers, the approval and its job, the file's generation and
  download through `transfer_hold_reason`) runs with `enable_seqscan = off` and reads, per client, its events in
  effect (`client_payee_rule`: the client's events by `client_status_event_client_idx`, each one's qualification by
  key) and its standing seizures (`client_seizures_standing`: the new `client_status_event_client_seizure_idx`, each
  release by `client_status_event_release_uq`).
- `private.gate_assignments` (every import's and regate's gating) reads the end of each client's mandate once per
  distinct client of the gated files (`client_end_event`); so does the allocation job's `load_files` (one statement
  for the job's files' clients).
- `public.forward_payment` re-reads the end once; `run_advance_checks` adds two statements on the servicer's partial
  indexes (`client_status_event_to_qualify_idx`, `client_status_event_seizure_idx`), each row's release or
  qualification probed by key (`not exists (… offset 0)`: as an anti-join the release check read
  `client_status_event_release_uq` whole in CI's order, 8,302 planted rows).

**Stale statistics** (`worker/tests/test_client_event_reads_integration.py`, the db job; not a scale file). In one
rolled-back transaction, 7c-1's planted tables (`test_client_payment_reads_integration._plant`: events, payout
accounts, settlements, invoices, advances, …) and 10,000 rows each of: other servicers' standing seizures and old
« Tutelle ou curatelle » rows (`qualified_at` null), their releases, representatives over two events, qualifications,
declared items over two events — each analysed with its keys' n_distinct pinned (2); every plan generic. Then each
read and command as its caller runs it, on a client whose death is recorded with its notary and whose notary's
account was confirmed by a second admin (a run prepared, a payment received after the death held for ops): the rows
each read from the planted tables (index entries returned and sequential reads), bounded at 60 per call.
Measured (bound 60 each; the file alone after the scale-payouts run; the same bounds held in CI's order in the db
job's run):
- The blockers: `remittance_payout_blockers` 6 (`client_status_event` 5, `client_payout_account` 1); the approval
  job's re-check 11 (7 + 4); `transfer_hold_reason` (the file's generation and download) 7 (5 + 2); « Valider »
  (`approve_remittance_runs`) 0.
- The gate: `regate_account` (`gate_assignments`) 6; the allocation job's `load_files` 3; `forward_payment` 3.
- The letters and the page: `client_addressee` 5 (4 + the representative 1); `client_events_view` 16 (11 + 3 + 2).
- The commands: a seizure recorded 0, its release 3, `set_client_representative` 5, `qualify_protection_event` 5,
  `propose_payout_account` (estate) 4, its confirmation (`payout_court_appointed`) 4.
- The night's `run_advance_checks` full pass: 4 (`client_status_event` 3, `client_status_event_qualification` 1).
- Before the fixes: the blockers and the page read **5,008** planted rows per call (the servicer's seizure index read
  whole for one client: the client-keyed partial index fixed it), and in CI's order the night read **8,302** (1,075 in
  the reproduction: the « no release naming it » anti-join read `client_status_event_release_uq` whole; the `offset 0`
  fence keeps it a probe per seizure).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`): **15 passed** (1,205.1 s; 7c-2
round 1: 1,334.1 s). No Paris date change fell in it (20:36–20:56 UTC).

- `test_transfer_line_scale_integration.py`:
  - The 500-member lot short of one, rolled back: options 0.44 s, booking **1.56 s** (499 bookings), **2,995**
    `remittance_line` rows read, no sequential scan of a per-member table (7c-2 round 1: 1.59 s).
  - The same through the API: options 0.37 s, booking **1.80 s**, the allocation lock held 1.63 s (7c-2 round 1:
    0.45 / 1.69 / 1.50 s).
  - The saturating lots: options 1.79 / 1.83 s, the command 2.01 / 1.84 s (`parts_do_not_add_up`).
  - 501 members 0.03 s and 5,000 members 0.011 / 0.010 s (`lot_too_large`).
  - The 50,000-item draft: options 0.07 s, command 0.17 s, lock 0.13 s.
  - The approval jobs (the blockers with this slice's reads) took **118.0 s** for 500 runs and 114.2 s for 501 (7c-2
    round 1: 129.0 / 128.5 s).
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 0.97 s, prepared in **10.4 s** (the 50,000-line prepare: load 3.29 s, price 4.88 s, write 2.03 s;
    7c-2 round 1: 12.0 s). The approval job and documents took 13.6 s (7c-2 round 1: 14.6 s).
  - The nightly checks took 3.8 s (the draft waiting 3.7 s), and the cancellation 3.14 s.
  - The re-run was prepared and approved in **26.7 s** (7c-2 round 1: 30.3 s), and its payout booked in 0.8 s.
  - The nightly checks with the run booked took **4.4 s** (7c-2 round 1: 5.4 s); `run_advance_checks` **66 ms** own
    (7c-2 round 1: 89 ms), its two new statements included. They read `ledger_entry` 211,602 rows by index.
- The others:
  - 50,000 credits imported and matched in 26.4 s (the gate's end per client included), allocated in **61.3 s** (the
    job's gate twin included; 7c-2 round 1: 69.6 s); 1,000 returns in 27.3 s, their nightly checks 3.6 s.
  - The statement: 50,000 credits in 37.2 s (the 13,500-credit history in 9.9 s).
  - 25 receipt jobs in 61.0 s (12.2 ms per receipt).
  - The 50k boarding in 94 s (commit 25.0 s, confirm job 28.3 s).
  - The camt.053 import job in 24.2 s.
  - The transfer cancellation file: set-up 37.5 s, generation with the holds 2.50 s, nightly checks **0.63 s**
    (75,850 `bank_transfer` rows), the late predecessor's booking **1.80 s** (7c-2 round 1: 1.98 s).
  - The 5,000-transfer file: the debit job 8.9 s, its nightly checks 0.31 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,226.5 s, 20.4 min; 7c-2 round 1:
21.7 min). No Paris date change fell in it (20:56–21:17 UTC).

- The 200 members' batch line's funds pass took 0.46 s, and the 200 RMT debits' job 0.60 s (their approval jobs
  18.5 s).
- « Générer le fichier » for 5,000 payouts (+50 cancelled) took 6.55 s (the fixture's 5,050 approval jobs **499.3 s**,
  the blockers with this slice's reads; 7c-2 round 1: 533.9 s).
- The 5,000-member batch line's funds pass took **20.6 s** (20.9 s under auto_explain; 7c-2 round 1: 22.4 s). It read
  20,000 `remittance_line` rows and 0 `client_advance` rows, none by a sequential scan.
- The nightly checks took **1.14 s** (0.93 s warm; 7c-2 round 1: 1.00 s); `document_open`'s 5,100 calls took 105 ms
  own.
- 5,000 RMT debits were imported in 1.3 s, and the debit job took **18.9 s** in chunks of 7.7, 7.3 and 3.8 s (7c-2
  round 1: 19.9 s).
- Then the 2,000 held chained runs (their approval jobs 216.1 s): the funds pass took 19.3 s and the nightly checks
  **13.53 s** (the standalone reading 10.64 s; 7c-2 round 1: 13.65 s). Once the days were imported, they took
  **13.83 s** (7c-2 round 1: 13.23 s).

### M2c-7d-1 review fixes, round 1 (2026-11-25, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What round 1 changes on the timed paths (ADR-0014 « M2c-7d-1 review fixes »):
- CC-1: `private.remittance_payout_blockers` calls the payee rule (`client_payee_rule`) and the seizures' read
  (`client_seizures_standing`) — SQL functions with SET clauses, parsed and planned at every call — only after a keyed
  probe finds an event in effect for the client (`client_status_event_client_idx`; a seizure for the latter,
  `client_status_event_client_seizure_idx`). Per payout at the file's generation, its first download and « Virements »
  (through `transfer_hold_reason`), per run at the approval.
- The letters' rule (`private.can_read_remittance_document`) reads, for a repayment request's letter only, its request
  by the letter's key (the new `advance_repayment_request_document_idx`); the portfolio confirmation gate reads what each
  of the client's events counts as (`client_event_effective`, the qualification by key).

**The blockers, 5,000 calls** (as `transfer_hold_reason` makes them: `v := f(client, 'EUR', current_date)` in a
plpgsql loop, in a rolled-back transaction after the db job's suites; 7c-2's body (before 7d-1) and 7d-1's as built
(`a7489f2`) created beside the fix; results equal for both clients; two runs):
- A client with no event: 7c-2's 0.119 / 0.133 s, 7d-1 as built **1.898 / 2.056 s**, the fix **0.245 / 0.239 s**.
- A client with a death recorded: 7c-2's 0.124 / 0.148 s, 7d-1 as built 2.638 / 2.877 s, the fix 2.377 / 2.243 s (the
  payee rule called; no seizure read). Left open: inlining the two nested functions (7f).

**Stale statistics** (`worker/tests/test_client_event_reads_integration.py`, the db job; not a scale file; bound 60 per
call), round 1's reads added beside 7d-1's (unchanged), with 10,000 repayment requests of two other clients planted,
their letters drawn and addressed to a notary (`document_id` n_distinct pinned to 2): the portfolio confirmation gate
17 (`client_status_event` 13, `client_status_event_qualification` 4); a letter to the notary read as the client's
member 1 (`advance_repayment_request`: the request by its letter), as staff 0; the client's requests as its member 1.
The index dropped (mutant): the test fails (the letter's rule reads the planted requests).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`): **15 passed** (1,308.9 s; 7d-1:
1,205.1 s). No Paris date change fell in it (23:37–23:59 UTC).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.48 s, booking
  **1.69 s** (499 bookings), 2,995 `remittance_line` rows read, no sequential scan of a per-member table; through the
  API 0.41 / 1.80 s, the allocation lock held 1.59 s; the saturating lots' options 2.19 / 2.08 s, the command 2.03 /
  2.13 s; 501 and 5,000 members refused `lot_too_large` at once. The approval jobs: **127.2 s** for 500 runs and 130.6 s
  for 501 (7d-1: 118.0 / 114.2 s). The fixture's « Virements », « Générer le fichier » and first download (timed from
  this round): 0.13 / 0.36 / 0.24 s at 500 payouts, 0.15 / 0.33 / 0.24 s at 501.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.22 s, prepared in **12.0 s** (load 3.70 s, price
  5.73 s, write 2.30 s; 7d-1: 10.4 s); the approval job and documents 15.8 s; the nightly checks 4.4 s (the draft
  waiting 4.3 s); the cancellation 3.69 s; the re-run prepared and approved in **28.0 s** (7d-1: 26.7 s), its payout
  booked in 0.9 s; the nightly checks with the run booked **4.5 s** (7d-1: 4.4 s), `run_advance_checks` 78 ms own.
- The others: 50,000 credits imported and matched in 30.2 s, allocated in **72.3 s** (7d-1: 61.3 s); 1,000 returns in
  28.6 s, their nightly checks 3.8 s; the statement's 50,000 credits in 37.7 s (the 13,500-credit history 10.3 s); 25
  receipt jobs in 61.1 s (12.2 ms per receipt); the 50k boarding in 98 s (commit 27.0 s, confirm job 31.1 s); the
  camt.053 import job 26.5 s; the transfer cancellation file: set-up 39.1 s, generation with the holds 2.39 s, nightly
  checks 0.78 s, the late predecessor's booking 1.78 s; the 5,000-transfer file: generation 2.32 s, download 0.66 s,
  the debit job 10.5 s, its nightly checks 0.37 s.

The `scale-payouts` job's command, after another fresh reset: **6 passed** (1,297.4 s, 21.6 min; 7d-1: 20.4 min). No
Paris date change fell in it (00:00–00:21 UTC, 2026-11-25: Paris already on the 25th).
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 2.89 s** (7d-1 as built: 6.55 s; 7c-2 round 1: 3.01 s);
  « Virements » with the 5,000 queued 1.53 s, the file's first download 2.53 s (timed from this round) — far under the
  API's 8 s. At 2,000 payouts: 0.55 / 1.06 / 1.24 s; at 200: 0.10 / 0.21 / 0.15 s.
- The fixture's 5,050 approval jobs **542.3 s** (7d-1: 499.3 s); the 200 members' batch line's funds pass 0.63 s, the
  200 RMT debits' job 0.69 s.
- The 5,000-member batch line's funds pass **20.2 s** (20.3 s under auto_explain; 7d-1: 20.6 s), 20,000
  `remittance_line` rows read and 0 `client_advance`, none by a sequential scan; the nightly checks **1.04 s** (0.97 s
  warm); 5,000 RMT debits imported in 1.2 s, the debit job **18.9 s** (chunks 7.6, 7.9 and 3.2 s).
- The 2,000 held chained runs (their approval jobs 222.8 s): the funds pass 19.2 s, the nightly checks **14.16 s** (the
  standalone reading 12.69 s; 7d-1: 13.53 s); once the days were imported 13.36 s.

### M2c-7d-2: set-off bars (2026-11-25, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What 7d-2 puts on the timed paths (ADR-0014 « M2c-7d-2 »):
- The prepare: one call of `private.prepare_set_off_facts` per run (the client's events by
  `client_status_event_client_idx`, once materialized for the bars) and, for a client with an opening only, each open
  invoice's birth (`private.document_born_on`: its lines by `remittance_line_invoice_idx`, its repricings by
  `remittance_line_repricing_invoice_idx`); `HELD_TO_SQL` gains a third branch (the withheld items, by the draft's key).
- The approval: `private.remittance_approval_refusal` reads the standing seizures (one probe of
  `client_status_event_client_seizure_idx`) and, for a plan that sets something off, `private.run_set_off_changed` (the
  draft by its key; each planned document's bar and birth); `private.approve_remittance_run` now runs with
  `enable_seqscan = off` (its queue delete by `remittance_pending_run_idx` whatever the statistics).
- The file's generation and download (`private.transfer_hold_reason`): for a payout whose run sets something off and
  whose client has an event (or whose draft recorded one), the same re-check; otherwise one probe.
- The debit (`private.post_run_settlements`): one keyed probe per booked run of a client with an event
  (`private.runs_with_client_events`), the barred settles of those runs only; a barred entry, its reversal and the
  guard's one keyed read per reversal; the commit check per barred settlement (`ledger_entry_reversed_once_uq`).
- The schedule's candidates: one more `bool_or` over the same unreserved queue, `enable_seqscan = off`.
- The nightly (`run_advance_checks`): `set_off_after_bar` — the servicer's clients by `organization_servicer_idx`, one
  probe each of their events, the settlements of those with an event.

**Stale statistics** (`worker/tests/test_set_off_bar_reads_integration.py`, the db job; not a scale file; bound 60 per
call): 7d-1's planted tables (and 7c-1's), 10,000 lines of two other invoices (`remittance_line`, `invoice_id`,
`run_id`, `client_organization_id` at n_distinct 2) and 10,000 queue items of two other servicers, half withheld
settlements, reserved by two drafts (`remittance_pending`, `draft_run_id`, `organization_id`, `client_organization_id`
at 2); every plan generic. Per call, tuples read from the watched tables: the bars 1 (`client_set_off_barred`), 4
(`client_set_off_bars`), the opening 1, a birth 2 (`commission_invoice` 1, `remittance_line` 1), `document_nettable` 7,
`prepare_set_off_facts` 11, `HELD_TO_SQL` 3 (`remittance_pending`), the approval's re-check 4, its job 18
(`commission_invoice` 7, `ledger_entry` 9, `remittance_pending` 2), the hold 4, `post_run_settlements` with the
withholding 50 (`client_status_event` 10, `commission_invoice` 6, `ledger_entry` 32, `remittance_line` 2),
`ledger_check_now` 5, the schedule's candidates 3, `set_off_after_bar_rows` 9. As first written, before the fixes:
`client_set_off_barred` 40,010 `client_status_event` (a partial index by kind, since dropped, read whole),
`prepare_set_off_facts` 180,075, `post_run_settlements` 80,034 and 10,044 `ledger_entry` (the guard's exception as an
anti-join over `ledger_entry_idempotency_uq`), `approve_remittance_run` 10,008 `remittance_pending` (its queue delete).
And in the db job's order 7d-1's reads test (`test_client_event_reads_integration.py`) read 7d-1's index of the
servicer's seizures whole — 5,005 tuples per blocker check, 10,006 per approval, 5,010 per « Événements du client » —
where the same test alone read 5: that index is dropped (ADR-0014 « M2c-7d-2 » D3); after it, 7d-1's test reads as
before (the blockers 5, the approval 6) in the db job's order too.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset` with
CI's logging settings: **15 passed** (1,372.9 s; 7d-1 round 1: 1,308.9 s). No Paris date change fell in it (03:53–04:16
UTC).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.44 s, booking
  **1.66 s** (499 bookings), no sequential scan of a per-member table; through the API 0.48 / 1.88 s, the allocation
  lock held 1.63 s; the saturating lots' options 2.04 / 2.05 s, the command 2.30 / 2.23 s; 501 and 5,000 members refused
  `lot_too_large` at once. The approval jobs: **132.1 s** for 500 runs and 133.0 s for 501 (7d-1 round 1: 127.2 / 130.6
  s: the seizure probe and the set-off re-check of each run, `enable_seqscan = off`); « Virements », « Générer le
  fichier » and the first download at 501 payouts 0.19 / 0.34 / 0.33 s.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.11 s, prepared in **11.1 s** (load 3.50 s, price
  5.15 s, write 2.26 s; 7d-1 round 1: 12.0 s); the approval job and documents 15.9 s; the nightly checks 4.3 s (the
  draft waiting 3.8 s); the cancellation 3.61 s; the re-run prepared and approved in **29.5 s** (7d-1 round 1: 28.0 s),
  its payout booked in 0.8 s; the nightly checks with the run booked **5.0 s** (4.5 s), `run_advance_checks` 80 ms own
  (78 ms).
- The others: 50,000 credits imported and matched in 31.4 s, allocated in **72.3 s** (72.3 s); 1,000 returns in 25.3 s,
  their nightly checks 3.8 s; the statement's 50,000 credits in 44.4 s (the 13,500-credit history 11.1 s); 25 receipt
  jobs in 76.3 s (15.3 ms per receipt); the 50k boarding in 104 s (commit 28.0 s, confirm job 32.5 s); the camt.053
  import job 27.8 s; the transfer cancellation file: set-up 42.4 s, generation with the holds 2.99 s; the 5,000-transfer
  file: generation 2.51 s, download 0.73 s, the debit job 10.3 s, its nightly checks 0.34 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,189.5 s, 19.8 min; 7d-1 round 1:
21.6 min). No Paris date change fell in it (04:17–04:37 UTC).
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 3.53 s** (7d-1 round 1: 2.89 s); « Virements » with the
  5,000 queued 1.62 s, the file's first download 2.95 s, far under the API's 8 s. At 2,000 payouts: 0.66 / 1.45 / 1.22
  s; at 200: 0.12 / 0.18 / 0.16 s.
- The fixture's 5,050 approval jobs **481.6 s** (7d-1 round 1: 542.3 s), the 2,000 held chained runs' 183.2 s (222.8 s),
  the 200 runs' 18.8 s. In the approval's re-check, `private.run_set_off_changed` (each run's own invoice is set off:
  the opening, the bars, each planned document's bar and birth) took 12.68 s over its 7,250 calls (1.75 ms each; its SQL
  functions are planned at each call), 2.6 % of those jobs.
- The 200 members' batch line's funds pass 0.50 s, the 200 RMT debits' job 0.62 s.
- The 5,000-member batch line's funds pass **24.3 s** (24.4 s under auto_explain; 7d-1 round 1: 20.2 s, 7c-2 round 1:
  22.4 s), 20,000 `remittance_line` rows read and 0 `client_advance`, none by a sequential scan; the nightly checks
  **1.08 s** (1.16 s warm; 1.04 s); 5,000 RMT debits imported in 1.3 s, the debit job **21.3 s** (chunks 8.7, 8.7 and
  3.8 s; 18.9 s). The heaviest statements of the funds pass under auto_explain are the ledger posting's temporary tables
  (`_lps_dim`, `_lps_x`), which 7d-2 does not change; of 7d-2's statements on these paths, `pg_stat_statements` (5,000
  entries, 2,067 evicted during the command) kept the guard's exception: 14,576 calls, 0.04 s in all (7a's check beside
  it 0.03 s). The debit's extra work for a client without an event is one probe of `client_status_event_client_idx` per
  run and two updates of the debit's temporary table (milliseconds for 5,000 runs). The 4.1 s and 2.4 s more, above the
  earlier rounds' spread on these two paths (20.2–22.4 s, 18.9–19.9 s), are not traced to 7d-2's statements and not
  explained here: to be read again on CI's next volume run.
- The 2,000 held chained runs: the funds pass 19.1 s (19.2 s), the nightly checks **12.40 s** (the standalone reading
  11.07 s; 7d-1 round 1: 14.16 s); once the days were imported 12.92 s (13.36 s).

### M2c-7d-2 review fixes, round 1 (2026-11-25, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What the round puts on the timed paths (ADR-0014 « M2c-7d-2 review fixes », round 1):
- The prepare: the births of the run's own invoices are built once (a dict of the charged entries' collection dates)
  and only for a client with an opening — no scan of the draft's lines per mandate (CC-6); the held items are read
  through `private.draft_held_items` (the worker's `HELD_TO_SQL` body, `enable_seqscan = off`, its per-run line reads
  fenced by the run's key: CC-5).
- The approval: `plan_sets_off_barred` reads the opening once and the draft's lines and repricings only when the client
  has one (CC-2, MLAW-1); the job's repricing insert reads each repriced line by its key.
- The « Lier » preview: one `private.run_settlement_split` per payout part (one probe of `client_status_event_client_idx`
  for a client without an event; the barred settles otherwise).
- The debit: unchanged but for the event gate matched by position (CC-4).
- The schedule's candidates (`pending_item_deadlines`): its returned-payout and withheld-settlement branches read each
  run's lines by the primary key's prefix only.
- The nightly's `set_off_after_bar_rows`: for a row barred by a mandate's end, its entry and the end event by their
  keys (MLAW-3).

**Stale statistics** (`worker/tests/test_set_off_bar_reads_integration.py`, the db job; bound 60 per call), now also
with 10,000 draft lines and 10,000 draft repricings of two other drafts (`run_id`, `mandate_id` / `line_run_id` at
n_distinct 2), the re-check measured after a redressement and after a seizure, `HELD_TO_SQL` with the withheld item
reserved, the run page's `remittance_run_withheld` and the candidates with the client a candidate. Per call: the bars 1
and 4, the opening 1, a birth 2, `document_nettable` 7, `prepare_set_off_facts` 11, `HELD_TO_SQL` 3 (the withheld item
reserved: 9 — `remittance_pending` 6, `ledger_entry` 2, `remittance_line` 1), the re-check 4 (after the redressement 2,
after the seizure 2), its job 22 (`client_status_event` 4, `commission_invoice` 6, `ledger_entry` 9,
`remittance_draft_line` 1, `remittance_pending` 2), the hold 4, `post_run_settlements` 50, `ledger_check_now` 3,
`remittance_run_withheld` 5 (`commission_settlement` 2), the candidates 38 (`remittance_pending` 35, `ledger_entry` 2,
`remittance_line` 1), `set_off_after_bar_rows` 9. Before the round's fixes, on this stack: `HELD_TO_SQL` 30,009
`remittance_pending` (`a9a6e65`'s version of the test failed its bound here too) and, the withheld item reserved, 10,004
to 20,004 `remittance_line`; the candidates 10,119 `remittance_line`; the approval's job 5,003 `remittance_line` once draft
repricings were planted.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset` with
CI's logging settings: **15 passed** (1,498.6 s; 7d-2: 1,372.9 s). No Paris date change fell in it (07:47–08:12 UTC).
The VM ran slower through this session — the allocation of 50,000 credits, a path the round does not touch, took 80.7 s
(7d-2: 72.3 s), the 50,000 boarding 99 s (104 s) —: compare within a run, not across.
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.43 s, booking
  **2.02 s** (499 bookings), no sequential scan of a per-member table; through the API 0.47 / 2.03 s, the allocation
  lock held 1.90 s; the saturating lots' options 2.40 / 2.47 s, the command 2.50 / 2.58 s; 501 and 5,000 members refused
  `lot_too_large` at once. The approval jobs: **150.6 s** for 500 runs and 148.5 s for 501 (7d-2: 132.1 / 133.0 s);
  « Virements », « Générer le fichier » and the first download at 501 payouts 0.23 / 0.40 / 0.30 s.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.47 s, prepared in **12.1 s** (load 3.90 s, price
  5.48 s, write 2.54 s; 7d-2: 11.1 s); the approval job and documents 17.7 s; the nightly checks 4.8 s (the draft
  waiting 4.4 s); the cancellation 4.00 s; the re-run prepared and approved in **32.4 s** (29.5 s), its payout booked in
  0.9 s; the nightly checks with the run booked **5.3 s** (5.0 s), `run_advance_checks` 78 ms own (80 ms).
- The others: 50,000 credits imported and matched in 35.3 s, allocated in 80.7 s; 1,000 returns in 26.7 s, their
  nightly checks 3.8 s; the statement's 50,000 credits in 42.4 s (the 13,500-credit history 11.5 s); 25 receipt jobs in
  70.5 s (14.1 ms per receipt); the camt.053 import job 32.4 s; the transfer cancellation file: set-up 44.4 s; the
  5,000-transfer file: generation 3.95 s (command), job 0.95 s; the 50,000-item draft requeued: options 0.09 s, booking
  0.19 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,333.4 s, 22.2 min; 7d-2: 19.8 min).
No Paris date change fell in it (08:12–08:35 UTC).
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 4.04 s** (7d-2: 3.53 s); « Virements » with the 5,000
  queued 1.78 s, the file's first download 3.73 s, under the API's 8 s. At 2,000 payouts: 0.79 / 1.83 / 1.47 s; at 200:
  0.11 / 0.18 / 0.19 s.
- The fixture's 5,050 approval jobs **536.3 s** (7d-2: 481.6 s), the 2,000 held chained runs' 220.5 s (183.2 s), the
  200 runs' 21.9 s (18.8 s): about 11 % slower each, as the untouched allocation above.
- The 200 members' batch line's funds pass 0.54 s, the 200 RMT debits' job 0.69 s.
- The 5,000-member batch line's funds pass **27.9 s** (28.6 s under auto_explain; 7d-2: 24.3 s); the nightly checks
  **1.24 s** (1.08 s); 5,000 RMT debits imported in 1.5 s, the debit job **23.9 s** (chunks 9.7, 9.4 and 4.5 s; 21.3 s).
- The 2,000 held chained runs: the funds pass 20.7 s (19.1 s), the nightly checks **13.63 s** (the standalone reading
  12.36 s; 12.40 s); once the days were imported 15.03 s (12.92 s).

### M2c-7d-3: declarations, liquidation, statement (2026-11-25, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What 7d-3 puts on the timed paths (ADR-0014 « M2c-7d-3 »):
- The nightly (`run_advance_checks`): the servicer's clients with a proceeding or a liquidation read once (`v_proc`: the
  servicer's clients by `organization_servicer_idx`, one probe each of their events), then, for those clients only,
  `claims_to_declare`, `post_opening_unpaid` and `payout_after_liquidation` (each client's invoices, advances and runs
  by their client indexes, each document's open part and birth by key); `advance_open` leaves those clients out;
  `set_off_after_bar` one probe of `set_off_outcome` by its key per alerted settlement.
- The remittance runs' checks (`invoice_overdue`): one call of `private.invoice_to_declare` per overdue invoice (its
  client's events by `client_status_event_client_idx`; the birth only for a client with an opening).
- The statement build (the documents job): the end of the mandate and the addressees as of K (the client's events and
  representatives by key), the withheld rows (each by its entry's key); and `enable_seqscan = off` (D5).
- The payout's debit, the prepare, the approval and the files: unchanged.

**Stale statistics** (`worker/tests/test_declarations_reads_integration.py`, the db job; not a scale file; bound 60 per
call): 7d-2's planted tables (and 7d-1's, 7c-1's) and 10,000 rows each of the bookings of two other transfers
(`bank_line_booking`), the dispositions of other payouts, the outcomes of other settlements and the booked runs of two
other servicers with their transfers (`remittance_run`), each with its keys' n_distinct pinned to 2; every plan
generic. Per call, tuples read from the watched tables: `client_procedure_facts` 1, `client_claims_to_declare` 7,
`client_post_opening_unpaid` 5, `client_payouts_after_liquidation` 17, « Enregistrer la suite » 23, « Compensation
maintenue » 7, the statement build 32 without an event and 35 with fr-4's parts, `remittance_run_withheld` 1. The
nightly's two functions read the servicer's own planted rows whole by design, as their 7d-2 bodies do on the same books
(`run_advance_checks` 20,000 `client_advance` both; `run_remittance_runs_checks` 180,025 / 180,026 `commission_invoice`),
none of 7d-3's planted rows, and at most 14 tuples more of any table than the 7d-2 bodies. As first written: the
outcome's guard 10,013 `ledger_entry` (its entry read through the servicer's key), the statement build 10,000
`remittance_pending` (its « not remitted » read by a sequential scan of every servicer's queue — present in 7c's body,
measured here for the first time); both fixed (D5).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset` with
CI's logging settings: **15 passed** (1,477.9 s; 7d-2 round 1, this branch's base: 1,498.6 s). No Paris date change
fell in it (11:45–12:10 UTC). The VM ran as slowly as in 7d-2's round 1 (the untouched allocation 76.8 s, then 80.7 s;
7d-2 itself 72.3 s): the figures in brackets are round 1's.
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.51 s, booking
  **2.00 s** (2.02 s; 499 bookings), no sequential scan of a per-member table; through the API 0.58 / 2.23 s, the
  allocation lock held 1.91 s; the saturating lots' options 2.59 / 2.57 s, the command 2.49 / 2.47 s; 501 and 5,000
  members refused `lot_too_large` at once. The approval jobs: **148.0 s** for 500 runs and 145.4 s for 501 (150.6 /
  148.5 s); « Virements », « Générer le fichier » and the first download at 501 payouts 0.21 / 0.45 / 0.31 s.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.30 s, prepared in **12.9 s** (load 4.46 s, price
  5.75 s, write 2.50 s; 12.1 s); the approval job and documents 16.6 s (17.7 s; the statement's build 6.72 s, 7.33 s
  for the one drawn again); the nightly checks 4.5 s (the draft waiting 4.0 s); the cancellation 3.61 s; the re-run
  prepared and approved in **31.9 s** (32.4 s), its payout booked in 1.0 s; the nightly checks with the run booked
  **5.3 s** (5.3 s), `run_advance_checks` 120 ms own (78 ms: its client probe for `v_proc` and the three checks' reads,
  for a servicer with no client in a proceeding), `run_remittance_runs_checks` 400 ms.
- The others: 50,000 credits imported and matched in 33.1 s, allocated in 76.8 s; 1,000 returns in 29.1 s, their
  nightly checks 4.1 s; the statement's 50,000 credits in 45.0 s (the 13,500-credit history 12.2 s); 25 receipt jobs in
  70.8 s (14.2 ms per receipt); the 50k boarding in 112 s (commit 30.6 s, confirm job 34.5 s); the camt.053 import job
  31.0 s; the transfer cancellation file: set-up 44.4 s, generation with the holds 3.34 s; the 5,000-transfer file:
  generation 3.30 s (command), download 1.23 s, the debit job 12.4 s, its nightly checks 0.37 s; the 50,000-item draft
  requeued: options 0.08 s, booking 0.19 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** (1,293.7 s, 21.6 min; round 1: 22.2
min). No Paris date change fell in it (12:10–12:32 UTC).
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 3.98 s** (4.04 s); « Virements » with the 5,000 queued
  1.78 s, the file's first download 3.31 s, under the API's 8 s. At 2,000 payouts: 0.70 / 1.47 / 1.31 s; at 200: 0.12 /
  0.20 / 0.19 s.
- The fixture's 5,050 approval jobs **529.9 s** (536.3 s), the 2,000 held chained runs' 209.1 s (220.5 s), the 200 runs'
  20.8 s (21.9 s).
- The 200 members' batch line's funds pass 0.54 s, the 200 RMT debits' job 0.77 s.
- The 5,000-member batch line's funds pass **26.8 s** (26.2 s under auto_explain; 27.9 s), 20,000 `remittance_line`
  rows read and 0 `client_advance`, none by a sequential scan; the nightly checks **1.21 s** (1.24 s); 5,000 RMT debits
  imported in 1.3 s, the debit job **24.1 s** (chunks 9.6, 9.8 and 4.5 s; 23.9 s). 7d-3 changes none of these
  statements.
- The 2,000 held chained runs: the funds pass 20.7 s (20.7 s), the nightly checks **13.38 s** (the standalone reading
  11.93 s; 13.63 s); once the days were imported 13.79 s (15.03 s).

**The statement's build, measured apart** (one session, the same 20 booked runs, 200 builds a round, three rounds):
`private.remittance_statement_build` takes 10.0 / 10.5 / 10.8 ms with 7d-3's body, 10.1 / 9.7 / 10.0 ms with 7d-2's,
10.7 / 10.7 / 12.2 ms with 7d-3's without `enable_seqscan = off` — under a millisecond more a statement. Every budget
held.

### M2c-7d-3 review fixes, round 1 (2026-11-25, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What round 1 changes on the timed paths (ADR-0014 « M2c-7d-3 review fixes »):
- The remittance runs' checks (`invoice_overdue`, CC-1): the servicer's clients with a proceeding or a liquidation read
  once (`v_proc`: the servicer's clients by `organization_servicer_idx`, one probe each of their events), then
  `private.invoice_to_declare` called for their overdue invoices only, none for the others.
- The nightly's `set_off_after_bar` (ML-2): each settlement part of a client with a barring event tested by one call of
  `private.settlement_set_off_alert` (the same reads as before, in one function, evaluated once per part).
- The statement build (ML-1): each of the client's events read through `private.client_event_known` (the event and its
  qualification by their keys) — a client with no event, none.
- « Compensation maintenue »: the alert's test per settlement part of its run's plan.

**Stale statistics** (`worker/tests/test_declarations_reads_integration.py`, the db job; not a scale file; bound 60 per
call), same plants as 7d-3's:
- (CC-1) `run_remittance_runs_checks` at today + 90 emits 10,000+ `invoice_overdue` rows (7c-1's plant of the servicer's
  invoices, overdue and open, of two clients with no event: `document_open` called 10,000+ times) and calls
  `invoice_to_declare` **0** times (the client in liquidation's invoices are settled); the guard removed: **10,001**
  calls. The reviewer's probe on the same plant measured that body at 4.00 / 3.46 / 3.36 s against 1.91 / 1.92 / 1.83 s
  for 7d-2's and 1.88 / 1.97 / 1.99 s with the guard: the guard gives back 7d-2's time.
- (CC-2) a second client walked through the real jobs (a redressement after the download, the debit withholding the
  set-off, the next run giving it back, its payout debited then returned by a camt.053 return, the account confirmed
  again, a later run paying it again). Tuples per call, three runs: `remittance_run_withheld` (returned, repaid)
  `bank_transfer` 7, `remittance_run` 3–6, `bank_line_booking` 4, `ledger_entry` 3, `commission_settlement` 2,
  `remittance_line` 2; the giving run's statement build (its withheld row) `remittance_run` 23–32 (the client's earlier
  runs, by `remittance_run_client_idx`, pre-existing), `bank_transfer` 9–11, `ledger_entry` 10, `bank_line_booking` 2,
  `client_status_event` 2, `remittance_line` 1 — never the 10,000 planted bookings of other transfers.
- The first test, after a fresh reset: `client_procedure_facts` 1, `client_claims_to_declare` 7,
  `client_post_opening_unpaid` 5, `client_payouts_after_liquidation` 16, « Enregistrer la suite » 22, « Compensation
  maintenue » 9 (the alert's test: 2 events, 3 entries, the run, the invoice, its settlement), the statement build 27
  without an event and 35 with fr-4's parts (`client_status_event` 8: each event and its qualification by key),
  `remittance_run_withheld` 1; the nightly's two functions as their 7d-2 bodies on the same books
  (`run_advance_checks` 20,000 `client_advance` both; `run_remittance_runs_checks` 180,026 `commission_invoice` both,
  plus 1 `client_status_event` for `v_proc`).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset` with
CI's logging settings: **15 passed** in 1,566.1 s (14:33–14:59 UTC; 7d-3: 1,477.9 s). No Paris date change fell in it.
The VM ran slower than in 7d-3's run on paths the round does not touch (the 50k boarding 128 s against 112 s, its
commit 36.8 s against 30.6 s; the receipts 15.8 ms against 14.2 ms a receipt; the approval jobs of 501 runs 160.3 s
against 145.4 s): the figures in brackets are 7d-3's.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.38 s, prepared in **13.3 s** (12.9 s); the
  approval job and documents 19.0 s (16.6 s; the statement's build 7.58 s, 7.92 s for the one drawn again — 6.72 s;
  the client has no event: `client_event_known` is not called); the nightly checks 5.2 s with the draft waiting; the
  cancellation 4.07 s; the re-run prepared and approved in **33.0 s** (31.9 s), its payout booked in 1.0 s; the nightly
  checks with the run booked **5.7 s** (5.3 s): `run_advance_checks` 145 ms own (120 ms), `run_remittance_runs_checks`
  507 ms (400 ms: `v_proc`'s probe of the servicer's clients, then no `invoice_to_declare` call — the servicer has no
  client in a proceeding).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.54 s, booking
  **1.92 s** (2.00 s; 499 bookings), no sequential scan of a per-member table; through the API 0.70 / 2.06 s, the
  allocation lock held 1.75 s; the saturating lots' options 2.49 / 2.78 s, the command 2.53 / 2.63 s; 501 and 5,000
  members refused `lot_too_large` at once. The approval jobs: **150.5 s** for 500 runs and 160.3 s for 501 (148.0 /
  145.4 s); « Virements », « Générer le fichier » and the first download at 501 payouts 0.17 / 0.37 / 0.29 s.
- The others: 50,000 credits imported and matched in 33.7 s, allocated in 77.7 s (76.8 s); 1,000 returns in 28.8 s,
  their nightly checks 4.2 s; the statement's 50,000 credits in 44.3 s (the 13,500-credit history 12.8 s); 25 receipt
  jobs in 79.1 s; the camt.053 import job 34.1 s; the transfer cancellation file: set-up 42.9 s, generation with the
  holds 3.70 s, its nightly checks 0.86 s; the 5,000-transfer file: generation 2.97 s (command), download 0.69 s, the
  debit job 11.4 s, its nightly checks 0.40 s; the 50,000-item draft requeued: options 0.08 s, booking 0.18 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,394.1 s (15:00–15:23 UTC; 7d-3:
1,293.7 s). No Paris date change fell in it.
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 4.13 s** (3.98 s); « Virements » with the 5,000 queued
  2.09 s, the file's first download 3.65 s, under the API's 8 s. At 2,000 payouts: 0.83 / 1.77 / 1.33 s; at 200: 0.13 /
  0.20 / 0.17 s.
- The fixture's 5,050 approval jobs **577.7 s** (529.9 s), the 2,000 held chained runs' 228.7 s (209.1 s), the 200 runs'
  21.8 s (20.8 s).
- The 200 members' batch line's funds pass 0.52 s, the 200 RMT debits' job 0.83 s.
- The 5,000-member batch line's funds pass **28.1 s** (30.8 s under auto_explain; 26.8 s), 20,000 `remittance_line`
  rows read and 0 `client_advance`, none by a sequential scan; the nightly checks **1.23 s** (1.21 s); 5,000 RMT debits
  imported in 1.6 s, the debit job **24.2 s** (chunks 10.1, 9.3 and 4.5 s; 24.1 s). Round 1 changes none of these
  statements.
- The 2,000 held chained runs: the funds pass 22.3 s (20.7 s), the nightly checks **14.15 s** (the standalone reading
  12.96 s; 13.38 s); once the days were imported 14.17 s (13.79 s).

Every budget held; the differences follow the VM's speed on untouched paths (the approval jobs, the funds passes).

### M2c-7d-3 review fixes, round 2 (2026-11-25, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What round 2 changes on the timed paths (ADR-0014 « M2c-7d-3 review fixes », round 2):
- **The remittance runs' checks** (`private.run_remittance_runs_checks`):
  - `v_proc` and `v_evt` are read in one pass: the servicer's clients by `organization_servicer_idx`, each one's
    events by `client_status_event_client_idx` (one probe per client, as before).
  - The withheld branch of `invoice_overdue` reads, for each client with an event, its invoices by
    `commission_invoice_client_idx`, then one `private.invoice_withheld_on` per invoice with no due date (the invoice
    by its key, its run's barred settlement by `ledger_entry_idempotency_uq`), and `document_open` only for those
    withheld.
  - A servicer with no client with an event reads nothing more.
- **The nightly's `post_opening_unpaid`** (`private.client_post_opening_unpaid`, for the clients in a proceeding or a
  liquidation only) calls `invoice_withheld_on` once for each of their invoices with no due date.

**Stale statistics** (`worker/tests/test_declarations_reads_integration.py`, the db job; not a scale file; bound 60 per
call), with 7d-3's plants. The new test walks two clients through the real jobs: each run sets its own invoice off in
full, the file is downloaded, then a liquidation or a death is recorded and the debit withholds the set-off. Tuples
per call:
- `invoice_withheld_on`: `commission_invoice` 1, `ledger_entry` 1.
- `client_post_opening_unpaid`, the client in liquidation: `commission_invoice` 5, `client_status_event` 2,
  `remittance_line` 2, `ledger_entry` 1.
- The nightly's two functions whole, for each servicer, against their 7d-2 bodies on the same books:
  - `run_advance_checks`, the liquidation's servicer: `client_advance` 20,000 both (7c-1's plant), `client_status_event`
    7 (1), `ledger_entry` 8 (6), `commission_invoice` 8 (—), `bank_transfer` 4 (—), `remittance_run` 6 (1),
    `remittance_line` 4 (1). The figures in brackets are the 7d-2 body's.
  - `run_remittance_runs_checks`, the liquidation's servicer: `commission_invoice` 180,013 (180,012: 7c-1's plant, read
    whole by design), `client_status_event` 2 (—), `private.remittance_pending` 31 (17), `remittance_run` 28 (22).
  - `run_remittance_runs_checks`, the deceased client's servicer: `commission_invoice` 11 (8), `ledger_entry` 3 (2),
    `client_status_event` 1 (—).
  - All within 60 a table of the 7d-2 bodies'. The liquidation's invoice is in `post_opening_unpaid` alone, the deceased
    client's in `invoice_overdue` alone.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset` with
CI's logging settings: **15 passed** in 1,497.6 s (16:58–17:23 UTC; round 1: 1,566.1 s). No Paris date change fell in
it. The VM ran a little faster than in round 1 on the paths the round does not touch: the 50k boarding took 115 s
(128 s), its commit 31.8 s (36.8 s), and the receipts 14.3 ms a receipt (15.8 ms). The figures in brackets are round
1's.
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 1.27 s and prepared in **14.5 s** (13.3 s).
  - The approval job and documents took 18.0 s (19.0 s); the statement's build took 6.90 s, and 6.67 s for the one drawn
    again.
  - The nightly checks took 4.7 s (4.5 s with the draft waiting), and the cancellation 3.91 s.
  - The re-run was prepared and approved in **30.4 s** (33.0 s), and its payout booked in 0.9 s.
  - The nightly checks with the run booked took **5.1 s** (5.7 s): `run_advance_checks` 82 ms own (145 ms) and
    `run_remittance_runs_checks` 450 ms (507 ms). The servicer has no client with an event, so `v_evt` is empty and the
    withheld branch reads nothing.
- `test_transfer_line_scale_integration.py`:
  - The 500-member lot short of one (rolled back): options 0.49 s, booking **1.75 s** (1.92 s; 499 bookings), with no
    sequential scan of a per-member table. Through the API: 0.56 / 1.87 s, the allocation lock held 1.63 s.
  - The saturating lots: options 2.22 / 2.44 s, the command 2.35 / 2.35 s. 501 and 5,000 members are refused
    `lot_too_large` at once.
  - The approval jobs: **141.8 s** for 500 runs and 146.0 s for 501 (150.5 / 160.3 s). « Virements », « Générer le
    fichier » and the first download at 501 payouts: 0.24 / 0.46 / 0.33 s.
- The others:
  - Credits: 50,000 imported and matched in 33.2 s, allocated in 74.0 s (77.7 s); 1,000 returns in 28.3 s, their
    nightly checks 3.8 s.
  - The statement's 50,000 credits in 41.6 s (the 13,500-credit history in 10.8 s); 25 receipt jobs in 71.4 s; the
    camt.053 import job 29.8 s.
  - The transfer cancellation file: set-up 39.4 s, generation with the holds 3.24 s, its nightly checks 0.78 s.
  - The 5,000-transfer file: generation 3.10 s (command), download 0.70 s, the debit job 11.0 s, its nightly checks
    0.34 s.
  - The 50,000-item draft requeued: options 0.07 s, booking 0.19 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,314.5 s (17:24–17:46 UTC; round
1: 1,394.1 s). No Paris date change fell in it.
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 3.50 s** (4.13 s). « Virements » with the 5,000 queued
  took 2.01 s and the file's first download 3.55 s, under the API's 8 s. At 2,000 payouts: 1.25 / 2.12 / 1.57 s; at
  200: 0.15 / 0.19 / 0.17 s.
- The fixture's 5,050 approval jobs took **526.8 s** (577.7 s), the 2,000 held chained runs' 217.1 s (228.7 s), the 200
  runs' 20.3 s (21.8 s).
- The 200 members' batch line: its funds pass 0.53 s; the 200 RMT debits' job 0.71 s.
- The 5,000-member batch line:
  - Its funds pass took **27.6 s** (29.2 s under auto_explain; 28.1 s), reading 20,000 `remittance_line` rows and 0
    `client_advance`, none by a sequential scan.
  - The nightly checks took **1.24 s** (1.23 s), `run_remittance_runs_checks` 242 ms own.
  - 5,000 RMT debits were imported in 1.4 s; the debit job took **24.1 s** (chunks 10.3, 9.6 and 4.1 s; 24.2 s).
- The 2,000 held chained runs: the funds pass took 22.6 s (22.3 s) and the nightly checks **15.26 s** (13.09 s read
  standalone; 14.15 s), or 14.37 s once the days were imported (14.17 s).

Every budget held. The differences follow the VM's speed on paths the round does not touch: the approval jobs, the
funds passes and the held chains' `remittance_chain_events`. None of the servicers these files build has a client with
an event, so the withheld branch reads nothing in them.

### M2c-7d-3 review fixes, round 3 (2026-11-25, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What round 3 changes on the timed paths (ADR-0014 « M2c-7d-3 review fixes », round 3):
- **The statement's build** (`private.statement_mandate_end`): the ends the code applied before the one at K
  (`earlier`) come from a window over the same rows it already read (the client's events effective by K, each through
  `client_event_known`): no new read. A client with no event reads nothing more.
- **The nightly's `post_opening_unpaid`** (`private.client_post_opening_unpaid`, for the clients in a proceeding or a
  liquidation only): the client's invoice bar once (`client_set_off_barred`) and, when one applies, the day it was
  recorded once (`client_set_off_bar_recorded_on`: the client's events by `client_status_event_client_idx`, each end's
  knowledge or each standing seizure by its key).

**Stale statistics** (`worker/tests/test_declarations_reads_integration.py`, the db job; not a scale file; bound 60 per
call), with 7d-3's plants. The new test walks two clients through the real jobs: each run sets its own invoice off in
full, approved, its payout ordered in no file; then a liquidation, or a death and a seizure, is recorded. Tuples per
call:
- `client_set_off_bar_recorded_on`: `client_status_event` 1 (a liquidation), 3 (the mandate's end), 2 (a seizure).
- `client_post_opening_unpaid` the next day, the client in liquidation: `commission_invoice` 5, `client_status_event` 4,
  `remittance_run` 3, `remittance_line` 2 (its own invoice listed).
- `run_advance_checks` whole for its servicer, against its 7d-2 body on the same books: `client_advance` 20,000 both
  (7c-1's plant), `client_status_event` 9 (1), `commission_invoice` 8 (—), `ledger_entry` 4 (4), `remittance_line` 3
  (—), `bank_transfer` 2 (—), `client_payout_account` 2 (—), `remittance_run` 2 (—); within 60 a table of the 7d-2
  body's. The invoice is in `post_opening_unpaid` alone.
- The statement build with an old « Tutelle ou curatelle » row, a death and the row's qualification before K:
  `client_status_event` 12, `remittance_run` 8, `commission_invoice` 6, `ledger_entry` 2 (`earlier` the death).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset` with
CI's logging settings: **15 passed** in 1,491.9 s (20:05–20:31 UTC; round 2: 1,497.6 s). No Paris date change fell in
it. The figures in brackets are round 2's.
- `test_remittance_scale_integration.py` (50,000 lines):
  - Reserved in 1.41 s and prepared in **11.7 s** (14.5 s).
  - The approval job and documents took 16.5 s (18.0 s); the statement's build took 6.61 s, and 7.74 s for the one
    drawn again (6.90 / 6.67 s; the client has no event: the build reads nothing more).
  - The nightly checks took 4.5 s (4.7 s), and the cancellation 4.11 s (3.91 s).
  - The re-run was prepared and approved in **34.0 s** (30.4 s), and its payout booked in 0.9 s.
  - The nightly checks with the run booked took **5.15 s** (5.1 s): `run_advance_checks` 80 ms own (82 ms) and
    `run_remittance_runs_checks` 381 ms (450 ms).
- The 50k boarding took 111 s (115 s), its commit 29.1 s (31.8 s); the receipts 14.7 ms a receipt (14.3 ms).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, booking **1.76 s** (1.75 s; 499 bookings),
  no sequential scan of a per-member table; through the API 0.52 / 1.91 s, the allocation lock held 1.73 s; the
  saturating lots 2.35 / 2.74 s and 2.50 / 2.62 s; 501 and 5,000 members refused `lot_too_large` at once; the approval
  jobs **150.6 s** for 500 runs and 157.1 s for 501 (141.8 / 146.0 s).
- The others: 50,000 credits imported and matched in 32.6 s, allocated in 77.4 s; 1,000 returns in 28.8 s, their
  nightly checks 4.3 s; the statement's 50,000 credits in 45.6 s (the 13,500-credit history in 12.0 s); 25 receipt jobs
  in 73.7 s; the camt.053 import job 29.5 s; the transfer cancellation file: set-up 42.2 s, generation with the holds
  3.14 s, its nightly checks 0.82 s; the 5,000-transfer file: generation 2.78 s (command), download 1.46 s, the debit job
  11.5 s, its nightly checks 0.38 s; the 50,000-item draft requeued: options 0.11 s, booking 0.18 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,320.8 s (20:31–20:53 UTC; round
2: 1,314.5 s). No Paris date change fell in it.
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 4.36 s** (3.50 s; round 1: 4.13 s). « Virements » with
  the 5,000 queued took 1.94 s and the file's first download 3.66 s, under the API's 8 s. At 2,000 payouts: 0.73 / 1.62
  / 1.44 s; at 200: 0.14 / 0.28 / 0.21 s.
- The fixture's 5,050 approval jobs took **547.1 s** (526.8 s), the 2,000 held chained runs' 202.6 s (217.1 s), the 200
  runs' 21.5 s (20.3 s).
- The 200 members' batch line: its funds pass 0.64 s; the 200 RMT debits' job 0.92 s.
- The 5,000-member batch line: its funds pass **25.6 s** (26.8 s under auto_explain; 27.6 s); the nightly checks
  **1.11 s** (1.24 s), `run_remittance_runs_checks` 225 ms own; 5,000 RMT debits imported in 1.4 s, the debit job
  **24.3 s** (chunks 10.6, 9.5 and 4.1 s; 24.1 s).
- The 2,000 held chained runs: the funds pass took 20.0 s (22.6 s) and the nightly checks **13.57 s** (15.26 s), or
  14.35 s once the days were imported.
- The round touches none of these paths (the payouts' clients have no event); their spread is the VM's.

Every budget held.

### M2c-7e-1: top-ups and the own-account file (2026-11-26, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What 7e-1 puts on the timed paths (ADR-0014 « M2c-7e-1 »):
- **The hourly job** (`servicer-top-ups`, minute 37): one `top_ups` message per servicer with an active dedicated
  account; each reads Σ 4679 by the servicer's 4679 accounts (`ledger_account` by its key, then their postings), its
  sweeps and top-ups in flight (`bank_transfer_servicer_flight_idx`), its open period and its billing settings, and
  writes at most one top-up per currency. Not on any scale path: the scale files run no cron.
- **The nightly** (`run_advance_checks`): `top_up_account_missing` (the need per active dedicated currency, the
  billing settings' own account) and `top_up_order_failed` (one row of `private.top_up_order_state` by its key):
  `run_advance_checks` 92 ms own in the 50,000-line run's nightly (7d-3: 80 ms).
- **The download** (`transfer_file_download`, every file): `set enable_seqscan = off`; the run update now per run by
  its key (the file's transfers by `bank_transfer_file_idx`); an own-account file's checks (none on a payout file).
- **The funds pass** (the debit job): a `TOP…` credit's top-up read with `private.top_up_in_own_file` when in_file (by
  key); the worker's loader one keyed call per pass for the in_file top-ups it holds.
- The generation of payout files, the prepare, the approval and the payouts' bookings: unchanged.

**Stale statistics** (`worker/tests/test_top_up_reads_integration.py`, the db job; not a scale file; bound 60 per
call), on 10,000 planted rows each of `bank_transfer` (in flight and booked), `transfer_file`, `transfer_file_item`,
`bank_transaction`, `ledger_entry`, `ledger_posting`, `private.servicer_shortfall_period`, keys' n_distinct pinned to
2, every plan generic. Rows read per call from the watched tables in the last run: the need 5 `bank_transfer`, 1
`ledger_posting`; the hourly step 5 / 2 and 1 period; `top_up_overview` 24 `bank_transfer`, 6 files, 8 items, 2
postings; `top_up_credit_options` 4–6 / 1 line; `servicer_shortfall_periods` 4 postings, 2 entries, 1 period;
`generate_top_up_file` 36–38 / 24 files; the download 14 `bank_transfer`, 5 files, 8 items. Found while building and
fixed (ADR): the download's keyed reads without the seqscan setting (11,089 / 32,018), the overview's per-file counts
(113 items), its account counts (5,059), the generation's update with its temporary table (5,420), the superseded
file's close (10,420; 60,564), the download's run update (296–406).

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **52 files, 3,178 tests, PASS** (560 s); the
types unchanged after `supabase gen types`; the non-scale integration suite **307 passed** (1,004 s); `make eval`:
mapping top-1 1.000 (167/167, threshold 0.980), reconciliation 0.9600 automatic, 0 wrong.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`:
**15 passed** in 1,520.9 s (00:49–01:15 UTC; 7d-3: 1,477.9 s). No Paris date change fell in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.32 s, prepared in **13.4 s** (load 4.46 s, price
  5.96 s, write 2.77 s; 7d-3 12.9 s); the approval job and documents 18.7 s (the statement's build 8.39 s, 7.17 s for the
  one drawn again); the nightly checks 5.1 s (the draft waiting 4.9 s); the cancellation 4.46 s; the re-run prepared and
  approved in **31.9 s**, its payout filed, downloaded, debited and booked in 1.0 s; the nightly checks with the run
  booked **5.3 s** (`run_advance_checks` 92 ms own, `run_remittance_runs_checks` 402 ms).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.49 s, booking
  **1.99 s** (499 bookings), no sequential scan of a per-member table; through the API 0.64 / 2.07 s, the allocation lock
  held 1.84 s; the saturating lots 2.29 / 2.31 s and 2.91 / 2.97 s; 501 and 5,000 members refused `lot_too_large` at
  once; the approval jobs **151.5 s** for 500 runs and 155.2 s for 501 (7d-3: 148.0 / 145.4 s); « Virements »,
  « Générer le fichier » and the first download at 501 payouts 0.17 / 0.43 / 0.38 s.
- The others: 50,000 files boarded in 94 s; 50,000 credits imported and matched in 33.0 s, allocated in 75.9 s; 1,000
  returns in 29.0 s, their nightly checks 4.0 s; the statement's 50,000 credits in 42.5 s (the 13,500-credit history in
  12.8 s; automatic 0.9685, 0 wrong); 5,000 receipts in 25 jobs 73.3 s (14.7 ms a receipt); the transfer cancellation
  file: set-up 43.1 s, generation with the holds 3.03 s, its nightly checks 0.81 s; the 5,000-transfer file: generation
  3.04 s (command), job 0.94 s, download 1.51 s (the download's run update now per run: none in a refunds' file), « 
  Virements » 0.16 s, the debit job 11.8 s, its nightly checks 0.50 s; the 50,000-item draft requeued: options 0.10 s,
  booking 0.22 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,243.9 s (01:15–01:36 UTC; 7d-3:
1,320.8 s). No Paris date change fell in it.
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 3.70 s** (7d-3: 4.36 s). « Virements » with the 5,000
  queued took 1.78 s and the file's first download **3.69 s** (its run update now per run by its key; 7d-3: 3.66 s),
  under the API's 8 s. At 2,000 payouts: 0.68 / 1.39 / 1.48 s; at 200: 0.12 / 0.26 / 0.31 s.
- The fixture's 5,050 approval jobs took 513.6 s (547.1 s), the 2,000 held chained runs' 191.9 s, the 200 runs' 21.8 s.
- The 200 members' batch line: its funds pass 0.58 s; the 200 RMT debits' job 0.88 s.
- The 5,000-member batch line: its funds pass **24.9 s** (26.9 s under auto_explain; 25.6 s); the nightly checks
  **1.13 s** (1.24 s warm); 5,000 RMT debits imported in 1.3 s, the debit job **22.8 s** (chunks 9.5, 9.1 and 4.1 s;
  24.3 s).
- The 2,000 held chained runs: the funds pass 18.4 s (20.0 s) and the nightly checks **12.33 s** (13.57 s).

The E2E (`./scripts/e2e.sh`, after a fresh reset): **69 passed** in 7.4 min (`top-ups.spec.ts`: 11.4 s desktop, 11.0 s mobile).

Every budget held.

### M2c-7e-1 review fixes, round 1 (2026-11-26, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What round 1 puts on the timed paths (ADR-0014 « M2c-7e-1 review fixes », round 1):
- **« Rattacher à TOP… »** (`top_up_credit_options`): the servicer's open top-ups by `bank_transfer_servicer_flight_idx`
  (CC-1; was every servicer's transfers of the credit's amount), each one's own account by its key; `book_top_up_credit`
  and the re-check: one account read by its key (MONEY-BANK-1).
- **The own-account file**: its first download and its generation read `private.top_up_credit_seen` per top-up of the
  file or of the account (by the `TOP…` id's key; MONEY-BANK-2); `transfer_file_failed` closes an own file through
  `private.top_up_file_close` (by the file's key; CC-2); none on a payout file.
- **The nightly** (`run_advance_checks`): `top_up_account_missing`'s age (the open period by
  `servicer_shortfall_period_open_uq`), `top_up_order_failed`'s stale rule (the servicer's active dedicated accounts by
  their key, its state row): `run_advance_checks` 86 ms own in the 50,000-line run's nightly (7e-1: 92 ms).
- **« Virements »** (`top_up_overview`): `surplus_minor` per currency, the same terms as `top_up_needed`.
- The payout files, their downloads, the prepare, the approval and the payouts' bookings: unchanged.

**Stale statistics** (`worker/tests/test_top_up_reads_integration.py`, the db job; bound 60 per call), the plant now
with a fifth of its 10,000 `bank_transfer` rows at the waiting credit's amount and `amount_minor`'s n_distinct pinned
to 2. Rows read per call from the watched tables: `top_up_credit_options` **5** `bank_transfer` and 1 line (`617b3af`'s
body: **2,005**); the refused first download 16 `bank_transfer`, 13 files, 6 items, 1 line; the new file's generation 43
/ 11 / 1; its first download 19 / 8 / 6 and again 37 / 15 / 12; `book_top_up_credit` 28 `bank_transfer`, 15 files, 11
items, 28 postings, 8 entries, 8 lines; the own file's failure (`transfer_file_failed`) **3** `bank_transfer`, 11 files
(the generic release: **25,024**); « Annuler » of the payout files on it 1 file; the overview 31 `bank_transfer`, 5
files, 8 items, 3 postings; the nightly 16 `bank_transfer`, 3 postings beyond 7d-3's body (none).

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **52 files, 3,185 tests, PASS** (569 s; `047a`
32); the types unchanged after `supabase gen types`; then, without a reset, the non-scale integration suite **307
passed** (958 s); `make eval`: mapping top-1 1.000 (167/167, threshold 0.980), reconciliation 0.9600 automatic, 0 wrong.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`:
**15 passed** in 1,497.5 s (03:43–04:08 UTC; 7e-1: 1,520.9 s). No Paris date change fell in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.21 s, prepared in **11.8 s** (load 3.79 s, price
  5.16 s, write 2.66 s; 7e-1 13.4 s); the approval job and documents 17.3 s; the nightly checks 4.5 s (the draft waiting
  4.1 s); the cancellation 4.19 s; the re-run prepared and approved in **29.3 s**, its payout filed, downloaded, debited
  and booked in 0.8 s; the nightly checks with the run booked **5.0 s** (`run_advance_checks` 86 ms own,
  `run_remittance_runs_checks` 440 ms).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.53 s, booking
  **1.81 s** (499 bookings), no sequential scan of a per-member table; through the API 0.57 / 2.04 s, the allocation lock
  held 1.79 s; the saturating lots 2.28 / 2.36 s and 2.36 / 2.25 s; 501 and 5,000 members refused `lot_too_large` at
  once; the approval jobs **204.3 s** for 500 runs and 157.0 s for 501 (7e-1: 151.5 / 155.2 s; the round touches no
  approval path: the first fixture of the file ran slower); « Virements », « Générer le fichier » and the first
  download at 501 payouts 0.17 / 0.40 / 0.40 s.
- The others: 50,000 files boarded in 92 s; 50,000 credits imported and matched in 31.2 s, allocated in 79.2 s; 1,000
  returns in 28.2 s, their nightly checks 3.9 s; the statement's 50,000 credits in 43.5 s (the 13,500-credit history in
  11.3 s; automatic 0.9685, 0 wrong); 5,000 receipts in 25 jobs 70.3 s (14.1 ms a receipt); the transfer cancellation
  file: set-up 41.1 s, generation with the holds 2.53 s, its nightly checks 0.73 s; the 5,000-transfer file: generation
  3.23 s (command), job 0.97 s, download 1.73 s, « Virements » 0.16 s, the debit job 10.9 s, its nightly checks 0.35 s;
  the 50,000-item draft requeued: options 0.08 s, booking 0.19 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,322.6 s (04:09–04:31 UTC; 7e-1:
1,243.9 s). No Paris date change fell in it.
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 4.12 s** (7e-1: 3.70 s). « Virements » with the 5,000
  queued took 1.83 s and the file's first download **4.40 s** (3.69 s), under the API's 8 s; the round changed no
  statement of a payout file's generation or download. At 2,000 payouts: 0.88 / 2.01 / 1.52 s; at 200: 0.11 / 0.20 /
  0.23 s.
- The fixture's 5,050 approval jobs took 542.7 s (513.6 s), the 2,000 held chained runs' 202.7 s, the 200 runs' 19.7 s.
- The 200 members' batch line: its funds pass 0.54 s; the 200 RMT debits' job 0.69 s.
- The 5,000-member batch line: its funds pass **27.3 s** (29.4 s under auto_explain; 24.9 s); the nightly checks
  **1.50 s** (1.23 s warm); 5,000 RMT debits imported in 1.8 s, the debit job **24.2 s** (chunks 10.7, 9.1 and 4.1 s;
  22.8 s).
- The 2,000 held chained runs: the funds pass 19.7 s (18.4 s) and the nightly checks **13.91 s** (12.33 s).
- The VM ran slower than in 7e-1's runs on paths the round does not touch (the approval jobs about 6 % slower, the
  batch line's funds pass, whose re-check gained one condition per top-up row — none in a payout's lines — 10 %).

The E2E (`./scripts/e2e.sh`, after a fresh reset): **69 passed** in 7.5 min (`top-ups.spec.ts`: 11.4 s desktop, 11.8 s
mobile).

Every budget held.

### M2c-7e-1 review fixes, round 2 (2026-11-26, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What round 2 puts on the timed paths (ADR-0014 « M2c-7e-1 review fixes », round 2):
- **The nightly** (`run_advance_checks`): `top_up_order_failed` gains one condition (an active dedicated account,
  already read by its key): the 50,000-line run's nightly checks 4.4 s with the draft waiting, 4.7 s with the run booked
  (round 1: 4.5 / 5.0 s).
- **A file's first download** (every file, payout files included): the runs to mark sent read through the file's items
  (`transfer_file_item` by its key, each transfer by its key) instead of `bank_transfer_file_idx`: the 5,000-payout
  file's first download 3.38 s (round 1: 4.40 s), the 5,000-transfer file's 0.68 s (1.73 s).
- **The own-account file and « Virements »' top-up section** (not timed by the volume runs): the generation's two reads
  and the overview's count keyed by the account and the status (`bank_transfer_to_file_idx`); a superseded, cancelled or
  failed own file closed through its items; the overview's needed line from Σ4679 and the in-flight sums read once per
  currency.
- The payout files' generation, the prepare, the approval and the payouts' bookings: unchanged.

**Stale statistics** (`worker/tests/test_top_up_reads_integration.py`, the db job; bound 60 per call, the overview's
`bank_transfer` 60 + its 50 listed), the plant now with 5,000 booked past top-ups of the servicer's own account. Rows
read per call from the watched tables: `generate_top_up_file` **37** `bank_transfer`, 22 files, 2 items, 1 line
(`6b53073`'s body: **10,033**), the kept one 43 / 14 / 1 line, the one to fail 33 / 13; the overview **74**
`bank_transfer` (50 of them its list), 6 files, 10 items, 2 postings (`6b53073`'s body: **5,075**); `cancel_top_up_file`
15 `bank_transfer`, 9 files, 8 items; the refused first download 16 / 11 / 10 items / 1 line; the new file's first
download 27 / 8 / 10 and again 45 / 15 / 16; the own file's failure 4 `bank_transfer`, 9 files, 1 item;
`book_top_up_credit` 28 `bank_transfer`, 20 files, 11 items, 28 postings, 8 entries, 8 lines; the nightly 16
`bank_transfer`, 3 postings beyond 7d-3's body (none). Before the file reads went through the items, four runs in about
a dozen on one stack read about 30,000 `bank_transfer` entries per file-keyed call (`bank_transfer_filed_amount_idx`,
the dead entries of earlier rolled-back plants included); eight runs in eight within the bound since.

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **52 files, 3,186 tests, PASS** (560 s; `047a`
33); the types unchanged after `supabase gen types`; then, without a reset, the non-scale integration suite **307
passed** (1,012 s).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`:
**15 passed** in 1,413.9 s (06:54–07:18 UTC; round 1: 1,497.5 s). No Paris date change fell in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.30 s, prepared in **12.4 s** (load 3.71 s, price
  6.15 s, write 2.37 s; round 1 11.8 s); the approval job and documents 16.0 s; the nightly checks 4.4 s (the draft
  waiting 3.9 s); the cancellation 3.59 s; the re-run prepared and approved in **28.3 s**, its payout filed, downloaded,
  debited and booked in 0.8 s; the nightly checks with the run booked **4.7 s**.
- `test_transfer_line_scale_integration.py`: the approval jobs 139.5 s for 500 runs and 153.1 s for 501 (round 1: 204.3
  / 157.0 s); « Virements », « Générer le fichier » and the first download at 501 payouts 0.18 / 0.48 / 0.41 s.
- The 5,000-transfer file: generation 2.67 s (command), job 0.88 s, download **0.68 s** (round 1: 1.73 s), « Virements »
  0.13 s, the debit job 11.1 s, its nightly checks 0.36 s; the transfer cancellation file: set-up 43.9 s, generation
  with the holds 3.06 s, its nightly checks 0.76 s; 1,000 returns imported and linked in 25.7 s, their nightly checks
  3.8 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,260.4 s (07:18–07:39 UTC; round
1: 1,322.6 s). No Paris date change fell in it.
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 4.20 s** (round 1: 4.12 s; the round changed no statement
  of a payout file's generation). « Virements » with the 5,000 queued took 2.00 s and the file's first download **3.38
  s** (4.40 s: the runs to mark sent read through the items), under the API's 8 s. At 2,000 payouts: 0.68 / 1.52 / 1.76
  s; at 200: 0.11 / 0.19 / 0.19 s.
- The fixture's 5,050 approval jobs took 511.9 s (542.7 s), the 200 runs' 20.2 s.
- The 200 members' batch line: its funds pass 0.59 s; the 200 RMT debits' job 0.73 s.
- The 5,000-member batch line: its funds pass **27.2 s** (27.3 s); the nightly checks **1.11 s** (1.50 s); the debit job
  **21.5 s** (24.2 s).
- The 2,000 held chained runs: the funds pass 20.1 s (19.7 s) and the nightly checks **13.33 s** (13.91 s).

The E2E (`./scripts/e2e.sh`, after a fresh reset): **69 passed** in 7.4 min (`top-ups.spec.ts`: 11.4 s desktop, 11.8 s
mobile).

Every budget held.

### M2c-7e-2: our references in CSV labels, held and reviewed (2026-11-26, same VM, the main stack alone, each run right after `supabase db reset` with CI's logging settings)

What 7e-2 puts on the timed paths (ADR-0014 « M2c-7e-2 »; the import's own: `docs/benchmarks/payments.md` « Our
references in CSV labels »):
- **The debit job's funds pass**: `private.bank_booking_candidates` (whole copy) fetches the kind `label_reference` in
  both branches (as read, or a held line released so) through the recreated `bank_transaction_own_idx`; the worker
  reviews such a line before any other rule. No other statement of the pass changed.
- **The nightly** (`run_advance_checks`, 7e-1's body and one insert): `label_reference_waiting` reads the servicer's
  such lines through the two new partial indexes (`bank_transaction_label_reference_idx`,
  `bank_duplicate_resolution_label_reference_idx`), then each line, its candidate's transfer and its run by their keys —
  none in the volume runs, which import no such line.
- **« Débits et retours »** (`debit_queue`, whole copy): its new column reads one transfer per listed line by key (the
  transfer its label cites, then the run) and « À classer »'s second branch gains the kind; the guards
  (`link_debit_guard`, the link trigger) one more condition on the line already read. (Review round 1, CC-1: the rest
  of the queue is the body 7e-2 found, which under stale statistics reads the servicer's lines through
  `bank_transaction_org_idx` and the review, link, release and resolution tables whole by hash joins — measured by the
  review at 260,196 index rows and 45,000 table rows in 120 ms on 65,000 lines, the old body alike; ADR-0014
  « M2c-7e-2 review fixes », Left open for 7f.)
- The payout files, the prepare, the approval, the payouts' bookings: unchanged.

**Stale statistics** (`worker/tests/test_label_reference_reads_integration.py`, the db job; bound 60 per call, or the
reads before this slice plus 60): with `bank_transfer`, `bank_transaction`, `bank_duplicate_resolution`,
`bank_debit_review` and the probe tables planted (10,000 rows each, keys' `n_distinct` 2, generic plans), every call
stayed within its bound in the db job's sequence (`supabase test db`, then the integration suite: 311 passed). The
mutants: the queue's transfer unkeyed read 44,192 `bank_transfer` rows (the body 7e-2 found: 0); the nightly's 20,044
(7e-1's body: 2). Set apart (unchanged since M2b-6): `apply_bank_bookings` replaces a pass's reviews by a hash join
over the whole review table (10,083 rows after the db job's tests), its temporary table never analysed (ADR Left open).

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **53 files, 3,210 tests, PASS** (641 s;
`047b` 24); the types unchanged after `supabase gen types` (the regenerated file committed); then, without a reset,
the non-scale integration suite **311 passed** (1,094.5 s).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`:
**15 passed** in 1,440.3 s (10:39–11:03 UTC; 7e-1 round 2: 1,413.9 s). No Paris date change fell in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.24 s, prepared in **11.8 s** (load 3.82 s, price
  5.34 s, write 2.44 s; 7e-1 round 2: 12.4 s); the approval job and documents 16.7 s; the nightly checks 4.5 s (the
  draft waiting 3.9 s); the cancellation 3.77 s; the re-run prepared and approved in **32.9 s**, its payout filed,
  downloaded, debited and booked in 1.0 s (its funds pass 0.4 s); the nightly checks with the run booked **4.8 s**.
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.48 s, booking
  **1.68 s** (499 bookings), no sequential scan of a per-member table; through the API 0.52 / 1.83 s, the allocation
  lock held 1.61 s; the saturating lots 2.29 / 2.23 s and 2.40 / 2.57 s; 501 and 5,000 members refused `lot_too_large`
  at once; the approval jobs **139.2 s** for 500 runs and 136.1 s for 501; « Virements », « Générer le fichier » and
  the first download at 501 payouts 0.17 / 0.40 / 0.38 s.
- The 5,000-transfer file: refunds asked in 16.7 s, generation 2.86 s (command), job 0.93 s, download **0.88 s**,
  « Virements » 0.14 s, the debit job 11.1 s, its nightly checks 0.36 s; the transfer cancellation file: set-up 42.8 s,
  generation with the holds 3.21 s, its nightly checks 0.81 s; the 50,000-item draft requeued: options 0.13 s, booking
  0.18 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,267.0 s (11:04–11:25 UTC; 7e-1
round 2: 1,260.4 s). No Paris date change fell in it.
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 3.73 s** (7e-1 round 2: 4.20 s). « Virements » with the
  5,000 queued took 1.80 s and the file's first download **3.73 s** (3.38 s), under the API's 8 s. At 2,000 payouts:
  0.93 / 1.72 / 1.62 s; at 200: 0.12 / 0.20 / 0.22 s.
- The fixture's 5,050 approval jobs took 531.8 s (511.9 s), the 200 runs' 19.6 s.
- The 200 members' batch line: its funds pass 0.50 s; the 200 RMT debits' job 0.65 s.
- The 5,000-member batch line: its funds pass **24.6 s** (27.2 s; 25.2 s under auto_explain); the nightly checks
  **1.15 s** (1.11 s); 5,000 RMT debits imported in 1.3 s, the debit job **22.6 s** (chunks 9.1, 8.8 and 4.5 s; 21.5 s).
- The 2,000 held chained runs: the funds pass 20.9 s (20.1 s) and the nightly checks **14.37 s** (13.33 s).

The E2E (`./scripts/e2e.sh`, after a fresh reset): **71 passed** in 7.6 min (`label-references.spec.ts`: 3.5 s desktop,
3.6 s mobile).

Every budget held.

### M2c-7e-2 review fixes, round 1 (2026-11-26, same VM, the main stack alone, each run right after `supabase db reset`)

What round 1 puts on the timed paths (ADR-0014 « M2c-7e-2 review fixes »; the import's own: `docs/benchmarks/payments.md`
« Review round 1 »): the import probes every candidate a CSV label cites (one keyed probe each); « Débits et retours »
and « Contrôles » only word what they read (no new read); the debit job, the payout files and the nightly unchanged.

**Stale statistics** (`worker/tests/test_label_reference_reads_integration.py`): its docstring and this file no longer
say the whole queue reads by key — the body 7e-2 found reads the servicer's lines and the review, link, release and
resolution tables whole under these statistics (Left open for 7f); the test now bounds absolutely what 7e-2 adds:
one `bank_transfer` row per listed line for the queue's new column (4 in « À classer », 1 in « Doublons possibles »)
and one per candidate for the import (5), the rest relatively as before.

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **53 files, 3,213 tests, PASS** (599 s;
`047b` 27); the types unchanged (`supabase gen types`: no diff); then, without a reset, the non-scale integration suite
**312 passed** (1,075 s). `make eval`: mapping 1.000 (167/167); reconciliation 0.9600 automatic, 0 wrong.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`:
**15 passed** in 1,496.3 s (13:03–13:28 UTC; 7e-2: 1,440.3 s). No Paris date change fell in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.40 s, prepared in **14.4 s** (load 4.27 s, price
  6.17 s, write 2.65 s; 7e-2: 11.8 s); the approval job and documents 19.0 s; the nightly checks 4.6 s (the draft
  waiting 4.5 s); the cancellation 3.94 s; the re-run prepared and approved in **32.4 s**, its payout filed,
  downloaded, debited and booked in 1.1 s (its funds pass 0.4 s); the nightly checks with the run booked **5.4 s**.
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.48 s, booking
  **2.00 s** (499 bookings), no sequential scan of a per-member table; through the API 0.52 / 2.03 s, the allocation
  lock held 1.81 s; the saturating lots 2.57 / 2.60 s and 2.76 / 2.75 s; 501 and 5,000 members refused
  `lot_too_large` at once; the approval jobs **158.6 s** for 500 runs and 149.9 s for 501; « Virements », « Générer le
  fichier » and the first download at 501 payouts 0.18 / 0.41 / 0.36 s.
- The 5,000-transfer file: refunds asked in 16.8 s, generation 2.73 s (command), job 0.87 s, download **0.71 s**,
  « Virements » 0.18 s, the debit job 12.4 s, its nightly checks 0.40 s; the transfer cancellation file: set-up 38.9 s,
  generation with the holds 3.17 s, its nightly checks 0.74 s; the 50,000-item draft requeued: options 0.07 s, booking
  0.17 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,252.6 s (13:28–13:49 UTC; 7e-2:
1,267.0 s). No Paris date change fell in it.
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 4.13 s** (7e-2: 3.73 s). « Virements » with the 5,000
  queued took 1.90 s and the file's first download **4.29 s** (3.73 s), under the API's 8 s. At 2,000 payouts:
  0.83 / 1.57 / 1.74 s; at 200: 0.11 / 0.22 / 0.21 s.
- The fixture's 5,050 approval jobs took 501.1 s (531.8 s), the 200 runs' 20.7 s.
- The 200 members' batch line: its funds pass 0.59 s; the 200 RMT debits' job 0.71 s.
- The 5,000-member batch line: its funds pass **26.3 s** (24.6 s; 26.5 s under auto_explain); the nightly checks
  **1.17 s** (1.15 s); 5,000 RMT debits imported in 1.3 s, the debit job **22.5 s** (chunks 9.5, 8.9 and 4.0 s; 22.6 s).
- The 2,000 held chained runs: the funds pass 19.1 s (20.9 s) and the nightly checks **13.06 s** (14.37 s).

The E2E (`./scripts/e2e.sh`, after a fresh reset): **71 passed** in 7.7 min (`label-references.spec.ts`: 3.4 s desktop,
3.7 s mobile).

Every budget held.

### M2c-7e-2 review fixes, round 2 (2026-11-26, same VM, the main stack alone, each run right after `supabase db reset`)

What round 2 puts on the timed paths (ADR-0014 « M2c-7e-2 review fixes », round 2; the import's own:
`docs/benchmarks/payments.md` « Review round 2 »): nothing in SQL — the CSV parser reads a NOTPROVIDED cell's `/REF` as
a candidate, not as the line's end-to-end id, and « À classer » words a top-up's credit from the status the queue
already returns. The debit job, the payout files and the nightly unchanged.

**Stale statistics**: no read is new or changed; `worker/tests/test_label_reference_reads_integration.py` passed
unchanged in the db job.

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **53 files, 3,214 tests, PASS** (594 s;
`047b` 28, `033` unchanged); the types unchanged (`supabase gen types`: no diff); then, without a reset, the non-scale
integration suite **313 passed** (1,075 s). `make eval`: mapping 1.000 (167/167); reconciliation 0.9600 automatic,
0 wrong.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`:
**15 passed** in 1,706.3 s (15:10–15:38 UTC; round 1: 1,496.3 s; every timed step below at or under round 1's but
a few, the fixtures' set-up not timed apart). No Paris date change fell in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.26 s, prepared in **10.7 s** (load 3.30 s, price
  5.03 s, write 2.19 s; round 1: 14.4 s); the approval job and documents 16.0 s; the nightly checks 4.2 s (the draft
  waiting 3.6 s); the cancellation 3.70 s; the re-run prepared and approved in **28.7 s**, its payout filed,
  downloaded, debited and booked in 0.9 s (its funds pass 0.3 s); the nightly checks with the run booked **5.0 s**.
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.49 s, booking
  **1.80 s** (499 bookings), no sequential scan of a per-member table; through the API 0.52 / 1.94 s, the allocation
  lock held 1.71 s; the saturating lots 2.17 / 2.12 s and 2.29 / 2.79 s; 501 and 5,000 members refused
  `lot_too_large` at once; the approval jobs **152.4 s** for 500 runs and 141.5 s for 501; « Virements », « Générer le
  fichier » and the first download at 501 payouts 0.28 / 0.47 / 0.43 s.
- The 5,000-transfer file: refunds asked in 16.2 s, generation 2.39 s (command), job 1.01 s, download **0.68 s**,
  « Virements » 0.13 s, the debit job 10.6 s, its nightly checks 0.35 s; the transfer cancellation file: set-up 39.5 s,
  generation with the holds 3.08 s, its nightly checks 0.75 s; the 50,000-item draft requeued: options 0.07 s, booking
  0.25 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,201.4 s (15:39–15:59 UTC;
round 1: 1,252.6 s). No Paris date change fell in it.
- **« Générer le fichier » for 5,000 payouts (+50 cancelled): 3.58 s** (round 1: 4.13 s). « Virements » with the 5,000
  queued took 1.70 s and the file's first download **3.55 s** (4.29 s), under the API's 8 s. At 2,000 payouts:
  0.73 / 1.52 / 1.56 s; at 200: 0.11 / 0.19 / 0.18 s.
- The fixture's 5,050 approval jobs took 485.1 s (501.1 s), the 200 runs' 19.8 s.
- The 200 members' batch line: its funds pass 0.51 s; the 200 RMT debits' job 0.69 s.
- The 5,000-member batch line: its funds pass **24.9 s** (26.3 s; 24.9 s under auto_explain); the nightly checks
  **1.10 s** (1.17 s); 5,000 RMT debits imported in 1.2 s, the debit job **21.8 s** (chunks 8.9, 8.8 and 3.9 s; 22.5 s).
- The 2,000 held chained runs: the funds pass 19.9 s (19.1 s) and the nightly checks **13.40 s** (13.06 s).

The E2E (`./scripts/e2e.sh`, after a fresh reset): **71 passed** in 7.4 min (`label-references.spec.ts`: 3.2 s desktop,
3.5 s mobile).

Every budget held.

### M2c-7e-2 review fixes, round 3 (2026-11-26, same VM, the main stack alone, each run right after `supabase db reset`)

What round 3 puts on the timed paths (ADR-0014 « M2c-7e-2 review fixes », round 3; the import's own:
`docs/benchmarks/payments.md` « Review round 3 »): the statement import keeps a booked run's payout over the label's
other candidates (each candidate read once, a payout's run by key); `private.link_debit_guard` returns
`label_reference_top_up_line` for a line citing our top-up (the row it already read); « Contrôles » and the refusal
word a `TOP` line's classes without a return. The debit job, the payout files and the nightly unchanged.

**Stale statistics**: `worker/tests/test_label_reference_reads_integration.py` plants and watches `remittance_run` and
bounds the import's runs absolutely (one per payout candidate); every other bound passed unchanged in the db job.

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **53 files, 3,216 tests, PASS** (555 s;
`047b` 30, `033` unchanged); the types unchanged (`supabase gen types`: no diff); then, without a reset, the non-scale
integration suite **314 passed** (1,076 s).

The scale job's two import files only (the import changed; nothing else they time did), after another fresh reset:
**2 passed** in 185.4 s (`docs/benchmarks/payments.md` « Review round 3 »). The scale job's seven other files and the
`scale-payouts` job's two time nothing this round changes: not run.

The E2E (`./scripts/e2e.sh`, after a fresh reset): **71 passed** in 7.3 min (`label-references.spec.ts`: 3.3 s desktop,
3.4 s mobile).

Every budget held.

### M2c-7e-3: our references in CSV labels, the three exits (2026-11-26, same VM, the main stack alone, each run right after `supabase db reset`, the volume jobs with CI's logging settings)

What 7e-3 puts on the timed paths (ADR-0014 « M2c-7e-3 »; the import is unchanged: nothing for
`docs/benchmarks/payments.md`):
- **The payouts' bookings** (the scale and scale-payouts jobs' funds passes and ops' « Comptabiliser… »):
  `private.bank_line_booking_guard` (whole copy) reads, per booking, one more value of the line already read
  (`label_cites`: only for a `label_reference` line, the booking's transfer by its key) and its counterparty IBAN;
  `private.transfer_line_class`, `_pre`, `_check` and `_options_of` gain the class L (a `label_reference` credit: none in
  the volume runs), and `_check`'s `advance_settled` reads the double payout's advance by its cause entry, then its
  settlements by the document (fenced).
- **The chain's events** (`remittance_chain_paid` and its readers, the nightly's booked branch): the third return
  branch, which reads the transfer's `payout_returned` bookings by `bank_line_booking_transfer_idx`, compares one more
  column of the line already read by key — measured equal to 7e-2's body under planted statistics.
- **The debit job's re-check** (`private.bank_booking_recheck`, whole copy): its `top_up` rule reads a line's candidate
  by key only for an ops booking on a `label_reference` line with no IBAN; its `_bb` build unchanged (`037`'s parity).
- `release_own_credit`, its two guards, `client_line_facts`, `book_client_payment_line` and `book_top_up_credit`: one
  command per line, never on a volume path.

**Stale statistics** (`worker/tests/test_label_reference_exit_reads_integration.py`, the db job; each call bounded by
the same call on the tables unplanted, plus 60): with 7e-2's tables planted (10,000 rows each, keys' `n_distinct` 2,
generic plans), every call stayed within its bound: `book_transfer_line` read 59 `bank_transfer` rows (56 unplanted),
`transfer_line_options` 17 (30), `book_top_up_credit` 14 `bank_transfer` and 15 `remittance_run` (13, 18),
`release_own_credit` 61 `payment` rows (61: the payment guard's own reads, as before 7e-3), every other call under 32
rows of any watched table; the nightly's booked branch read 6 `bank_transfer` and 44 `remittance_run` rows on this
slice's events body and on 7e-2's alike (a run of the file alone; in the db job's sequence the file passed in 20.8 s).
`test_advance_reads_integration.py`'s new test (a double payout's unplanned return under the planted statistics):
`client_advance` 9 rows for the options and 9 for the booking, `commission_settlement` none (bound 72). The mutants: the
pre's cited transfer unkeyed read 10,076 / 10,118 `bank_transfer` rows; `advance_settled` unfenced 10,022 / 10,020
`commission_settlement` rows (bound 72).

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **54 files, 3,236 tests, PASS** (598 s;
`047c` 20); the types unchanged after `supabase gen types` (the regenerated file committed); then, without a reset, the
non-scale integration suite **318 passed** (1,013.1 s; the exits' reads test 20.8 s).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`
with CI's logging settings: **15 passed** in 1,352.6 s (19:48–20:10 UTC; 7e-2 round 2: 1,706.3 s). No Paris date
change fell in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.11 s, prepared in **10.6 s** (load 3.44 s, price
  4.66 s, write 2.32 s; 7e-2 round 2: 10.7 s); the approval job and documents 15.3 s; the nightly checks 4.1 s (the
  draft waiting 3.5 s); the cancellation 3.61 s; the re-run prepared and approved in **28.0 s** (28.7 s), its payout
  filed, downloaded, debited and booked in 0.8 s (its funds pass 0.3 s); the nightly checks with the run booked
  **4.7 s** (5.0 s).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.50 s, booking
  **1.83 s** (499 bookings), no sequential scan of a per-member table; through the API 0.53 / 2.05 s, the allocation
  lock held 1.81 s; the saturating lots 2.19 / 2.32 s and 2.20 / 2.43 s; 501 and 5,000 members refused
  `lot_too_large`; the 50,000-item draft requeued: options 0.08 s, booking 0.17 s.
- The 5,000-transfer file: refunds asked in 15.9 s, generation 2.95 s (command), job 0.82 s; the transfer
  cancellation file: set-up 39.7 s, generation with the holds 2.94 s, its nightly checks 0.79 s.
- The payments volume: 50,000 credits imported and matched in 39.8 s; 5,000 receipts in 66.2 s (13.2 ms each); the
  50,000-line camt.053's import job 27.0 s (7.2 s again); the nightly checks over 50,000 payments 4.68 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,266.5 s (20:11–20:32 UTC;
7e-2 round 2: 1,201.4 s). No Paris date change fell in it.
- « Générer le fichier » for 5,000 payouts (+50 cancelled): **3.59 s** (3.58 s); « Virements » 1.71 s, the file's
  first download **3.63 s** (3.55 s), under the API's 8 s; at 2,000 payouts 0.76 / 1.51 / 1.44 s; at 200 0.11 / 0.21 /
  0.17 s.
- The 200 members' batch line: its funds pass 0.52 s. The 5,000-member batch line: its funds pass **23.2 s** (24.9 s;
  24.6 s under auto_explain); the nightly checks **1.09 s** (1.10 s); 5,000 RMT debits imported in 1.2 s, the debit job
  **21.1 s** (chunks 8.4, 8.5 and 4.0 s; 21.8 s).
- The 2,000 held chained runs: the funds pass 19.9 s (19.9 s) and the nightly checks **13.45 s** (13.40 s).

The E2E (`./scripts/e2e.sh`, after a fresh reset): **73 passed** in 8.0 min (`label-references.spec.ts`: 9.3 and 4.3 s
desktop, 9.1 and 4.1 s mobile).

Every budget held.


### M2c-7e-3 review fixes, round 1 (2026-11-26, same VM, the main stack alone, each run right after `supabase db reset`, the volume jobs with CI's logging settings)

What round 1 puts on the timed paths (ADR-0014 « M2c-7e-3 review fixes », round 1; the import unchanged: nothing for
`docs/benchmarks/payments.md`): `public.release_own_credit` gains `set enable_seqscan = off` (one command per line,
never on a volume path); the rest is the web (« Débits et retours »' texts and labels, the statement's page reading
each line's `bank_line_booking` kinds by its key, an embedded select of the page's 100 lines at most) and tests.

**Stale statistics** (`worker/tests/test_label_reference_exit_reads_integration.py`, the db job): the test now also
plants `client_payout_account` (10,000 rows, the servicer's and another's, two IBANs, `organization_id` and `iban`
`n_distinct` 2) and watches it. Before the fix `release_own_credit` read **10,002** of its rows in one sequential scan
(bound 62); after it none, and 10 `bank_transaction` rows (7 unplanted; 52 unplanted before the fix). Every other call
within its bound as in 7e-3 (`book_transfer_line` 35 `bank_transfer` rows planted, 56 unplanted; `transfer_line_options`
15 / 30; `book_top_up_credit` 14 / 13; the payout-account reads of `book_transfer_line`, `book_top_up_credit` and
`transfer_line_options` 7, 6 and 2 rows, as unplanted); the nightly's booked branch 6 `bank_transfer` rows on either
events body and 10 `remittance_run` rows (12 on 7e-2's).

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **54 files, 3,238 tests, PASS** (577 s; `047c`
22, `033` unchanged); the types unchanged (`supabase gen types`: no diff); then, without a reset, the non-scale
integration suite **318 passed** (1,022.9 s; the exits' reads test 22.2 s).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`
with CI's logging settings: **15 passed** in 1,296.8 s (22:24–22:46 UTC; 7e-3: 1,352.6 s). No Paris date change fell
in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.13 s, prepared in **10.1 s** (load 3.35 s, price
  4.47 s, write 2.04 s; 7e-3: 10.6 s); the approval job and documents 15.0 s; the nightly checks 4.1 s (the draft
  waiting 3.6 s); the cancellation 3.62 s; the re-run prepared and approved in **27.8 s** (28.0 s), its payout filed,
  downloaded, debited and booked in 0.8 s (its funds pass 0.3 s); the nightly checks with the run booked **4.7 s**
  (4.7 s).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.48 s, booking
  **1.70 s** (499 bookings), no sequential scan of a per-member table; through the API 0.48 / 1.90 s, the allocation
  lock held 1.67 s; the saturating lots 2.00 / 2.06 s and 2.16 / 2.15 s; 501 and 5,000 members refused
  `lot_too_large`; the 50,000-item draft requeued: options 0.10 s, booking 0.21 s.
- The 5,000-transfer file: refunds asked in 15.8 s, generation 2.40 s (command), job 0.80 s; the transfer
  cancellation file: set-up 37.9 s, generation with the holds 2.81 s, its nightly checks 0.68 s.
- The payments volume: 50,000 credits imported and matched in 39.0 s; 5,000 receipts in 63.2 s (12.6 ms each); the
  50,000-line camt.053's import job 26.2 s (7.1 s again); the nightly checks over 50,000 payments 4.71 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,183.8 s (22:46–23:06 UTC;
7e-3: 1,266.5 s). No Paris date change fell in it.
- « Générer le fichier » for 5,000 payouts (+50 cancelled): **3.55 s** (3.59 s); « Virements » 1.73 s, the file's
  first download **3.79 s** (3.63 s), under the API's 8 s; at 2,000 payouts 0.84 / 1.57 / 1.37 s; at 200 0.10 / 0.25 /
  0.18 s.
- The 200 members' batch line: its funds pass 0.52 s. The 5,000-member batch line: its funds pass **23.9 s** (23.2 s;
  24.4 s under auto_explain); the nightly checks **1.18 s** (1.09 s); 5,000 RMT debits imported in 1.1 s, the debit job
  **21.1 s** (chunks 8.4, 8.6 and 3.9 s; 21.1 s).
- The 2,000 held chained runs: the funds pass 19.3 s (19.9 s) and the nightly checks **13.38 s** (13.45 s).

The E2E (`./scripts/e2e.sh`, after a fresh reset): **73 passed** in 7.6 min (`label-references.spec.ts`: 9.0 and 4.2 s
desktop, 9.1 and 4.2 s mobile; `statements.spec.ts` 7.1 s desktop, 7.8 s mobile, now waiting for the debit job's fee
booking).

Every budget held.

### M2c-7e-3 review fixes, round 2 (2026-11-27, same VM, the main stack alone, each run right after `supabase db reset`, the volume jobs with CI's logging settings)

What round 2 puts on the timed paths (ADR-0014 « M2c-7e-3 review fixes », round 2; the import unchanged: nothing for
`docs/benchmarks/payments.md`): the returned payouts' accounts are set `returned` one by one by their key in
`private.transfer_line_post` (ops' « Comptabiliser… » and exit (a)) and `private.bank_booking_post_rows` (every
`private.post_bank_bookings` call: the debit job's funds pass, the fourth exit), in place of one update whose status
filter let the planner read `client_payout_account_current_uq` whole; with no payout returned among the parts the loop
does nothing. The web's « Libérer » text and two pgTAP fixtures' dates.

**Stale statistics** (`worker/tests/test_label_reference_exit_reads_integration.py`, the db job): the plant gains 300
current payout accounts of other servicers. Round 1's bodies on a fresh reset: `book_transfer_line` read **305**
`client_payout_account` rows (bound 63; 95 in CI's order without the new plant, 323 re-run), `book_top_up_credit`
**303**; round 2's: 2 and none. Every other call within its bound as in round 1.

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **54 files, 3,238 tests, PASS** (594 s; `033`
unchanged, `043` and `046c` green on a Friday with their fixtures' dates moved); the types unchanged (`supabase gen
types`: no diff); then, without a reset, the non-scale integration suite **318 passed** (1,182.5 s; the exits' reads
test 24.4 s). The same sequence before the read fix: 317 passed, the exits' reads test failed (95 rows).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`
with CI's logging settings: **15 passed** in 1,328.7 s (01:18–01:40 UTC; round 1: 1,296.8 s). No Paris date change fell
in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.16 s, prepared in **11.4 s** (load 3.43 s, price
  5.21 s, write 2.53 s; round 1: 10.1 s); the approval job and documents 15.8 s; the nightly checks 4.3 s (the draft
  waiting 3.7 s); the cancellation 3.64 s; the re-run prepared and approved in **30.3 s** (27.8 s), its payout filed,
  downloaded, debited and booked in 1.0 s (its funds pass 0.4 s); the nightly checks with the run booked **5.1 s**
  (4.7 s).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.50 s, booking
  **1.68 s** (499 bookings), no sequential scan of a per-member table; through the API 0.48 / 1.93 s, the allocation
  lock held 1.67 s; the saturating lots 2.04 / 2.15 s and 2.25 / 2.24 s; 501 and 5,000 members refused
  `lot_too_large`; the 50,000-item draft requeued: options 0.07 s, booking 0.16 s.
- The 5,000-transfer file: refunds asked in 15.6 s, generation 3.06 s (command), job 0.83 s; the transfer
  cancellation file: set-up 39.5 s, generation with the holds 2.90 s, its nightly checks 0.67 s.
- The payments volume: 50,000 credits imported and matched in 38.4 s; 5,000 receipts in 62.0 s (12.4 ms each); the
  50,000-line camt.053's import job 27.6 s; the nightly checks over 50,000 payments 3.6 s.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,251.7 s (01:41–02:02 UTC;
round 1: 1,183.8 s). No Paris date change fell in it.
- « Générer le fichier » for 5,000 payouts (+50 cancelled): **4.17 s** (3.55 s); « Virements » 1.71 s, the file's
  first download **4.24 s** (3.79 s), under the API's 8 s; at 2,000 payouts 0.82 / 1.55 / 1.72 s; at 200 0.17 / 0.21 /
  0.19 s.
- The 200 members' batch line: its funds pass 0.51 s. The 5,000-member batch line: its funds pass **25.9 s** (23.9 s;
  26.7 s under auto_explain), no `client_payout_account` row read; the nightly checks **1.14 s** (1.18 s); 5,000 RMT
  debits imported in 3.1 s, the debit job **22.4 s** (chunks 9.0, 9.2 and 4.0 s; 21.1 s).
- The 2,000 held chained runs: the funds pass 20.7 s (19.3 s) and the nightly checks **13.37 s** (13.38 s).
The job took 6 % longer than round 1's on the same VM (the scale job 2 % longer); the changed loop reads only the
working table here (no payout returned among these debits' parts), so the spread is most likely the VM's.

The E2E (`./scripts/e2e.sh`, after a fresh reset): **73 passed** in 7.7 min (`label-references.spec.ts` 9.0 and 4.4 s
mobile; `statements.spec.ts` 8.2 s mobile).

Every budget held.

### M2c-7f-1: hardening and every deferred code fix (2026-11-27, same VM, the main stack alone, each run right after `supabase db reset`, the volume jobs with CI's logging settings)

What 7f-1 puts on the timed paths (ADR-0014 « M2c-7f-1 »; plan `docs/design/m2c-7f-plan.md` §2): the nightly
(`private.run_payment_checks` with `enable_seqscan = off`, `servicer_shortfall` from `private.top_up_needed`,
`run_transfer_checks`' failed-file probe by the file's items, `inflight_overdue_lines` by the run's key, a
partial `(organization_id) where kind = 'invoice'` index on the invoices), six single-column partial indexes of `bank_transaction` (the
nightly's kind probes and the funds pass's candidates), « Débits et retours » (`public.debit_queue` keyed), the funds
pass's review replacement by key, the payout files' reads through their items (the release, « Marquer comme
déposé », the line's « remplace le fichier » check, the file's run locks, a late predecessor's file in the transfer
line's locks, the two-step's evidence and update, the re-issue guard; `bank_transfer_filed_amount_idx` kept, so rule
3b's probe is unchanged), the prepare's loader by key in SQL, the allocation's backstop re-reading the mandate's end, and
`request_top_up` under the remit lock. The CSV import's `/REF` count (H18) touches the import's parser only: the
payments volume below is the scale job's.

**Stale statistics** (`worker/tests/test_close_out_reads_integration.py`, the db job; each figure the earlier body's,
then 7f-1's): the nightly's refund requests 218,240 → 200 and transfers 2,500 / 2,200 → 219; the servicer's kinds
10,465 → within 198; the funds pass's candidates 12,547 → within 6 × 560 and its reviews 10,004 → within the reviews it
writes; « À classer » and « Frais » 2,097 and 2,138 → within 4 × candidates + 60; an in-flight run's overdue lines
120,144 → within 72; the prepare's loader 10,006 / 10,026 → keyed; the payout files (H7; the earlier bodies with 40
refunds, 7f-1's with 80): the release after a download 165,976 → 1,280 `bank_transfer` rows, « Marquer comme
déposé » 10,013 runs → none, the « remplace le fichier » check 37,745 → 80, the two-step 230,301 → 640 and 2,080, a
late predecessor's file 48,531 → 160.

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **55 files, 3,259 tests, PASS** (684 s;
`033`–`047c` unchanged; `048a` 21 tests); `supabase gen types` gives no diff against the committed file, which this
slice regenerated (`client_advance_totals`; `mandate_ended_on` in `match_queue_accounts` and `search_payment_files`);
then, without a reset, the non-scale integration suite **333 passed** (1,128.2 s; the close-out reads file's files test
42.9 s, its kinds test 23.8 s, its invoices test 17.8 s). The same sequence's two earlier runs passed 331 and 332 of
333 (7d-2's set-off-bar and 7e-1's top-up reads tests, then 7e-1's once more), each fixed at the root (ADR « Suites »).

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`
with CI's logging settings: **15 passed** in 1,219.1 s (12:58–13:18 UTC; 7e-3 round 2: 1,328.7 s). No Paris date change
fell in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 1.04 s, prepared in **12.8 s** (load 3.57 s, price
  5.18 s, write 1.76 s; 7e-3 round 2: 11.4 s, load 3.43 s; the loader's two reads now by key in SQL, H20); the
  approval job and documents 14.0 s (15.8 s); the nightly checks 4.0 s (the draft waiting 3.5 s); the cancellation 3.11 s
  (3.64 s); the re-run prepared and approved in **27.9 s** (30.3 s), its payout filed, downloaded, debited and booked in
  0.9 s (its funds pass 0.4 s); the nightly checks with the run booked **4.7 s** (5.1 s).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.45 s, booking
  **1.41 s** (499 bookings; 1.68 s), no sequential scan of a per-member table; through the API 0.44 / 1.63 s, the
  allocation lock held 1.40 s; the saturating lots 1.71 / 1.79 s and 1.84 / 1.87 s; 501 and 5,000 members refused
  `lot_too_large`; the 50,000-item draft requeued: options 0.10 s, booking 0.17 s.
- The 5,000-transfer file: refunds asked in 15.4 s, generation 2.62 s (command), job 0.71 s, download 0.59 s; the debit
  job booking the 5,000 debits 9.5 s; the nightly checks 0.35 s. The transfer cancellation file: set-up 37.3 s,
  generation with the holds 2.44 s (2.90 s), its nightly checks 0.63 s reading **55,768** `bank_transfer` rows
  (75,850 in 7a's CI round, 7c-2 and 7d-1, the last that quoted it: the nightly's transfer probes are keyed, H1), the
  late predecessor's options 0.04 s and booking **1.97 s** (1.80 s to 2.51 s in 7c-2 and 7d-1).
- The payments volume: 50,000 credits imported and matched in 38.4 s (ingest 7.8 s; automatic 0.9687, 48,433, 0 wrong),
  allocated (the allocation run's) in 62.6 s; 5,000 receipts in 62.5 s (12.5 ms each); the 50,000-line camt.053's
  import job 26.1 s; the nightly checks over 50,000 payments 4.68 s (`run_payment_checks` 2.75 s own; 7e-3: 4.68 s).

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 1,156.6 s (13:19–13:38 UTC;
7e-3 round 2: 1,251.7 s). No Paris date change fell in it.
- « Générer le fichier » for 5,000 payouts (+50 cancelled): **3.15 s** (4.17 s); « Virements » 1.34 s (1.71 s), the
  file's first download **3.09 s** (4.24 s), under the API's 8 s; at 2,000 payouts « Virements » 0.66 s, « Générer »
  1.31 s, the download 1.26 s; at 200, 0.11 / 0.14 / 0.14 s.
- The 200 members' batch line: its funds pass 0.44 s (0.51 s). The 5,000-member batch line: its funds pass **19.1 s**
  (25.9 s; 20.0 s under auto_explain), no `client_payout_account` row read and no sequential scan of a per-member
  table; the nightly checks **0.98 s** (1.14 s); 5,000 RMT debits imported in 1.2 s, the debit job **16.6 s** (chunks
  6.7, 6.6 and 3.1 s; 22.4 s).
- The 2,000 held chained runs: the confirmation 5.26 s, the funds pass 16.1 s (20.7 s) and the nightly checks
  **13.11 s** (13.37 s).
The job took 8 % less than 7e-3 round 2's on the same VM, its timed steps 8 % to 27 % less; 7f-1 changes the funds
pass's reads (H4's indexes, H6's review delete by key) and the payout files' (H7), and this run does not attribute the
gains further.

The E2E (`./scripts/e2e.sh`, after a fresh reset): **73 passed** in 7.4 min (the slowest: `payments-debits.spec.ts`
44.6 s desktop, `remittances.spec.ts` 41.3 s mobile). Eight screenshots kept, those whose text changed:
`m2-statement-imported` and `m2-statements` (H21), `m2c-controles` (H2), `m2c-virement-hors-reversement` (H23), mobile
and desktop; the others show only dates, ids or order and were reverted.

Every budget held.

### M2c-7f-1 review fixes, round 1 (2026-11-27, same VM, the main stack alone, each run right after `supabase db reset`, the volume jobs with CI's logging settings)

**Stale statistics** (`worker/tests/test_close_out_reads_integration.py` and 7e-1's top-up reads test, the db job;
each figure is the earlier body's, then this round's):
- The nightly's transfers (the kinds test's `bank_transfer` bound, 120 for the servicer's 5 transfers): 27,563 rows on
  `22bb2fb`; 365 with `run_transfer_checks`' two laterals fixed (`transfers_in_flight` per account); 49 default and 38
  generic in the aged state with it fixed. In the db job's order, before the client_funds checks became probes: 219
  default once, then 157, 278 and 179 generic. After them: 44 default and 38 generic.
- « Avances »: the client's page 20,000 `client_advance` rows (7b's body 40,000), now none (the fixture's client has
  none); the servicer's one-row page 7 (7b's body 40,007); 7c-2's repayment-request test's call 10,008 (exempt
  before), now 8.
- « Approvisionnements » (7e-1's test, the db job's order): the overview 2,707 `bank_transfer` rows and each
  « Générer le fichier (compte propre) » 5,307 / 5,317 / 5,309, against bounds of 110 and 60; after the fix, nothing
  over its bound.

The db job as `ci.yml` runs it, after a fresh reset: `supabase test db` **55 files, 3,263 tests, PASS** (564 s;
`033`–`047c` unchanged; `048a` 25 tests); `supabase gen types` gives no diff (no public signature changed); then,
without a reset, the non-scale integration suite **333 passed** (961.0 s; the close-out reads file's files test
37.9 s, its kinds test 22.6 s with its generic arm, its invoices test 14.4 s; 7e-1's top-up reads test 37.9 s). The
same sequence's two earlier runs failed, each fixed at the root before the next: the first `046c` tests 24 and 25
(MB-1's proposed comparison, reverted) and the kinds test's new bound (the client_funds checks); the second 7e-1's top-up
reads (the ordered top-ups). ADR « M2c-7f-1 review fixes », round 1.
Worker: `ruff check`, `ruff format --check` and `mypy --strict` (222 files) are clean, and the unit suite has
**1,300 passed** and 7 xfailed (137.5 s). `make eval`: mapping top-1 1.000 (167/167, threshold 0.980);
reconciliation 0.9600 automatic (95,997 of 100,000), 0 wrong, 0 policy violations.

The scale job's command as `ci.yml` runs it (its nine files; `RECEIPT_FILES=5000`), right after `supabase db reset`
with CI's logging settings: **15 passed** in 1,047.6 s (17:57–18:15 UTC; 7f-1: 1,219.1 s). No Paris date change fell
in it.
- `test_remittance_scale_integration.py` (50,000 lines): reserved in 0.94 s, prepared in **8.9 s** (load 2.67 s,
  price 4.23 s, write 1.80 s; 7f-1: 12.8 s); the approval job and documents 12.3 s (14.0 s); the nightly checks 3.3 s
  (the draft waiting 3.0 s); the cancellation 2.78 s (3.11 s); the re-run prepared and approved in **24.8 s**
  (27.9 s), its payout filed, downloaded, debited and booked in 0.6 s; the nightly checks with the run booked
  **3.7 s** (4.7 s).
- `test_transfer_line_scale_integration.py`: the 500-member lot short of one, rolled back: options 0.38 s, booking
  **1.55 s** (499 bookings; 1.41 s); through the API 0.36 / 1.59 s, the allocation lock held 1.43 s; the saturating
  lots 1.75 / 1.72 s and 1.74 / 1.78 s; 501 and 5,000 members refused `lot_too_large`; the 50,000-item draft
  requeued: options 0.07 s, booking 0.16 s.
- The 5,000-transfer file: refunds asked in 12.7 s, generation 2.13 s (command), job 0.66 s, download 0.88 s; the
  debit job booking the 5,000 debits 9.4 s; the nightly checks 0.29 s. The transfer cancellation file: set-up 36.3 s,
  generation with the holds 2.17 s, its nightly checks 0.59 s reading **55,748** `bank_transfer` rows (7f-1: 55,768),
  the late predecessor's options 0.03 s and booking **1.65 s** (1.97 s).
- The payments volume: 50,000 credits imported and matched in 23.2 s, allocated in 53.2 s (five chunks of 10,000,
  post 8.1 to 8.6 s each); the 50,000-line camt.053's import job 20.5 s (ingest 7.0 s); 5,000 receipts in 53.2 s
  (10.6 ms each); the nightly checks over 50,000 payments 3.74 s (`run_payment_checks` 1.94 s own; 7f-1: 4.68 s and
  2.75 s), reading 7 `bank_transfer` rows.

The `scale-payouts` job's command (`test_debit_bookings_scale_integration.py` then
`test_breach_held_scale_integration.py`), after another fresh reset: **6 passed** in 986.7 s (18:15–18:32 UTC; 7f-1:
1,156.6 s). No Paris date change fell in it.
- « Générer le fichier » for 5,000 payouts (+50 cancelled): **2.83 s** (3.15 s); « Virements » 1.33 s (1.34 s), the
  file's first download **2.86 s** (3.09 s), under the API's 8 s; at 2,000 payouts « Virements » 0.53 s, « Générer »
  1.13 s, the download 1.09 s; at 200, 0.10 / 0.14 / 0.15 s.
- The 200 members' batch line: its funds pass 0.40 s. The 5,000-member batch line: its funds pass **17.8 s** (19.1 s;
  18.8 s under auto_explain); the nightly checks **0.83 s** (0.98 s); 5,000 RMT debits imported in 1.0 s, the debit
  job **15.9 s** (chunks 6.5, 6.3 and 3.0 s; 16.6 s).
- The 2,000 held chained runs: the confirmation 5.40 s, the funds pass 16.2 s and the nightly checks **10.77 s**
  (13.11 s).
Both jobs took less time than 7f-1's on the same VM. This round changes the nightly's transfer reads (keyed) and the
own-account file's reads, and this run does not attribute the gains further; run-to-run variance on this VM is of the
same order.

The E2E (`./scripts/e2e.sh`, after a fresh reset): **73 passed** in 7.2 min (the slowest: `payments-debits.spec.ts`
44.8 s mobile and 43.7 s desktop, `remittances.spec.ts` 40.2 s mobile). No screenshot kept: each diff showed only
dates, ids, hashes or order.

Every budget held.

### M2c-7f-2, part 1: the property machine (2026-11-27, same VM, the main stack alone; a second stack ran another session's volume files during part of the runs)

`worker/tests/test_close_out_machine_integration.py` (plan `docs/design/m2c-7f-plan.md` M1–M6, V4, X1's machine half),
the db job's own step after the integration suite (`ci.yml`, `timeout-minutes: 8`: the 6-minute budget plus 25 %,
rounded up). Each figure is the whole file — the switch-off class, the switch-on class (each example in one transaction
rolled back), and `test_every_check_can_fail` (15 s) — at the PR's size, 2 classes × 8 examples × 20 steps:

| Seed | Wall time | × 1.5 |
|---|---|---|
| 7 | 190 s (the second stack's volume files running) | 285 s |
| 8 | 148 s | 222 s |
| 9 | 196 s for the two classes, + 15 s the plants' test | 317 s |
| 10 | 161 s for the two classes, + 15 s the plants' test | 264 s |

The budget holds: the slowest seed × 1.5 is 5.3 min ≤ 6 min (seed 8 again on the final commit: 164 s). The
`machine-long` job (workflow_dispatch only, 45 min) runs 25 × 40 per class: locally **999 s** (16.6 min) with seed
2540, the whole file, green. Its first run (same seed) failed twice, both the oracle's gaps, now closed: a run whose
takes equal the refunds it owes settles nothing (D = 0, `settlement.py`'s deferral) — the oracle now computes the
refunds owed from its own credit notes and defers as the plan does; and a returned payout blocks the client's account
only while it is still the account it was paid to (one replaced since stays active). What the examples reached at
25 × 40: a late predecessor's return re-queued in a later run (then recorded as « M5 », which it is not: review round 1,
MACH-3) 14 times, 038's f_partial form 15 + 11, a D = 0 run 4, a set-off withheld at the debit 9 + 19, LG003 refused
43 + 47, LG009 3 + 16; « 038's d_queue / d_twice shape » as the event then counted it (any queue in debit after a
cancelled file: not 038's shape, review round 1, MACH-5) once, at 8 × 20 (seed 8, switch on, on the commit before the
late cycle), not at 25 × 40.

The mutants (X1, the machine half): each applied to the live stack (an SQL body swapped, a trigger disabled) or to the
worker's code, both classes run at 8 × 20 (seed 7), then restored. 22 runs — the 17 of §8.5's mutants on paths the
machine walks (not the payee kind, the import's `label_reference` override, the chain events' label branch), H2 and
H11, and three variants (each cover off with LG009 off too; VAT pro rata off in the SQL twin as well) — 20 killed by
the machine. The two it cannot reach (the plan's VAT pro rata in a run's settlement; the requested flag read by the
prepare job) are killed by `test_settlement.py::test_a_take_in_part_moves_its_vat_pro_rata` (added) and
`test_repayment_requests_integration.py::test_a_requested_advance_is_never_also_taken_by_the_real_prepare`. Each check
of the machine is shown failing on a planted state by `test_every_check_can_fail` (32 checks).

### M2c-7f-2, part 2: the close-out volume file (2026-11-28, same VM, the main stack alone)

`worker/tests/test_close_out_scale_integration.py` (plan `docs/design/m2c-7-plan.md` §8.3, `docs/design/m2c-7f-plan.md`
V1–V4 and X1's volume half), its own job `scale-closeout` (pushes to `main` and manual dispatch only; the `scale`
step excludes it). The world: one servicer, one client, 50,000 files from the synthetic tape; ten collections of every
file, each remitted in a 50k-line run through the jobs, filed, downloaded, debited and booked (the history); the day:
1,000 full returns (2 %) of the first run's payments, covered at the reversal. Statistics: a reset, then the imports;
before the measured steps of rows 1, 2, 4 and 5 the eight tables 7a's reads use are forgotten and kept so *(review
round 1, VC-4: not before rows 6, 7 and V3, which run on the statistics the history left, nor row 8, on scale-payouts'
own plant of five tables — ledger_account not among them)*. Each run below on a fresh reset
with `scale-closeout`'s logging settings (auto_explain at 60 s, pg_stat_statements on every statement). Run 2 had row
6's fix (`client_payment_docs`, `client_open_advances`) but not row 8's; run 3 had both (migration
`20261203090000_close_out_fixes.sql`, ADR-0014 « M2c-7f-2 »).

| §8.3 row | Bound | Run 2 | Run 3 |
|---|---|---|---|
| 1. Covers at the reversal: the debit chunk / the cover statement | < 60 s / < 2 s | 3.7 s / 0.55 s (1 booked run), 3.7 s / 0.62 s (10) | 3.4 s / 0.56 s (1), 4.4 s / 0.65 s (10) |
| 1. Rows read per reversal: the cover's facts / its posting | ≤ 20 each | 2.2 / 20.0 (`ledger_account` 2,246 and 20,008 for 1,000) | 2.0 / 20.0 (2,000 and 20,026) |
| 2. The deferred LG009 check (1,000 calls) | < 0.5 s | 0.24 s / 0.26 s | 0.25 s / 0.26 s |
| 3. `cover_booked_run_reversals` (1,000 lines reversed in flight) | < 3 s | 0.56 s | 0.60 s |
| 4. Delta pass / its rows read in all, 1 vs 10 booked runs | < 0.5 s / within 10 % | 0.073 s, 0.068 s / 16,501 vs 16,011 (−3 %) | 0.078 s, 0.071 s / 16,009 vs 16,013 |
| 4. `p_full` / the whole nightly's increase over the body without 7a's checks | < 8 s / ≤ 2 s | 0.12 s, 0.55 s / +0.08 s (1.85 → 1.93 s), +0.70 s (12.90 → 13.60 s) | 0.12 s, 0.57 s / +0.00 s (2.17 → 2.17 s), −0.94 s (15.07 → 14.13 s) |
| 5. Claw-back prepare / approval (1,000 open advances, 200 overruns) | ≤ 11.66 s / ≤ 6.71 s | **14.90 s** / 5.46 s | **16.93 s** / 5.85 s |
| 5. Its settlement at the debit (1,000 rows) / « Avances » (servicer, client) | < 2 s / < 300 ms | 0.054 s / 108 ms, 114 ms | 0.055 s / 144 ms, 105 ms |
| 6. `record_client_payment` × 1,000 (median, p99, max) | each < 200 ms | 48, 83, 137 ms (run 1, before the fix: 185, 352, **529**) | 45, 76, 113 ms |
| 7. `top_ups` over 100 servicers: the job's own (wall) / a held lock | < 2 s / skipped | 1.20 s (3.25 s) / skipped, miss recorded | 1.11 s (2.92 s) / skipped, miss recorded |
| 8. The 5,000-payout funds pass | ≤ 26.4 s | **28.2 s** | **14.4 s** |

- Row 4's per-table comparison is one-sided (ADR « M2c-7f-2 », Deviations): in run 2 `ledger_account` 2,248 rows with
  one booked run against 2,002 with ten, `ledger_posting` 4,247 against 4,003 — the night with one run reading more; in
  run 3 the same on both nights (2,002 and 4,001 / 4,004).
- Row 5's prepare is the one bound still broken (ADR, Left open; review round 2: 8.38 s, within: « M2c-7f-2, review
  round 2 » below): the earlier charges of every file loaded whole (550,000
  `commission_invoice_charge` rows, 2.1 s for the query alone), the history's prepare and approval growing from
  13.0 s (run 1) to 19.4 s (run 9) of run 2's history.
- Row 7's wall time adds the queue consumer's connection per poll and per message (about 2 s for 100 messages).
- Row 8, run 2 (track_functions): `bank_booking_post_rows` 27.4 s, `ledger_post_set` 20.8 s in 4 calls (of which the
  pooled lookup 14.0 s: 4.4, 4.0, 3.8 and 1.8 s, pg_stat_statements), `post_run_settlements` 13.2 s,
  `run_booked_cover_check` 5,000 calls in 0.37 s, `cover_booked_run_reversals` 0.03 s. On the same world with the
  lookup fixed: 13.1 s. Run 3: 14.4 s (again with track_functions 14.6 s: `bank_booking_post_rows` 13.0 s,
  `ledger_post_set` 7.8 s in 4 calls, `post_run_settlements` 4.2 s, `run_booked_cover_check` 5,000 calls in 0.38 s,
  `cover_booked_run_reversals` 0.03 s). V2 (the run check made statement-level) is not built: it would save at most
  the 0.38 s.

V3, measured: the payout blockers' nested calls, 5,000 calls for the world's client: no event 0.23 s, a death recorded
**1.94 s** (run 3: 0.14 s and 2.11 s; budget 8 s; 7d-1: 2.2–2.4 s on a small world). `ledger_post_set`'s pooled lookup: row 8 above (fixed).
`bank_transfer_file_idx` and `test_transfer_files_scale_integration`'s headroom: the `scale` job's command below.

Time: run 2 **2,434 s (40.6 min)** — the world 1,212 s (its ten 50k-line runs 95–112 s each, collection included),
row 8's 5,000-payout fixture 867 s, the claw-back fixture 276 s, row 8's two passes 64 s, row 7 12 s. Run 3
**2,408 s (40.1 min)**: **1 failed** (row 5's prepare), 8 passed; the world 1,223 s, row 8's fixture 870 s, the
claw-back fixture 270 s, row 8's two passes 30 s, row 7 12 s. `scale-closeout`'s timeout: 60 minutes (the local
time with about 50 %). Beyond the ~28 minutes the plan aimed at (ADR « M2c-7f-2 », Left open; founder question): row 8
on `scale-payouts`' own 5,000-payout fixture would take about 15 minutes off this job.

The mutants (X1, the volume half; plan m2c-7f §3 X1, part 1 left them): each applied to the live stack on run 2's world
(a function's latest body with one change, then restored from the migrations and checked), the row measured again
(rows 1, 2 and 4 on a fresh day of returns in a rolled-back transaction; row 3 and 5 on a new collection's run; rows 7
and 8 as the file runs them):

| Mutant | Row | Verdict |
|---|---|---|
| (1) F9: the delta pass reads every booked run (`run_advance_checks`' window off) | 4 | killed: 0.79 s, `remittance_line` 559,335 rows, reads 21,025 → 611,160 |
| (2) the cover's facts unkeyed (`remitted_cover_held`: a reversal's covers by a scan) | 1, 2, 4 | killed: `client_advance` 3,120,000 rows, LG009 1.58 s, the delta pass 0.76 s |
| (3) the deferred LG009 check unkeyed per row (the reversed line by a scan) | 2 | killed: past the 120 s statement timeout |
| (4) `cover_booked_run_reversals` unkeyed (the client's every line, the run by a filter) | 3 | survives the row (0.63 s of its 3 s; `remittance_line` 208,432 → 767,169 rows); killed by the db job's `test_remitted_cover_reads_integration.py` |
| (5a) the claw-back's open advances unkeyed (`advance_open`: the reversal by a scan): prepare | 5 | the prepare 15.8 → 18.0 s; not a kill by the bound, which the baseline already breaks (Left open) |
| (5b) the same: the approval | 5 | survives (5.5 → 6.1 s of 6.71 s), and the db job's `test_advance_reads_integration.py` |
| (5c) the settlement's advance guard unkeyed (the advance's reversal by a scan) | 5 | survives (`post_run_settlements` 0.07 → 0.70 s of 2 s), and the db job's advance, client-payment and set-off reads tests |
| (6) a client payment's documents unkeyed (`advance_born_on`: the entry by a scan) | 6 | killed: 169 → 659 ms (on run 3's world) |
| (7) F8: the hourly job waits for a held servicer's lock (`order_due_top_up` without its lock timeout) | 7 | killed: the held servicer done, not missed |
| (7b) F8: the step without its savepoint (the lock timeout aborts the message's transaction) | 7 | killed: its miss not recorded |
| (8) F17: the per-row run check unkeyed (the run's lines by a scan) | 8 | killed: past the 120 s statement timeout |

The survivors are time bounds a 10× slower unkeyed read stays under at this volume (5b, 5c: no db-job reads test
bounds them either); (4) is held by the db job. Top-ups « in one transaction » has no product mutant short of the
queue itself (one message per servicer, `private.queue_top_ups`); (7b) is the closest: one transaction for the step and
its record.

The `scale` job's command as `ci.yml` runs it (its files but the three of their own jobs; `RECEIPT_FILES=5000`), right
after `supabase db reset` with CI's logging settings, with `20261203090000` applied (its `ledger_post_set` posts every
allocation): **15 passed** in 1,077.8 s (17.96 min; part 1's last: 1,047.6 s).
- The payments volume: 50,000 credits imported and matched in 23.8 s, allocated in 57.4 s (five chunks of 10,000, post
  8.5 to 9.4 s each; before: 53.2 s, 8.1 to 8.6 s — each receivable line's account now one probe of its key instead of
  one hash of the table); 5,000 receipts in 55.3 s (11.1 ms each); the nightly checks over 50,000 payments 3.2 s.
- `test_remittance_scale_integration.py` (50,000 lines): prepared in 9.1 s (load 2.67 s, price 3.88 s, write 1.71 s).
- V3, `test_transfer_files_scale_integration.py`: the nightly checks 0.33 s reading **5,000** `bank_transfer` rows,
  once the servicer's own (its bound 32,000; M2c-6b-3b part 3 read 25,083), `bank_transfer_file_idx`'s three
  once-per-check reads within them; the cancellation file's nightly checks 0.56 s reading 55,748 (as before).

The suites on the final body (`ledger_post_set`'s three lookups): `supabase test db` after a reset **3,263 passed**
(621 s); the db job's integration step in CI's order **all passed** (1,034 s), then the property machine (seed 8,
2 classes × 8 × 20) **passed** in 163 s; the worker's ruff, format, mypy and unit tests clean. The first version of the
lookup (the client added to the unique index's prefix) passed the same suites but for its own reads test in the db
job's state (82,454 rows: the plant's statistics priced `ledger_account_org_book_idx` the cheaper), which the final one
holds (1,604).

### M2c-7f-2, part 3: the long machine run and the final suites (2026-11-28, same VM, the main stack alone)

**The property machine at 200 examples per class** (founder question 1's default (a), once locally; ADR-0014
« M2c-7f-2 », « What the 200 × 60 run found»). One fresh reset, then 8 chunks of 25 examples per class, each chunk its
own seed (71301–71308) and its own Hypothesis database, one after the other, a hard cap of 3 h 30 in all (05:26:06 →
08:56:06 UTC). The main run ended at 07:54:33 (**8,907 s**); the three chunks that had failed were re-run on the final
code within the cap, the last ending at 08:31:09 (**11,103 s** in all, 3 h 05).

| Chunk (seed) | Switch off, 25 × 60 | Switch on, 25 × 40 |
|---|---|---|
| 1 (71301) | passed (both classes in 996 s; the switch-on class at 60 steps ran out of locks, below) | passed, 357 s |
| 2 (71302) | passed (both classes in 986 s; the same) | failed in 102 s (the plan's clauses, fixed) — re-run: passed, 413 s |
| 3 (71303) | failed in 169 s (the oracle's proceeding hold, fixed) — re-run: passed, 960 s | passed, 394 s |
| 4 (71304) | passed, 915 s | passed, 307 s |
| 5 (71305) | passed, 942 s | passed, 420 s |
| 6 (71306) | failed in 285 s (one hold reason per payout, the oracle fixed) — re-run: passed, 816 s | passed, 457 s |
| 7 (71307) | passed, 908 s | passed, 429 s |
| 8 (71308) | passed, 870 s | passed, 364 s |

So **200 × 60 switch off (12,000 steps) and 200 × 40 switch on (8,000 steps), every example green** — chunks 7 and 8
and the three re-runs on the final code, the earlier ones on the code before the fixes (each fix only changes the
state it was found on). A step costs about 0.6 s switch off (25 × 60 in 870–960 s) and 0.3–0.45 s switch on. What the
examples reached over the run (the `event` counts, both classes): « 038's `d_queue` / `d_twice` shape » as the event then
counted it (any queue in debit after a cancelled file: not 038's shape, review round 1, MACH-5) **33 times**, switch on;
a late predecessor's return re-queued in a later run (then recorded as « M5 », which it is not: review round 1, MACH-3)
68; 038's
f_partial form 130 + 124; a D = 0 run 17 + 6; a set-off withheld at the debit 133 + 129; LG003 refused 557 + 289;
LG009 refused 118 + 93; runs approved 1,794 + 1,485.

**The switch-on class at 60 steps.** Its first example (every step a collection, the all-zeros draw Hypothesis tries
first) ran out of Postgres's lock table at about step 51 in chunks 1 and 2 (« out of shared memory »,
`max_locks_per_transaction` 64 × 100 connections): the one transaction keeps the lock of every working table the
ledger's posting core creates and drops (sampled: 20,710 locks held by one switch-on transaction 22 s in, 11,921 on
relations already dropped, 46 advisory). It runs at 40 steps from chunk 1's re-run on (the `machine-long` job's size).

**The final suites** (the final code: `20261203090000` and the worker's plan fix; each group on a fresh reset):
- The db job in CI's order: `supabase test db` **3,263 passed** in 642 s (55 files; `033` unchanged); the generated
  types unchanged; the integration step exactly as `ci.yml` runs it **336 passed, 1 skipped** in 1,036 s; the machine
  step exactly as `ci.yml` runs it (2 × 8 × 20 and the plants' test, seed 12191405) **3 passed** in 190 s. The three
  steps take 1,868 s (31.1 min) locally, against the job's 45-minute timeout (part 2: 621 + 1,034 + 163 = 1,818 s).
- `make eval`: mapping top-1 1.000 (167/167, threshold 0.980); reconciliation 96.0 % automatic, 0 wrong.
- The worker on the final code: ruff, ruff format and mypy (226 files) clean; the unit tests **1,304 passed, 7
  xfailed** (2 min 21 s; 1,301 before the plan fix's three tests). The web: lint and typecheck clean, vitest **763
  passed** (38 files); no web file and no public signature changed (the generated types identical), so no E2E.
- The `scale` job's command exactly as `ci.yml` lists it (`RECEIPT_FILES=5000`), after a reset with CI's logging
  settings: **15 passed** in 1,097 s (18.3 min; part 2: 1,077.8 s): 50,000 credits imported and matched in 23.8 s,
  allocated in 56.7 s (post 8.6–9.1 s per 10,000), 5,000 receipts at 11.5 ms each, the 50k run prepared in 10.5 s
  (part 2: 9.1 s), the nightly checks over 50,000 payments 3.3 s.
- The `scale-payouts` command, after another reset with CI's logging settings: **6 passed** in 1,033 s (17.2 min):
  the 5,000-payout batch line's funds pass 12.7 s, the 5,000 RMT debits' job 11.1 s.
- The `scale-closeout` command, after a third reset with CI's logging settings: **8 passed, 1 failed** in 2,326 s
  (38.8 min; part 2's run 3: 2,408 s): the failure is row 5's prepare, **15.58 s** against 11.66 s (Left open since
  part 2: the earlier charges loaded whole); its approval 5.48 s (≤ 6.71 s), « Avances » 110 ms. Row 1: the debit
  chunk 3.7 s and the cover statement 0.61–0.64 s for 1,000 covers; row 4: the delta pass 0.073 s and 0.066 s with 1 and
  10 booked runs, the whole nightly 2.07 s (2.09 s without 7a's checks) and 13.46 s (13.15 s): +0.31 s at ten runs
  (≤ 2 s); row 6: median 46, p99 74, max 121 ms (< 200); row 7: the messages' own 1.15 s (wall 2.98 s); row 8: the
  5,000-member batch line's funds pass **13.5 s** (≤ 26.4 s); V3: the blockers with a death recorded 1.88 s for 5,000
  calls (budget 8 s). The world 1,184 s, row 8's fixture 831 s.
- Then `supabase db reset`, the stack left running.

### M2c-7f-2, review round 1 (2026-11-28, same VM, the main stack alone)

ADR-0014 « M2c-7f-2 review fixes ». What the round measured:
- **The pooled lookup and the entry check** (`test_close_out_fixes_reads_integration.py`, the lot of 100 entries over
  400 clients, statistics planted in three states, alone and beside 5,000 other clients' pooled and owner-claim
  accounts): **1,604** `ledger_account` rows read in all six states (bound 2,060); 7f-2's lookup read 81,004 and
  1,081,004 in « analysed while empty » (fresh reset), the earlier entry check 45,604 and 2,045,604 there (after the db
  job's first files).
- **The earlier charges** (the 10k-file world of the volume file, ten booked runs: 109,991 charges over 10,000 keys):
  the old statement and its build 0.9–1.0 s, the totals (`private.remittance_charge_totals`, 10,000 rows) and their
  build **0.18–0.20 s**; the engine on the claw-back run's facts (10,754 lines) 1.11 s whole, **0.93 s** summed, the
  same draft (the inputs hash apart). The reads test: 340 rows (whole) and 299 (summed) for 240 charges beside 10,000
  planted rows per table, planted or forgotten statistics.
- **The machine** (seed 7, 2 × 8 × 20 and the two fixed scenarios): **4 passed** in 191 s after a reset (the `machine` job's step); before it, the reviewer's mutants each killed in 2 × 8 × 20 runs (refunds never filed, an N = 0 run refused, H2), the release probe surviving (M5 not built).

The final suites on the round's code (each group on a fresh reset):
- `supabase test db` **3,263 passed** in 668 s; the types unchanged; the db job's integration step **342 passed, 1
  skipped** in 1,038 s: the db job's steps 1,734 s (28.9 min) locally, the machine now in its own job (191 s after a
  reset).
- `make eval` green (mapping 1.000, reconciliation 96.0 %, 0 wrong); the worker's lint, types and unit tests (1,307
  passed, 7 xfailed) green; the web's lint, typecheck and vitest (763) green, no web change, no E2E.
- `scale` **15 passed** in 1,093 s (part 3: 1,097 s): the 50k run prepared in 10.1 s (load 3.28, price 4.81, write
  1.86 s); allocated in 59.9 s, its posts 9.0–9.6 s per 10,000 (part 3: 8.6–9.1 s); receipts 11.2 ms each; the
  nightly over 50,000 payments 3.3 s.
- `scale-payouts` **6 passed** in 1,021 s (part 3: 1,033 s): the batch line's funds pass 12.7 s.
- `scale-closeout` **8 passed, 1 failed** in 2,446 s (part 3: 2,326 s): the history's ten prepares and approvals 14.4 →
  17.7 s (part 3: 13.8 → 20.0 s); **row 5's prepare 12.93 s** (part 3: 15.58 s; bound 11.66 s: ADR « M2c-7f-2 review
  fixes », Left open; round 2: 8.38 s, below), its approval 6.20 s, the totals' read over 549,935 charges 0.77 s; row 1 3.6 / 4.1 s and 0.57 /
  0.62 s; row 4 +0.78 s at ten runs; row 6 52 / 86 / 119 ms; row 7 1.58 s (wall 4.06 s); row 8 14.0 s; V3 2.20 s. The
  world 1,211 s, row 8's fixture 902 s, the claw-back fixture 284 s.
- Row 5 alone under cProfile on another fresh world (27 min): the claw-back prepare 17.4 s profiled (load 6.8 s), the
  first history run's 12.4 s (load 3.6 s), the tenth's 17.2 s (load 6.8 s): the 1,000 advances add little; what ten
  runs of history add is now per key (50,000 key states read and decoded, the charges' totals), the load's fourteen
  statements 2.4 s of database time.
- Then `supabase db reset`, the stack left running.

### M2c-7f-2, review round 2 (2026-11-28, same VM, the main stack alone)

ADR-0014 « M2c-7f-2 review fixes (round 2) ». What the round measured:
- **The machine's quiescence** (MACH-1): seeds 7 to 12 at 8 × 20, the whole file each (both classes, the plants'
  test, the fixed scenario): **4 passed** each, 167–211 s (seed 7 338 s, a volume build running beside it); seed 12
  failed before the fix. `machine-long`'s 25 × 40 at a random seed (240252426): **4 passed** in 1,013 s; it reached
  038's f_partial form 15 + 7, a late predecessor's return re-queued in a later run 7 (switch on), a D = 0 run 1, a
  set-off withheld at the debit 17 + 18, LG003 refused 45 + 46, LG009 26 + 10, runs approved 255 + 136.
- **Row 5's prepare** (VC-3), on the volume file's own world (50k files, ten booked 50k-line runs, the 1,000 open
  advances and the claw-back run's 53,748 items; 7a's tables' statistics forgotten as the file leaves them), each step
  timed three times in rolled-back transactions, in a process holding nothing else (the scale file's process holds the
  world too: 12.93 s there before the round):

| Code | load | price | write | total |
|---|---|---|---|---|
| before the round | 4.08–4.64 s | 4.76–5.32 s | 1.71–2.11 s | 10.72–11.39 s |
| the reads' conversions only (ids as text, array literals, no copy) | 3.05–3.27 s | 4.66–4.97 s | 1.76–2.14 s | 9.47–10.17 s |
| the collector paused only | 3.39–3.61 s | 2.82–2.97 s | 1.62–2.15 s | 7.85–8.58 s |
| the round (both) | 2.33–2.70 s | 2.58–3.12 s | 1.69–2.49 s | 7.06–8.24 s |

  Offline, the same run's facts (pickled in round 1) priced in 5.0–5.8 s with the collector on and 2.9–3.5 s with it
  off; with it off the peak memory moved from 356 to 363 MB, and no cyclic garbage was left to collect after it. The
  facts loaded by the old and the new code are equal field by field (31 fields, 53,748 items, 49,949 keys). A
  50,000-uuid array parameter: 0.10 s dumped as a list, 0.03 s as one literal; four uuid columns of 50,000 rows and
  their 250,000 `str()`: 0.22 s as uuids, 0.10 s as text.

The final suites on the round's code (each group on a fresh reset):
- `supabase test db` **3,263 passed** in 685 s; the types unchanged; the db job's integration step **343 passed, 1
  skipped** in 1,105 s: the db job's steps 1,820 s (30.3 min) locally; the `machine` job's step (after a reset, seed 7)
  **4 passed** in 217 s.
- `make eval` green (mapping 1.000, reconciliation 96.0 %, 0 wrong); the worker's lint, types and unit tests (1,312
  passed, 7 xfailed) green; the web's lint, typecheck and vitest (763) green, no web change, no E2E.
- `scale` **15 passed** in 1,173 s (round 1: 1,093 s): **the 50k run prepared in 6.1 s** (load 1.53, price 2.36,
  write 2.09 s; round 1: 10.1 s); allocated in 61.6 s, its posts 8.8–9.9 s per 10,000; receipts 13.0 ms each; the
  nightly over 50,000 payments 3.5 s.
- `scale-payouts` **6 passed** in 1,171 s (round 1: 1,021 s): the batch line's funds pass 13.6 s. Every phase ran about
  15 % slower than in round 1, the code this round did not touch included (the 5,050 approvals 427.8 → 490.5 s, the
  clients 38.3 → 43.1 s): the VM that hour; its 5,050 prepares 89.6 → 107.0 s.
- `scale-closeout` **9 passed** in 2,444 s (round 1: 8 passed, 1 failed, 2,446 s): **row 5's prepare 8.38 s** (bound
  11.66 s; round 1: 12.93 s), its approval 6.05 s; the history's ten prepares and approvals 10.7 → 12.6 s (round 1:
  14.4 → 17.7 s); row 1 4.1 / 3.7 s and 0.63 / 0.60 s; row 4's whole nightly 2.03 / 14.22 s (2.00 / 14.37 s without
  7a's checks); row 6 49 / 77 / 106 ms; row 7 1.63 s (wall 4.12 s); row 8 14.2 s; V3 1.93 s. The world 1,214 s, row
  8's fixture 898 s, the claw-back fixture 285 s.
- Then `supabase db reset`, the stack left running.
