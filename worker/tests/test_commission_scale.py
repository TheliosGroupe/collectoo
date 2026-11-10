"""The commission engine at the design's scale (§19: a 50k-line run): two parts a line (principal at
a marginal rate with a minimum, interest at a bracket rate), two terms versions per mandate, 200
mandates. A guard with a generous bound, so that a regression shows before the M2c-7 scale run;
the measured figures are in docs/benchmarks/remittances.md."""

from __future__ import annotations

import time
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal

from collectoo_worker.remittance.commission import (
    FileFacts,
    Line,
    LineKind,
    TermsVersion,
    compute,
)
from collectoo_worker.remittance.documents import run_documents
from collectoo_worker.remittance.terms import CommissionSchedule

N = 50_000
BOUND_S = 15.0  # measured ≈ 2.6 s for the engine (hash included), ≈ 0.6 s for the documents


def _schedule() -> CommissionSchedule:
    basis = {
        "families": "all",
        "forwards": {
            "file_recalled": False,
            "before_servicing_start": False,
            "client_ratification": False,
        },
        "on_reversal": "credit",
    }
    marginal = [
        {"up_to_minor": "100000", "rate": "0.15"},
        {"up_to_minor": "500000", "rate": "0.10"},
        {"up_to_minor": None, "rate": "0.06"},
    ]
    brackets = [{"up_to": "100000", "rate": "0.20"}, {"up_to": None, "rate": "0.12"}]
    return CommissionSchedule.model_validate(
        {
            "schema": "commission-1",
            "basis": basis,
            "rules": [
                {
                    "id": "p",
                    "tier_key": "p",
                    "label_fr": "Principal",
                    "match": {"families": ["principal"]},
                    "min_per_file_minor": "5000",
                    "rate": {"kind": "marginal", "tiers": marginal},
                },
                {
                    "id": "o",
                    "tier_key": "o",
                    "label_fr": "Autres",
                    "match": {},
                    "rate": {
                        "kind": "bracket",
                        "attribute": "boarded_amount",
                        "brackets": brackets,
                    },
                },
            ],
        }
    )


def test_a_50k_line_run_stays_within_its_budget() -> None:
    schedule = _schedule()
    versions = {
        f"M{m}": [
            TermsVersion(f"M{m}-1", f"M{m}", date(2026, 1, 1), date(2026, 6, 1), schedule),
            TermsVersion(f"M{m}-2", f"M{m}", date(2026, 6, 1), None, schedule),
        ]
        for m in range(200)
    }
    files = {}
    lines = []
    for i in range(N):
        fid, e = f"F{i}", date(2026, 1, 5) + timedelta(days=i % 300)
        files[fid] = FileFacts(fid, f"M{i % 200}", "b2b_invoice", "P1", 50_000 + i)
        basis = {"principal": 10_000 + i % 777, "interest": 300}
        posted = datetime(e.year, e.month, e.day, 12, tzinfo=UTC)
        lines.append(
            Line(f"E{i}", LineKind.ALLOCATION, fid, e, e, posted, sum(basis.values()), basis)
        )
    t0 = time.perf_counter()
    result = compute(lines, files, versions, {}, Decimal("0.2"))
    t1 = time.perf_counter()
    docs = run_documents(result.lines, files, {}, {}, Decimal("0.2"))
    t2 = time.perf_counter()
    print(f"commission {t1 - t0:.2f} s, documents {t2 - t1:.2f} s for {N} lines")
    assert len(result.lines) == N and len(docs) == 200
    assert sum(len(r.parts) for r in result.lines) == 2 * N
    assert t1 - t0 < BOUND_S and t2 - t1 < BOUND_S
