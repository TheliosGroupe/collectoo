# Payments benchmarks (M2b)

## Statement import (M2-07, M2b-2)

`worker/tests/test_statement_scale_integration.py` generates a synthetic camt.053 statement
(`synth camt053` mix: structured and typed RF references, invoice numbers, free text, batch bookings
split or not, returns, fees, our refunds, pending entries, identical twins) over 5 booking days,
uploads it through the commands as an ops manager and runs the payments job on it, then imports the
same lines again in another file. CI runs it at 50,000 lines; `STATEMENT_LINES=100000` for the
benchmark below.

The job is one transaction: download, check the SHA-256, parse (streaming lxml), COPY the lines into
`private.bank_import_stage`, then `private.ingest_statement`: set-based dedup against the account's
earlier lines, insert the lines, one `payment` per credit a debtor paid, **one `cash_in` entry per
booking day** through `private.ledger_post_set`, I11 and I9 checks. Every query after the load starts
from analysed temp tables or a unique index, so plans do not depend on the statistics of the tables
just loaded (the 100k run below was made right after `supabase db reset`).

### Result (2026-11-08, cloud session VM: 4 vCPU, 16 GB RAM, local Supabase stack)

| Statement | Lines | File | Job | of which download / parse / COPY / ingest | Payments | `cash_in` entries |
|---|---|---|---|---|---|---|
| 100k, fresh database | 100,000 | 70 MB | **17.0 s** | 0.3 / 5.8 / 0.3 / 10.4 s | 96,708 | 5 |
| the same lines again (other file) | 100,000 | 70 MB | **7.6 s** | 0.4 / 6.0 / 0.3 / 0.8 s | 0 | 0 |
| 50k (CI size, full integration suite) | 50,000 | 35 MB | **9.1 s** | 0.2 / 3.0 / 0.2 / 5.7 s | 48,368 | 5 |
| the same lines again (other file) | 50,000 | 35 MB | **4.1 s** | 0.3 / 2.9 / 0.2 / 0.6 s | 0 | 0 |

- After the M2b-2 review fixes (each line keeps its entry reference, indexed; new lines are probed
  for an entry already imported, one index lookup per line whatever the statistics say), right after
  `supabase db reset`: 100k job **17.6 s** (0.4 / 6.0 / 0.4 / 10.8 s), the same lines again **8.1 s**
  (ingest 1.0 s); 50k in the full integration suite 9.7 s (ingest 6.2 s), again 4.2 s. The entry
  lookup alone: 134 ms for 100k new lines, 1.8 ms for a 500-line day, against an unanalysed table
  of 1.1M lines (a hash join would read every line of the account, however old).
- Parsing alone: 5.6 s for 100k lines, **peak memory 111 MB** (elements freed as they are read).
- The upload commands (`create_statement_upload`, `submit_statement_import`) take milliseconds and
  run under the API's `statement_timeout = 8s` in the tests.
- Design estimate (§8.3): parse 5–10 s, ingest 5–10 s for 100k lines. Most of the ingest is the
  97k `payment` rows (row triggers: guard and change log) and the 100k `bank_transaction` rows with
  their indexes; the ledger work is 5 entries of 2 lines.

## Matching (M2-08, M2b-3)

`worker/tests/test_matching_scale_integration.py` boards 50,000 files from the synthetic EU loan tape
(the M1-21 path: upload, mapping, commit, confirmation with openings and RF references), imports a
statement of 13,500 earlier payments by RF (what teaches the IBAN memory), then a 50,000-credit
statement in the design §13 mix (`synth.reconciliation`: structured RF, RF in the text, bare
bodies, invoice or loan numbers backed by the payer's name or the exact balance, repeat IBANs, 4 %
unmatchable). The import queues the `payments.match` job; the test scores the database's decisions
against the truth. `MATCH_FILES` / `MATCH_CREDITS` change the sizes.

The job is one transaction: lock the waiting payments; read their signals in Python; load only what
they point to (RF references by unique index; invoice and file numbers through an analysed temp
table joined on the `private.ref_key` expression indexes; IBAN memory; then those files' items,
balances, parties and pending payments, again from an analysed temp table); rules R1–R4; for the
payments left, files whose balance equals the amount (one aggregate of the servicer's receivables)
and a word index of the servicer's party names; R5–R6; COPY the decisions and apply them set-based
(gating, payment rows, `payment_match`, IBAN memory, candidates).

### Result (2026-11-09, cloud session VM: 4 vCPU, 16 GB RAM, local Supabase stack)

| Run | Payments × files | Automatic | Wrong | Queue | Match job | load / rules / remainder load / apply |
|---|---|---|---|---|---|---|
| first version | 50,000 × 50,000 | 48,219 (96.4 %) | 0 | 1,781 | 29.4 s | 4.8 / 0.7 / 1.9 / 21.3 s |
| IBAN shape check in SQL, name word index | 50,000 × 50,000 | 48,245 (96.5 %) | **0** | 1,755 | **18.8 s** | 5.0 / 0.9 / 1.7 / 11.2 s |
| 5,000 × 5,000 | 5,000 × 5,000 | 4,813 (96.3 %) | 0 | 187 | 3.0 s | 0.7 / 0.1 / 0.1 / 2.2 s |
| before the review fixes (re-run, fresh stack) | 50,000 × 50,000 | 48,257 (96.5 %) | 0 | 1,743 | 17.6 s | 4.5 / 1.1 / 2.0 / 10.0 s |
| review fixes: file locks, keyed gating, chunks of 50k | 50,000 × 50,000 | 48,238 (96.5 %) | **0** | 1,762 | **18.9 s** | 4.7 / 1.1 / 2.0 / 11.1 s |

- 50,000 credits imported and matched end to end: 52.4 s (import job ≈ 17 s as above, then the match
  job); the 13,500 earlier credits: 8.0 s. The 50k boarding before it: 73 s.
- **Apply** is mostly the 48k `payment` updates (row triggers: guard, touch, change log: 5.8 s) and
  48k `payment_match` inserts with their foreign keys (1.7 s); gating 0.8 s. A mod-97 IBAN check per
  row in SQL cost 7.7 s: the memory now checks the IBAN's shape, the worker its digits.
- **Name search:** a GIN trigram search per payer cost 7 ms (index forced) to 110 ms (the planner
  chose a sequential scan): minutes for thousands of payers. The job builds a word index of the
  servicer's party names instead (1.7 s with the balance aggregate). The GIN index serves the ops
  search (`search_payment_files`: 14 ms by reference, 44 ms by name at 50k files).
- **Queue reads** at 63,500 payments, as an ops manager with RLS and `statement_timeout = 8s`:
  `payment_queue` 120–140 ms per page (tab « à traiter », « rapprochés » over 61k rows, a filtered
  last page), `statement_match_counts` 91 ms for two statements of 50k and 13.5k payments.
- **Eval in Python** (`make eval`, CI `py` job): 100,000 credits × 50,000 files: world 8 s,
  matching 16 s, **95.5 % automatic, 0 wrong, 4.5 % queued**, every queued credit with its expected
  reason. Through the database (integration test, 600 files, 1,500 credits): 95.5–95.6 %, 0 wrong.
  After the review fixes (ADR-0013, M2b-3 review fixes; hard cases added to the statement): world
  7 s, matching 11 s, **96.0 % automatic, 0 wrong, 0 policy violations, 4.0 % queued**; the
  database runs above were not repeated.
- Design estimate (§8.4): 10–20 s for 100k lines against 500k references.

### Review fixes (2026-11-09)

- **Gating locks the run's files** (`FOR KEY SHARE`, in id order) so that a hold placed or lifted, or a batch
  rolled back, during the run is never missed: +0.1–0.3 s at 31k files (the payment updates' foreign keys
  took the same locks later anyway).
- **Keyed gating.** A first version built the gating table in one statement of left joins over aggregates.
  After the other integration tests (statistics of `payment` taken while the new payments were all
  unmatched), the planner estimated « payments already matched to these files » at one row and rescanned
  that aggregate for each of 31k files: apply 41.7–44.0 s instead of 9.9 s (same sequence before the
  fixes). The run's files are now a keyed, analysed table filled by one aggregate per fact, every join on
  an indexed key: apply 10.9–11.1 s in that sequence and alone.
- **`NOT IN (subquery)` → `NOT EXISTS`:** 250k rows × 4k outer rows (default `work_mem`): `NOT IN`
  (plain subplan, the hash limit passed) 40.0 s; `NOT EXISTS` (hash anti-join, with or without
  statistics) 25 ms.
- **Chunks:** one job takes at most 50,000 payments (`MATCH_CHUNK`) and queues the rest; at exactly 50k
  a second job finds nothing (a few ms).
- **Queue reads** at 63,500 payments (1,757 to process, 61,743 ready), ops manager, RLS: « à traiter »
  first page 5–10 ms (was 94–116 ms: the whole payment history was filtered), by reason 5 ms (was 92 ms),
  last page 6 ms, by client 230 ms (RLS on `account` for each candidate file read, see « Next »);
  « rapprochés » 68–82 ms (was 112 ms), last page 157 ms. pgTAP 012 pins it: a page reads ~30 buffers
  with 5,000 older payments and no fresh statistics (343 before).
- Unrelated, seen while measuring: `private.ingest_statement` of a 50k statement takes 28 s after the
  other integration tests and ~105 s once four 50k worlds are loaded (8 s on a fresh stack), with or
  without the queue's new indexes: to profile before production volumes (M2b-2).

## Allocation (M2-09, M2b-4)

`worker/tests/test_allocation_scale_integration.py` boards 50,000 files from the synthetic EU loan tape (as the
matching benchmark: consumer and professional loans with principal, accrued interest, other balances and a balancing
line), imports a 50,000-credit statement paying each file by its structured RF reference (partial 10–60 %, the exact
balance, more than the balance, half), matches it, then runs the `payments.allocate` jobs: 10,000 payments per job and
transaction, the continuation queued. It checks set-based that Σ received = Σ allocated + Σ unallocated, that no
receivable an allocation credited is below zero, that client money is closed (Σ5120 + Σ4710 + Σ4670 = 0), that every
allocation entry has its client notification, and that no consumer loan's unclassified amount was paid. `ALLOC_FILES`
changes the size.

Each job: the allocation lock; the ready payments in processing order, their files locked `FOR KEY SHARE`, the
payments `FOR UPDATE SKIP LOCKED`; the files' receivables as per-date balance profiles (one aggregate over an analysed
temp table of the files); the plans in Python; COPY; `private.post_allocations` (set-based checks, one entry per
payment and file through `ledger_post_set`, plan headers, notifications, payment states).

### Result (2026-11-09, cloud session VM: 4 vCPU, 16 GB RAM, local Supabase stack)

| Run | Payments | Entries | Jobs | Per job: load / plan / post | Total |
|---|---|---|---|---|---|
| first version | 50,000 | 50,000 | 5 × 10k | 1.1 / 0.3 / 8.9 s | **51.9 s** |
| notifications without foreign keys, positions by index (full integration suite, after the other 50k runs) | 50,000 | 50,000 | 5 × 10k | 1.1–1.3 / 0.3–0.4 / 8.2–9.0 s | **50.4 s** |
| before the review fixes, fresh database (same session as the next row) | 50,000 | 50,000 | 5 × 10k | 1.1–1.4 / 0.3–0.4 / 8.8–9.3 s | **53.3 s** |
| review fixes (item-level backstop: one keyed lateral lookup per payment and item; releases as a set), fresh database | 50,000 | 50,000 | 5 × 10k | 1.1–1.3 / 0.3–0.4 / 8.2–9.0 s | **50.8 s** |
| review fixes, full integration suite (after the other 50k runs) | 50,000 | 50,000 | 5 × 10k | — | **50.2 s** |
- **Review fixes:** the item-level backstop of `post_allocations` (no item below what it owes as a whole) costs no
  measurable time (within run-to-run noise). The file page's payment list (`account_detail`) was a sequential scan of
  every payment (an OR over an IN subquery): 36.6 ms at 50,013 payments, 23.6 ms with a parallel scan at 164,400; two
  index lookups now: 0.5 ms and 0.1 ms. Observation, same code: on a fresh database where the ten small allocation integration tests ran first,
  the 50k import + match took 252 s instead of 23 s (stale statistics of tables analysed while tiny; see PROGRESS
  « Next », ingest at volume).
- **Where the time goes** (one 10k job, 7,674 entries, `pg_stat_statements` with nested statements, first version):
  `ledger_post_set` 4.8 s — of which the deferred per-entry checks at commit 2.35 s (**0.31 ms per entry**: design risk
  R1 estimated 0.2–0.4 ms; checks I2–I6 by key lookups), the entry insert with its foreign keys and guard 1.1 s, the
  request checks of `_lps_e` 0.5 s; the 10k payment updates 1.4 s (row triggers: guard, change log); the client
  notifications 0.5 s (five foreign-key checks per row); plan headers 0.2 s; the 1343-1 re-check below 0.1 s.
- **Fixes:** `client_notification` without foreign keys (a set-based guard with key lookups checks the same references,
  as `ledger_posting`): notifications 0.5 → 0.1 s per 10k; payment positions read by one index lookup per payment
  (lateral) instead of a join whose plan depended on the statistics of entries posted a moment ago.
- **R1 verdict:** the per-entry checks are within the design's estimate (~11 s per 50k) and run in the background job,
  10k at a time (the allocation lock is held ~10 s per chunk; ops commands wait at most 2 s, then « réessayez »). The
  whole posting path is above the design's 20–30 s for 50k; the statement-level fallback is not needed yet (open
  question in PROGRESS).
- Design estimate (§8.5): ~50k entries and ~350k postings in 20–30 s.


## Receipts (M2-10, M2b-5)

`worker/tests/test_receipts_scale_integration.py` boards `RECEIPT_FILES` files from the synthetic EU loan tape (as the
M2-09 run), pays each by its RF reference (partial, exact and over amounts), imports, matches and allocates them with
the receipt jobs left aside (as before receipts existed), then runs the migration's backfill
(`private.queue_receipt_backfill`: one job per 200 payments) and the `payments.receipts` jobs. It checks set-based that
every payment on a file has exactly one receipt number with one version (v1), totals adding up to the payment, a PDF
hash per version. CI runs it at 5,000 files (`RECEIPT_FILES=5000` in the `scale` job); 50,000 is the benchmark.

A job is one transaction under the servicer's receipts lock: `receipt_prepare` (payloads built in SQL from the ledger,
the versions due, numbers drawn), rendering one PDF at a time (reportlab, invariant, uncompressed, DejaVu Sans
subsets) while up to 8 uploads to Storage run alongside on a kept-alive HTTP client, then `receipt_issue` (documents
and receipts).

### Result (2026-11-09, cloud session VM: 4 vCPU, 16 GB RAM, local Supabase stack)

| Run | Receipts | Jobs | Per job: prepare / render + store / record | Total | Per receipt |
|---|---|---|---|---|---|
| uploads one after the other (2,000 files) | 2,000 | 10 × 200 | 0.14 / 4.3 / 0.03 s | 44.1 s | 22.0 ms |
| 8 uploads alongside the rendering (2,000 files) | 2,000 | 10 × 200 | 0.15 / 1.9–2.0 / 0.03 s | 22.5 s | 11.3 ms |
| **50,000 files** (boarded, imported, matched, allocated in 153 s) | 50,000 | 250 × 200 | 0.16–0.18 / 1.8–2.1 / 0.04 s | **578.4 s** | **11.6 ms** |

- **Where the time goes:** rendering, ~9 ms a receipt on one core (two font subsets of ~36 KB each are built per PDF);
  the SQL is ~1 ms a receipt (prepare and record), the uploads overlap the rendering. A PDF is ~87 KB (uncompressed,
  for bytes that do not depend on the zlib build): ~4.3 GB per 50,000 receipts.
- **Design risk R8** estimated 20–40 min for 50k receipts: ~10 min, in background jobs that never hold the allocation
  lock. Receipts of one servicer are issued one job at a time (one number counter); several servicers run in
  parallel. Faster later if needed: render in a process pool (4 cores), or lighter font subsets.
- **Allocation unchanged by the receipt triggers** (M2b-5, fresh database): the 50k allocation run posts 8.2–9.2 s per
  10k job as before (the statement-level triggers on `ledger_entry` and `payment` add one `pgmq.send` per 200
  payments); the test's total, 56.9 s, also counts taking the 250 receipt jobs off the queue unrun.
