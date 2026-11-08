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
