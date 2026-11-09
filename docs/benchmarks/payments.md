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
- Design estimate (§8.4): 10–20 s for 100k lines against 500k references.

