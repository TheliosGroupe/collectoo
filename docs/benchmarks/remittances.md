# Remittances benchmarks (M2c)

Targets: design `docs/design/m2c-remittances.md` §19. Each slice adds its section; runs, approvals, documents and
transfer files come with M2c-2 … M2c-7.

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
