"""Data-quality report (M1-16): completeness, contactability, duplicates, reconciliation."""

from __future__ import annotations

from collections import Counter
from decimal import Decimal
from typing import Any

import polars as pl

from collectoo_worker.boarding.validate import FileResult, IssueLog


def _pct(n: int, d: int) -> float:
    return round(n / d, 4) if d else 0.0


def _minor(v: Any) -> int:
    """Civil amounts are integer minor units; EU-tape amounts are exact decimal strings."""
    if isinstance(v, int):
        return v
    return int((Decimal(str(v)) * 100).to_integral_value())


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
    rows = total = paid = file_rows = 0
    by_currency: dict[str, dict[str, int]] = {}
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
            # Duplicate rows are boarded once: recomputed here (issue details are capped).
            dup = (~f.first_distinct()).to_list()
            key = (
                "claim_item.amount"
                if "claim_item.amount" in f.values
                else "eba.f3_12_legal_balance"
            )
            amounts: list[Any] = f.col(key).to_list() if key in f.values else []
            paids = f.col("claim_item.amount_paid", pl.Int64()).to_list()
            currencies = f.col(
                "claim_item.currency" if f.eba_table is None else "eba.f3_08_currency"
            ).to_list()
            for i, a in enumerate(amounts):
                if a is None or dup[i]:
                    continue
                amount = _minor(a)
                already_paid = _minor(paids[i]) if paids[i] is not None else 0
                cur = by_currency.setdefault(
                    str(currencies[i] or "EUR").upper(), {"rows": 0, "total": 0, "paid": 0}
                )
                cur["rows"] += 1
                cur["total"] += amount
                cur["paid"] += already_paid
                rows += 1
                total += amount
                paid += already_paid
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
    computed: dict[str, Any] = {
        "rows": rows,  # claim rows boarded (duplicates once)
        "file_rows": file_rows,  # data rows in the claim files, as the seller counts them
        "total_minor": total,
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
            for c, v in sorted(by_currency.items())
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
