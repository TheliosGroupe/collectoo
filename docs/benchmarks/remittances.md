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
