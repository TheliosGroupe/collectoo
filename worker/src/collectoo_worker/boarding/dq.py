"""Data-quality report (M1-16): completeness, contactability, duplicates, reconciliation."""

from __future__ import annotations

from collections import Counter
from decimal import Decimal
from typing import Any

from collectoo_worker.boarding.validate import FileResult, IssueLog


def _pct(n: int, d: int) -> float:
    return round(n / d, 4) if d else 0.0


def _minor(v: Any) -> int:
    """Amounts are minor units (int) for civil files, Decimal major units for EU tapes."""
    if isinstance(v, Decimal):
        return int((v * 100).to_integral_value())
    return int(v)


def build_report(
    files: list[FileResult],
    log: IssueLog,
    *,
    control: dict[str, Any],
    spec_versions: dict[str, int],
    addresses: dict[str, Any] | None = None,
) -> dict[str, Any]:
    by_file: dict[str, dict[str, dict[str, int]]] = {}
    for (fid, code, sev), n in log.counts.items():
        by_file.setdefault(fid, {})[code] = {"severity": sev, "count": n}  # type: ignore[dict-item]
    duplicate_rows = sum(n for (_, code, _), n in log.counts.items() if code == "duplicate_row")

    file_reports, claim_types, regimes = [], Counter[str](), Counter[str]()
    rows = total = paid = 0
    email = phone = mobile = postal = reachable = contact_rows = 0
    for f in files:
        completeness = {
            t: _pct(sum(v is not None for v in vals), f.rows)
            for t, vals in sorted(f.values.items())
        }
        file_reports.append(
            {
                "file_id": f.file_id,
                "name": f.name,
                "rows": f.rows,
                "completeness": completeness,
                "issues": by_file.get(f.file_id, {}),
            }
        )
        claim_types.update(c for c in f.claim_types if c)
        regimes.update(r for r in f.legal_regimes if r)
        if f.eba_table in (None, "t3_loan"):
            dup = set()
            for issue in log.issues:
                if issue.file_id == f.file_id and issue.code == "duplicate_row" and issue.row:
                    dup.add(issue.row - 1)
            amounts = (
                f.values.get("claim_item.amount") or f.values.get("eba.f3_12_legal_balance") or []
            )
            paids = f.values.get("claim_item.amount_paid", [None] * f.rows)
            for i, a in enumerate(amounts):
                if a is None or i in dup:
                    continue
                rows += 1
                total += _minor(a)
                paid += _minor(paids[i]) if paids[i] is not None else 0
        if f.eba_table is None:
            em = f.values.get("contact.email", [None] * f.rows)
            ph = f.values.get("contact.phone", [None] * f.rows)
            pc = f.values.get("contact.postcode", [None] * f.rows)
            for i in range(f.rows):
                contact_rows += 1
                e, p, post = em[i] is not None, ph[i] is not None, pc[i] is not None
                email += e
                phone += p
                mobile += bool(p and str(ph[i]).startswith(("+336", "+337")))
                postal += post
                reachable += e or p or post

    computed = {
        "rows": rows,
        "total_minor": total,
        "paid_minor": paid,
        "outstanding_minor": total - paid,
    }
    reconciliation: dict[str, Any] = {"computed": computed, "control": control or None}
    if control and "total_minor" in control:
        diff = computed["total_minor"] - int(control["total_minor"])
        reconciliation["difference_minor"] = diff
        reconciliation["status"] = "matched" if diff == 0 else "mismatch"
    else:
        reconciliation["status"] = "no_control_totals"
    return {
        "spec_versions": spec_versions,
        "files": file_reports,
        "totals": {
            "rows": sum(f.rows for f in files),
            "blocking": log.blocking,
            "warnings": sum(n for (_, _, s), n in log.counts.items() if s == "warning"),
        },
        "duplicates": duplicate_rows,
        "contactability": {
            "rows": contact_rows,
            "email_pct": _pct(email, contact_rows),
            "phone_pct": _pct(phone, contact_rows),
            "mobile_pct": _pct(mobile, contact_rows),
            "postal_pct": _pct(postal, contact_rows),
            "any_pct": _pct(reachable, contact_rows),
        },
        "claim_types": dict(claim_types),
        "legal_regimes": dict(regimes),
        "reconciliation": reconciliation,
        "addresses": addresses or {},
    }
