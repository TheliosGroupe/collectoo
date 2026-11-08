# Boarding benchmark (M1-22)

`make bench-boarding` generates a synthetic EU-template tape with 1,000,000 loans and runs the
worker's boarding pipeline on it in a separate process, measuring that process only.

Pipeline measured: read the CSV files (all columns as text), profile them, transform and validate
every row (EU-template fields, claim types, legal regimes, required fields, duplicates, amounts,
references between tables), then build the staging rows and JSON-encode them chunk by chunk as the
COPY into `private.boarding_staging` does. Database writes and the commit are not in this
benchmark; the 50k-loan CI test covers them end to end (below).

## Result (2026-11-08, cloud session VM: 4 vCPU, 16 GB RAM)

| Input | Rows |
|---|---|
| T1 counterparties | 1,069,955 |
| T2.1 borrower–loan links | 1,069,955 |
| T3 loans | 1,000,000 |

| Step | Time |
|---|---|
| Read + profile (3 files, 560 MB of CSV) | 21.9 s |
| Transform + validate | 17.4 s |
| Staging rows + JSON encoding (7.28 M rows) | 17.6 s |
| **Total** | **57.3 s** |
| **Peak memory (RSS)** | **2,865 MB** (target < 4 GB) |
| Blocking issues | 0 |

Generating the synthetic files takes about 4.5 minutes and is not counted.

### What changed to reach this

A first run peaked at 7.4 GB. Three changes brought it down:

1. Staging rows stay typed in memory and are JSON-encoded 100,000 rows at a time while being
   written (the JSON of all 7.28 M rows alone was 3.8 GB).
2. Duplicate rows are found by hashing each row (8 bytes) and comparing full rows only where
   hashes collide: exact, without copying every column into one structure.
3. Columns that need no change (already clean text) are shared instead of copied, and the
   EU-template staging rows are built from the typed columns without a copy.

The largest remaining peak is profiling the 330 MB T3 file.

## 50k-loan end-to-end run (M1-21)

`worker/tests/test_scale_integration.py` boards 50,000 loans (53,533 counterparties) through the
real stack: upload to Storage, queue, profile, mock mapping proposal, approval, transform and
validation, staging, commit into Layer 2 and Layer 1. It runs in the CI `db` job and must finish
in under 5 minutes. Local time: see the PR for the latest figure.

## Reproduce

```bash
make bench-boarding            # generate + measure
cd worker && uv run python -m collectoo_worker.bench --loans 1000000 --out ../tmp/bench --reuse
```
