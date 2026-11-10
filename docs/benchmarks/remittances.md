# Remittances benchmarks (M2c)

Targets: design `docs/design/m2c-remittances.md` §19. Each slice adds its section; documents and
transfer files come with M2c-5 … M2c-7.

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
