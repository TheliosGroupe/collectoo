"""Boarding benchmark (M1-22): `make bench-boarding` or

    uv run python -m collectoo_worker.bench --loans 1000000 --out ../tmp/bench

Generates a synthetic EU-template tape (T1 counterparties, T2.1 links, T3 loans) to CSV in
chunks, then runs the in-process pipeline on it in a child process (read, profile, transform +
validate, staging rows JSON-encoded as for COPY) and reports wall time and peak memory (RSS) of
that child only. `--reuse` skips generation when the files are already there.
The 36-month collection history (T5, 36 rows per loan) is excluded: it is boarded as aggregates.
"""

from __future__ import annotations

import argparse
import csv
import json
import resource
import subprocess
import sys
import time
from pathlib import Path

CHUNK = 50_000
TABLES = ("t1_counterparty", "t2_1_borrower_loan", "t3_loan")


def generate(loans: int, out: Path) -> dict[str, int]:
    from collectoo_worker.synth.eba import generate_eba  # noqa: PLC0415

    out.mkdir(parents=True, exist_ok=True)
    counts = dict.fromkeys(TABLES, 0)
    writers: dict[str, csv.DictWriter[str]] = {}
    handles = []
    try:
        for start in range(0, loans, CHUNK):
            tape = generate_eba(min(CHUNK, loans - start), seed=start + 1, id_offset=start)
            for table in TABLES:
                rows = tape[table]
                if table not in writers:
                    fh = (out / f"{table}.csv").open("w", newline="", encoding="utf-8")
                    handles.append(fh)
                    writers[table] = csv.DictWriter(fh, fieldnames=list(rows[0]))
                    writers[table].writeheader()
                writers[table].writerows(rows)
                counts[table] += len(rows)
    finally:
        for fh in handles:
            fh.close()
    return counts


def pipeline(out: Path) -> dict[str, float | int]:
    """Runs in the child process: what the worker does with the files of one batch."""
    from collectoo_worker.boarding.profile import profile_frame  # noqa: PLC0415
    from collectoo_worker.boarding.readers import scan_csv  # noqa: PLC0415
    from collectoo_worker.boarding.stage import stage_rows, staging_digest  # noqa: PLC0415
    from collectoo_worker.boarding.validate import FileResult, detect_eba_table, validate_batch  # noqa: PLC0415

    timings: dict[str, float | int] = {}
    t = time.monotonic()
    files, profiles = [], {}
    for table in TABLES:
        lf, _ = scan_csv(out / f"{table}.csv")
        profiles[table] = profile_frame(lf)
        df = lf.collect(engine="streaming")
        mapping = {c: (f"eba.{c}" if c.startswith("f") else None) for c in df.columns}
        files.append(FileResult(table, table, df, mapping, eba_table=detect_eba_table(mapping)))
    timings["read_profile_s"] = round(time.monotonic() - t, 1)
    t = time.monotonic()
    log = validate_batch(
        files,
        profiles,
        portfolio_default=None,
        conformance="servicing",
        art4_exempt=False,
        join_keys=[],
    )
    timings["transform_validate_s"] = round(time.monotonic() - t, 1)
    t = time.monotonic()
    staged = stage_rows(files, log)
    digest = staging_digest(staged)  # encodes every row to JSON, chunk by chunk, as COPY does
    timings["stage_encode_s"] = round(time.monotonic() - t, 1)
    timings["staged_rows"] = sum(d["rows"] for d in digest.values())
    timings["blocking"] = log.blocking
    timings["peak_rss_mb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
    return timings


def _count_rows(path: Path) -> int:
    with path.open("rb") as fh:
        return sum(1 for _ in fh) - 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="bench")
    parser.add_argument("--loans", type=int, default=1_000_000)
    parser.add_argument("--out", type=Path, default=Path("../tmp/bench"))
    parser.add_argument("--reuse", action="store_true", help="keep already generated files")
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.child:
        print(json.dumps(pipeline(args.out)))
        return 0
    t = time.monotonic()
    if args.reuse and all((args.out / f"{table}.csv").exists() for table in TABLES):
        counts = {table: _count_rows(args.out / f"{table}.csv") for table in TABLES}
    else:
        counts = generate(args.loans, args.out)
    gen_s = round(time.monotonic() - t, 1)
    t = time.monotonic()
    child = subprocess.run(  # noqa: S603 - our own module
        [sys.executable, "-m", "collectoo_worker.bench", "--child", "--out", str(args.out)],
        check=True,
        capture_output=True,
        text=True,
    )
    result = json.loads(child.stdout.strip().splitlines()[-1])
    result["pipeline_total_s"] = round(time.monotonic() - t, 1)
    print(
        json.dumps({"loans": args.loans, "rows": counts, "generate_s": gen_s, **result}, indent=1)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
