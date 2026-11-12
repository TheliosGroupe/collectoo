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
| (a) A statement of the file's 5,000 debits, one line per RMT end-to-end id: the import | 5,000 lines | 1.1 s | | |
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
| after | **2,600** (13 a member) | **1,200** (6) | 0.57–0.64 s |

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
approval jobs 585.7 s) / « Générer le fichier » 3.19 s; (b) the batch line **31.8 s** (29.5–31.3 s before; its time
is the posting — `post_run_settlements` 14.5 s, `ledger_post_set` 6.7 s — not the batch rule); (a) the debit job
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
