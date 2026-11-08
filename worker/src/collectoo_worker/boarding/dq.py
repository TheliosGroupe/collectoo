"""Data-quality report (M1-16): completeness, contactability, duplicates, reconciliation.

Claim totals use `boarding.items`, the definition staging uses too: civil items once per
(account, kind, ref) with credit notes negative, EU loans once per identifier with 3.12 rounded
half-up. The opening balances staged later must add up to these totals (M2-05).
"""

from __future__ import annotations

from collections import Counter
from typing import Any

import polars as pl

from collectoo_worker.boarding.items import eba_loans, staged_items
from collectoo_worker.boarding.opening import decimals, eba_components
from collectoo_worker.boarding.validate import FileResult, IssueLog
from collectoo_worker.money import to_minor_units

_BALANCING = {  # report key -> opening component
    "principal_minor": "principal",
    "accrued_interest_minor": "accrued_interest",
    "other_balances_minor": "other_balances",
    "balancing_minor": "balancing_line",
}


def _pct(n: int, d: int) -> float:
    return round(n / d, 4) if d else 0.0


class _Totals:
    """Claim totals per currency (amounts in minor units)."""

    def __init__(self) -> None:
        self.by_currency: dict[str, dict[str, int]] = {}

    def add(self, currency: str, rows: int, total: int, paid: int) -> None:
        cur = self.by_currency.setdefault(currency, {"rows": 0, "total": 0, "paid": 0})
        cur["rows"] += rows
        cur["total"] += total
        cur["paid"] += paid

    def sum(self, key: str) -> int:
        return sum(v[key] for v in self.by_currency.values())


def _claim_totals(files: list[FileResult]) -> tuple[_Totals, dict[str, dict[str, Any]]]:
    """Totals of the claims boarded, and the EU tapes' balancing lines per currency."""
    totals = _Totals()
    items = staged_items([f for f in files if f.eba_table is None])
    by_currency = items.group_by("currency").agg(
        pl.len().alias("rows"),
        pl.col("signed_minor").sum().alias("total"),
        pl.col("seller_paid_minor").sum().alias("paid"),
    )
    for currency, rows, total, paid in by_currency.iter_rows():
        totals.add(currency, rows, int(total), int(paid))
    balancing: dict[str, dict[str, Any]] = {}
    for t3 in (f for f in files if f.eba_table == "t3_loan"):
        loans = eba_loans(t3).filter(pl.col("first") & pl.col("p312").is_not_null())
        for currency, *amounts in loans.select(
            "currency", "p309", "p310", "p311", "p312"
        ).iter_rows():
            p309, p310, p311, p312 = decimals(*amounts)
            components = eba_components(p309, p310, p311, p312)
            totals.add(currency, 1, to_minor_units(p312) if p312 is not None else 0, 0)
            b = balancing.setdefault(
                currency,
                {
                    **dict.fromkeys(_BALANCING, 0),
                    "loans_with_balancing": 0,
                    "negative_balancing": 0,
                    "missing_components": 0,
                },
            )
            for key, component in _BALANCING.items():
                b[key] += components.get(component, 0)
            line = components.get("balancing_line", 0)
            b["loans_with_balancing"] += line != 0
            b["negative_balancing"] += line < 0
            b["missing_components"] += None in (p309, p310, p311)
    return totals, {
        c: {k: str(v) if k in _BALANCING else v for k, v in b.items()}
        for c, b in sorted(balancing.items())
    }


def build_report(  # noqa: PLR0913 - the report's inputs
    files: list[FileResult],
    log: IssueLog,
    *,
    control: dict[str, Any],
    spec_versions: dict[str, int],
    addresses: dict[str, Any] | None = None,
    unread_files: dict[str, str] | None = None,
) -> dict[str, Any]:
    by_file: dict[str, dict[str, dict[str, int]]] = {}
    for (fid, code, sev), n in log.counts.items():
        by_file.setdefault(fid, {})[code] = {"severity": sev, "count": n}  # type: ignore[dict-item]
    duplicate_rows = sum(n for (_, code, _), n in log.counts.items() if code == "duplicate_row")

    file_reports, claim_types, regimes = [], Counter[str](), Counter[str]()
    file_rows = 0
    email = phone = mobile = postal = reachable = contact_rows = 0
    for f in files:
        completeness = {
            t: _pct(f.rows - vals.null_count(), f.rows) for t, vals in sorted(f.values.items())
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
            file_rows += f.rows
        if f.eba_table is None:
            em = f.col("contact.email").to_list()
            ph = f.col("contact.phone").to_list()
            pc = f.col("contact.postcode").to_list()
            for i in range(f.rows):
                contact_rows += 1
                e, p, post = em[i] is not None, ph[i] is not None, pc[i] is not None
                email += e
                phone += p
                mobile += bool(p and str(ph[i]).startswith(("+336", "+337")))
                postal += post
                reachable += e or p or post

    for fid, name in (unread_files or {}).items():
        # Not read as a table (its blocking issue says why): listed so the report shows it.
        file_reports.append(
            {
                "file_id": fid,
                "name": name,
                "rows": 0,
                "completeness": {},
                "issues": by_file.get(fid, {}),
            }
        )
    claims, balancing = _claim_totals(files)
    total, paid = claims.sum("total"), claims.sum("paid")
    computed: dict[str, Any] = {
        "rows": claims.sum("rows"),  # claims boarded (each document or loan once)
        "file_rows": file_rows,  # data rows in the claim files, as the seller counts them
        "total_minor": total,  # signed: credit notes count negative
        "paid_minor": paid,
        "outstanding_minor": total - paid,
        # Per currency; amounts as decimal strings so browsers never round them.
        "currencies": {
            c: {
                "rows": v["rows"],
                "total_minor": str(v["total"]),
                "paid_minor": str(v["paid"]),
                "outstanding_minor": str(v["total"] - v["paid"]),
            }
            for c, v in sorted(claims.by_currency.items())
        },
    }
    reconciliation = _reconcile(computed, control)
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
        # EU tapes, per currency: Σ 3.09 / 3.10 / 3.11 / balancing line (3.12 - the three;
        # amounts as strings) and how many loans have one, a negative one, a missing component.
        "balancing": balancing,
        "addresses": addresses or {},
    }


def _reconcile(computed: dict[str, Any], control: dict[str, Any] | None) -> dict[str, Any]:
    """Seller's control totals vs the tape: the outstanding balance at cut-off (amounts minus
    what the seller reports as already paid) in euros, and the number of data rows."""
    rec: dict[str, Any] = {
        "computed": computed,
        "control": control or None,
        "basis": "outstanding_minor",
    }
    given = control or {}
    has_total = given.get("total_minor") is not None
    has_rows = given.get("rows") is not None
    if not (has_total or has_rows):
        rec["status"] = "no_control_totals"
        return rec
    mismatch = False
    if has_total:
        if set(computed["currencies"]) - {"EUR"}:
            # A single euro total cannot be compared with amounts in other currencies.
            rec["currency_mismatch"] = sorted(computed["currencies"])
            mismatch = True
        else:
            diff = computed["outstanding_minor"] - int(given["total_minor"])
            rec["difference_minor"] = diff
            mismatch |= diff != 0
    if has_rows:
        rec["difference_rows"] = computed["file_rows"] - int(given["rows"])
        mismatch |= rec["difference_rows"] != 0
    rec["status"] = "mismatch" if mismatch else "matched"
    return rec
