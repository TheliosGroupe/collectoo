"""Eval suites (M1-09): golden datasets in `worker/evals/<suite>/*.yaml`, run in CI.

    uv run python -m collectoo_worker.ai.evals mapping

Prints a report and exits non-zero when accuracy drops below `evals/<suite>/threshold`.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import polars as pl
import yaml

from collectoo_worker.ai.gateway import Gateway
from collectoo_worker.ai.mock import MockProvider
from collectoo_worker.boarding.mapping import propose
from collectoo_worker.boarding.profile import profile_frame

EVALS = Path(__file__).resolve().parents[3] / "evals"


def run_mapping(suite_dir: Path) -> tuple[int, int, list[str]]:
    gateway = Gateway(MockProvider())
    correct = total = 0
    misses: list[str] = []
    for path in sorted(suite_dir.glob("*.yaml")):
        for case in yaml.safe_load(path.read_text())["cases"]:
            cols: list[dict[str, Any]] = case["columns"]
            width = max(len(c["samples"]) for c in cols)
            frame = pl.DataFrame(
                {
                    c["header"]: [str(s) for s in c["samples"]]
                    + [None] * (width - len(c["samples"]))
                    for c in cols
                },
                schema={c["header"]: pl.Utf8 for c in cols},
            )
            proposals = {
                p.source_column: p.target for p in propose(gateway, profile_frame(frame.lazy()))
            }
            for c in cols:
                total += 1
                got = proposals.get(c["header"])
                if got == c["expected"]:
                    correct += 1
                else:
                    where = f"{path.stem}/{case['name']}"
                    misses.append(f"{where}: {c['header']!r} -> {got} (expected {c['expected']})")
    return correct, total, misses


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="evals")
    parser.add_argument("suite", choices=["mapping"])
    args = parser.parse_args(argv)
    suite_dir = EVALS / args.suite
    correct, total, misses = run_mapping(suite_dir)
    accuracy = correct / total if total else 0.0
    threshold = float((suite_dir / "threshold").read_text().strip())
    print(
        f"{args.suite}: top-1 accuracy {accuracy:.3f} ({correct}/{total}),"
        f" threshold {threshold:.3f}"
    )
    for miss in misses:
        print(f"  miss: {miss}")
    if accuracy < threshold:
        print("FAILED: accuracy below threshold")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
