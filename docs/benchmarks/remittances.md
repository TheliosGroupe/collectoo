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
