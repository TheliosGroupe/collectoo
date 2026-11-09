"""Reconciliation eval (M2-08 acceptance: « Synthetic statement: ≥ 95 % auto-matched; others in the
exception queue », with zero wrong automatic matches). Run in CI and by `make eval`:

    uv run python -m collectoo_worker.payments.reconciliation_eval [--credits 100000]

A synthetic world of files (`synth.reconciliation`) and a statement of credits with their ground
truth go through the matching rules (`payments.matching`, the code the `payments.match` job runs).
Prints the report; exits non-zero when the auto-match rate is below
`evals/reconciliation/threshold`, when any automatic match is wrong, when a credit expected in
the queue is matched automatically even to the right file (founder #3: a policy violation), or
when it is in the queue for another reason. The integration tests assert the same through the
database.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import date, timedelta
from pathlib import Path

from collectoo_worker.payments.matching import match_all
from collectoo_worker.synth.reconciliation import (
    Score,
    generate_credits,
    synthetic_world,
)

EVALS = Path(__file__).resolve().parents[3] / "evals"
START = date(2026, 10, 1)


def run(accounts: int, credits: int, seed: int) -> tuple[Score, dict[str, float]]:
    started = time.monotonic()
    world = synthetic_world(accounts, seed)
    batch = generate_credits(world, credits, seed + 1)
    built = time.monotonic()
    payments = [
        c.payment(f"p{k}", START + timedelta(days=k * 5 // len(batch)))
        for k, c in enumerate(batch, start=1)
    ]
    decisions = match_all(payments, world.directory())
    matched = time.monotonic()
    score = Score()
    for c, p, d in zip(batch, payments, decisions, strict=True):
        score.add(c, p.id, d.account_id if d.automatic else None, d.review_reason)
    return score, {"build_s": built - started, "match_s": matched - built}


def failures(score: Score, threshold: float) -> list[str]:
    """What fails the eval (empty: it passes)."""
    checks = {
        "rate": score.rate < threshold,
        "wrong": bool(score.wrong),
        "policy_violations": bool(score.policy_violations),
        "bad_reason": bool(score.bad_reason),
    }
    return [name for name, failed in checks.items() if failed]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="reconciliation_eval")
    parser.add_argument("--accounts", type=int, default=50_000)
    parser.add_argument("--credits", type=int, default=100_000)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args(argv)
    threshold = float((EVALS / "reconciliation" / "threshold").read_text().strip())
    score, timing = run(args.accounts, args.credits, args.seed)
    report = score.report()
    print(
        f"reconciliation: auto {score.rate:.4f} ({score.auto}/{score.total}),"
        f" threshold {threshold:.2f},"
        f" wrong {len(score.wrong)}, policy violations {len(score.policy_violations)},"
        f" queue {score.queued}"
        f" (world {timing['build_s']:.1f}s, matching {timing['match_s']:.1f}s)"
    )
    print(json.dumps(report, indent=1, ensure_ascii=False))
    for line in (*score.wrong[:20], *score.policy_violations[:20], *score.bad_reason[:20]):
        print(f"  {line}")
    if failed := failures(score, threshold):
        print(
            f"FAILED ({', '.join(failed)}): below the threshold, a wrong automatic match, an"
            " automatic match founder decision #3 forbids, or a queue reason differs"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
