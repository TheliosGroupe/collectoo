"""Opening balances of a staged batch (M2-05): the single Python formula of the opening.

Mirrored in SQL by `private.opening_lines` (docs/design/m2a-ledger.md §5.3, §7). Per account:
- civil and commercial items: one `principal` line per item, `item_outstanding` (signed: a
  credit note or an overpaid invoice is negative);
- an EU loan: the components of its T3 row, `eba_components` (their sum is exactly 3.12).

Zero lines are dropped; an account whose lines are all zero (or that has none) counts in
`accounts_without_balance`. `opening_totals` gives the totals per currency in the shape stored
in `dq_report.staging.opening` / `.skipped` (amounts as strings, like the DQ report), which the
commit and the posting compare to the cent. `check_bridge` is the staging invariant:
DQ computed outstanding = staging.opening + staging.skipped, per currency (§7.3).

Rows are streamed (a 1M-loan tape never holds a Python object per loan at once).
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Collection, Iterator, Mapping
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any

import polars as pl

from collectoo_worker.money import to_minor_units

COMPONENTS = ("principal", "accrued_interest", "other_balances", "balancing_line")
EBA_COLUMNS = (
    "f3_09_principal_amount",
    "f3_10_accrued_interest",
    "f3_11_other_balances",
    "f3_12_legal_balance",
)


class OpeningMismatchError(RuntimeError):
    """The staged opening does not add up to the DQ report: a bug, never a seller discrepancy."""


def item_outstanding(kind: str, original_minor: int, seller_paid_minor: int) -> int:
    """Opening of a civil item: -original for a credit note, +original otherwise, minus paid."""
    signed = -original_minor if kind == "credit_note" else original_minor
    return signed - seller_paid_minor


def eba_components(
    p309: Decimal | None, p310: Decimal | None, p311: Decimal | None, p312: Decimal | None
) -> dict[str, int]:
    """Opening components of an EU loan, in minor units (half-up), zero lines dropped.

    Principal 3.09, accrued interest 3.10, other balances 3.11 and the signed balancing line
    3.12 - (3.09 + 3.10 + 3.11), computed from the rounded minor units; a missing value counts 0.
    """

    def minor(v: Decimal | None) -> int:
        return 0 if v is None else to_minor_units(v)

    principal, interest, other = minor(p309), minor(p310), minor(p311)
    lines = {
        "principal": principal,
        "accrued_interest": interest,
        "other_balances": other,
        "balancing_line": minor(p312) - (principal + interest + other),
    }
    return {component: v for component, v in lines.items() if v != 0}


def decimals(*values: Any) -> tuple[Decimal | None, ...]:
    """Exact decimal strings (or None) -> Decimal (or None)."""
    return tuple(None if v is None else Decimal(str(v)) for v in values)


def loan_components(loans: pl.DataFrame) -> Iterator[dict[str, int]]:
    """`eba_components` of each row of a loans frame (`items.eba_loans`: p309…p312 strings)."""
    for amounts in loans.select("p309", "p310", "p311", "p312").iter_rows():
        yield eba_components(*decimals(*amounts))


@dataclass
class _Currency:
    accounts: int = 0
    without_balance: int = 0
    outstanding: int = 0
    components: Counter[str] = field(default_factory=Counter)

    def as_json(self) -> dict[str, Any]:
        return {
            "accounts": self.accounts,
            "accounts_without_balance": self.without_balance,
            "outstanding_minor": str(self.outstanding),
            "components": {
                c: str(self.components[c]) for c in COMPONENTS if self.components[c] != 0
            },
        }


def _accounts(staged: Mapping[str, pl.DataFrame], accounts: Collection[str] | None) -> pl.DataFrame:
    """(key, currency) of the staged accounts, once per key, restricted to `accounts` if given."""
    rows = staged.get("account")
    if rows is None:
        return pl.DataFrame(schema={"key": pl.Utf8, "currency": pl.Utf8})
    out = rows.select("key", pl.col("currency").fill_null("EUR")).unique(
        "key", keep="first", maintain_order=True
    )
    if accounts is not None:
        out = out.filter(pl.col("key").is_in(sorted(accounts)).fill_null(False))
    return out


def _lines(
    staged: Mapping[str, pl.DataFrame], keys: pl.DataFrame
) -> Iterator[tuple[str | None, str, str, int]]:
    """(account key, currency, component, amount) of the opening lines of these accounts."""
    items = staged.get("claim_item")
    if items is None or items.height == 0:
        return
    items = items.join(keys, left_on="account_key", right_on="key", how="semi", nulls_equal=True)
    civil = items.filter(pl.col("kind") != "loan_principal").select(
        "account_key", "kind", "original_minor", "seller_paid_minor", "currency"
    )
    for key, kind, original, paid, currency in civil.iter_rows():
        yield key, currency or "EUR", "principal", item_outstanding(kind, original, paid or 0)
    loans = items.filter(pl.col("kind") == "loan_principal")
    if loans.height == 0:
        return
    t3 = staged.get("eba.t3_loan", pl.DataFrame({"f3_01_loan_identifier": []}))
    t3 = t3.select(
        pl.col("f3_01_loan_identifier").cast(pl.Utf8),
        *(pl.col(c).cast(pl.Utf8) if c in t3.columns else pl.lit(None, pl.Utf8).alias(c)
          for c in EBA_COLUMNS),
        pl.lit(True).alias("_t3"),
    ).unique("f3_01_loan_identifier", keep="first", maintain_order=True)  # fmt: skip
    joined = loans.join(
        t3, left_on="account_key", right_on="f3_01_loan_identifier", how="left", nulls_equal=True
    ).select("account_key", "original_minor", "currency", "_t3", *EBA_COLUMNS)
    for key, original, currency, has_t3, *amounts in joined.iter_rows():
        p309, p310, p311, p312 = decimals(*amounts)
        if not has_t3 or p312 is None or to_minor_units(p312) != original:  # SQL: LG006
            raise OpeningMismatchError(f"loan {key!r}: claim item is not its T3 row's 3.12 x 100")
        for component, amount in eba_components(p309, p310, p311, p312).items():
            yield key, currency or "EUR", component, amount


def opening_totals(
    staged: Mapping[str, pl.DataFrame], accounts: Collection[str] | None = None
) -> dict[str, Any]:
    """`{"currencies": {c: {accounts, accounts_without_balance, outstanding_minor, components}}}`
    of the staged rows, for the given account keys (default: every staged account)."""
    keys = _accounts(staged, accounts)
    totals: dict[str, _Currency] = {}
    with_balance: set[str | None] = set()
    for key, currency, component, amount in _lines(staged, keys.select("key")):
        if amount == 0:
            continue
        with_balance.add(key)
        t = totals.setdefault(currency, _Currency())
        t.outstanding += amount
        t.components[component] += amount
    for key, currency in keys.iter_rows():
        t = totals.setdefault(currency, _Currency())
        if key in with_balance:
            t.accounts += 1
        else:
            t.without_balance += 1
    return {"currencies": {c: t.as_json() for c, t in sorted(totals.items())}}


def check_bridge(
    computed: Mapping[str, Mapping[str, Any]],
    opening: Mapping[str, Any],
    skipped: Mapping[str, Any],
) -> None:
    """Raise unless, for every currency, the DQ report's computed outstanding equals the opening
    of the staged accounts plus the opening of the accounts skipped as already boarded."""

    def outstanding(totals: Mapping[str, Any], currency: str) -> int:
        return int(totals.get(currency, {}).get("outstanding_minor", 0))

    staged, skip = opening["currencies"], skipped["currencies"]
    mismatches = []
    for c in sorted(set(computed) | set(staged) | set(skip)):
        dq, op, sk = outstanding(computed, c), outstanding(staged, c), outstanding(skip, c)
        if dq != op + sk:
            mismatches.append(f"{c}: computed {dq} != opening {op} + skipped {sk}")
    if mismatches:
        raise OpeningMismatchError(
            "staging: opening balances do not reconcile with the data-quality report ("
            + "; ".join(mismatches)
            + ")"
        )
