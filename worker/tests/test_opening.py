"""M2-05 opening balances, Python side (design §7): the formula, the staging contract and the
reconciliation bridge `DQ computed = staging.opening + staging.skipped`, per currency."""

from decimal import Decimal
from typing import Any

import polars as pl
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from test_items import civil_file, row, validate
from test_validation import _eba_files, _validate

from collectoo_worker.boarding.dq import build_report
from collectoo_worker.boarding.opening import (
    OpeningMismatchError,
    check_bridge,
    eba_components,
    item_outstanding,
    opening_totals,
)
from collectoo_worker.boarding.stage import split_skipped, stage_rows
from collectoo_worker.boarding.validate import FileResult
from collectoo_worker.money import to_minor_units


@pytest.mark.parametrize(
    ("kind", "original", "paid", "expected"),
    [
        ("invoice", 125000, 25000, 100000),
        ("invoice", 50000, 0, 50000),
        ("credit_note", 10000, 0, -10000),
        ("invoice", 3000, 3000, 0),  # paid in full
        ("rent_period", 1000, 1500, -500),  # overpaid: debtor in credit, posted signed
        ("credit_note", 0, 0, 0),
    ],
)
def test_item_outstanding(kind: str, original: int, paid: int, expected: int) -> None:
    assert item_outstanding(kind, original, paid) == expected


def _d(v: str | None) -> Decimal | None:
    return None if v is None else Decimal(v)


@pytest.mark.parametrize(
    ("amounts", "expected"),
    [
        (  # 3.12 off by +7 cents: the balancing line
            ("100.00", "20.00", "5.00", "125.07"),
            {
                "principal": 10000,
                "accrued_interest": 2000,
                "other_balances": 500,
                "balancing_line": 7,
            },
        ),
        (  # components above the legal balance: negative balancing line
            ("100.00", "20.00", "5.00", "120.00"),
            {
                "principal": 10000,
                "accrued_interest": 2000,
                "other_balances": 500,
                "balancing_line": -500,
            },
        ),
        (("1000.00", "0.00", "0", "1000.00"), {"principal": 100000}),  # zero lines dropped
        ((None, None, None, "50.00"), {"balancing_line": 5000}),  # only 3.12: all balancing
        ((None, "12.50", None, "112.50"), {"accrued_interest": 1250, "balancing_line": 10000}),
        (  # 4 decimals, rounded half-up per component, balancing from the rounded units
            ("100.0050", "0.0049", "0.0050", "100.0150"),
            {"principal": 10001, "other_balances": 1},
        ),
        (("-1.005", None, None, "0"), {"principal": -101, "balancing_line": 101}),
        (("0", "0", "0", "0"), {}),
    ],
)
def test_eba_components(
    amounts: tuple[str | None, str | None, str | None, str | None], expected: dict[str, int]
) -> None:
    p309, p310, p311, p312 = (_d(a) for a in amounts)
    components = eba_components(p309, p310, p311, p312)
    assert components == expected
    assert p312 is not None and sum(components.values()) == to_minor_units(p312)  # Σ = 3.12


def _account(key: str, currency: str = "EUR") -> dict[str, Any]:
    return {"key": key, "external_ref": key, "currency": currency}


def _item(key: str, kind: str, original: int, paid: int = 0, cur: str = "EUR") -> dict[str, Any]:
    return {
        "key": key,
        "account_key": key,
        "kind": kind,
        "ref": f"{key}-{kind}-{original}",
        "original_minor": original,
        "seller_paid_minor": paid,
        "currency": cur,
    }


def test_opening_totals_contract() -> None:
    staged = {
        "account": pl.DataFrame(
            [_account("A1"), _account("A2"), _account("A3"), _account("L1"), _account("U1", "USD")]
        ),
        "claim_item": pl.DataFrame(
            [
                _item("A1", "invoice", 125000, 25000),
                _item("A1", "invoice", 50000),
                _item("A2", "credit_note", 10000),
                _item("A3", "invoice", 7000, 7000),  # paid in full: no balance
                _item("L1", "loan_principal", 12507),
                _item("U1", "invoice", 999, cur="USD"),
            ]
        ),
        "eba.t3_loan": pl.DataFrame(
            {
                "key": ["1"],
                "f3_01_loan_identifier": ["L1"],
                "f3_09_principal_amount": ["100.00"],
                "f3_10_accrued_interest": ["20.00"],
                "f3_11_other_balances": [None],
                "f3_12_legal_balance": ["125.07"],
            },
            schema_overrides={"f3_11_other_balances": pl.Utf8},
        ),
    }
    assert opening_totals(staged) == {
        "currencies": {
            "EUR": {
                "accounts": 3,
                "accounts_without_balance": 1,
                "outstanding_minor": str(150000 - 10000 + 12507),
                "components": {
                    "principal": str(150000 - 10000 + 10000),
                    "accrued_interest": "2000",
                    "balancing_line": "507",
                },
            },
            "USD": {
                "accounts": 1,
                "accounts_without_balance": 0,
                "outstanding_minor": "999",
                "components": {"principal": "999"},
            },
        }
    }
    staged_rows, opening, skipped = split_skipped(staged, {"A1", "U1"})
    assert skipped["currencies"]["EUR"]["outstanding_minor"] == "150000"
    assert set(skipped["currencies"]) == {"EUR", "USD"}
    assert opening["currencies"]["EUR"]["outstanding_minor"] == str(-10000 + 12507)
    assert "USD" not in opening["currencies"]
    assert staged_rows["account"]["key"].to_list() == ["A2", "A3", "L1"]
    assert staged_rows["claim_item"].height == 3
    assert staged_rows["eba.t3_loan"].height == 1  # Layer 1 keeps the whole tape
    assert split_skipped(staged, set())[2] == {"currencies": {}}


def test_check_bridge() -> None:
    computed = {"EUR": {"outstanding_minor": "100"}, "USD": {"outstanding_minor": "-5"}}
    opening = {"currencies": {"EUR": {"outstanding_minor": "70"}}}
    skipped = {
        "currencies": {"EUR": {"outstanding_minor": "30"}, "USD": {"outstanding_minor": "-5"}}
    }
    check_bridge(computed, opening, skipped)
    with pytest.raises(
        OpeningMismatchError, match=r"EUR: computed 100 != opening 70 \+ skipped 31"
    ):
        check_bridge(
            computed,
            opening,
            {"currencies": {**skipped["currencies"], "EUR": {"outstanding_minor": "31"}}},
        )
    with pytest.raises(OpeningMismatchError, match="GBP"):
        check_bridge(computed, {"currencies": {"GBP": {"outstanding_minor": "1"}}}, skipped)


def _bridge(files: list[FileResult], skip: set[str]) -> None:
    log = validate(*files)
    computed = build_report(files, log, control={}, spec_versions={})["reconciliation"]["computed"]
    _, opening, skipped = split_skipped(stage_rows(files, log), skip)
    check_bridge(computed["currencies"], opening, skipped)
    for c in set(computed["currencies"]) | set(opening["currencies"]) | set(skipped["currencies"]):
        expected = int(computed["currencies"].get(c, {}).get("outstanding_minor", 0))
        got = sum(
            int(t["currencies"].get(c, {}).get("outstanding_minor", 0)) for t in (opening, skipped)
        )
        assert got == expected, c
    for totals in (opening, skipped):
        for c, t in totals["currencies"].items():
            assert sum(int(v) for v in t["components"].values()) == int(t["outstanding_minor"]), c
            assert all(int(v) != 0 for v in t["components"].values())


def test_bridge_on_a_synthetic_eba_tape_with_balancing_lines_of_both_signs() -> None:
    files, profiles = _eba_files(30)
    t3 = next(f for f in files if f.eba_table == "t3_loan")
    legal = t3.raw["f3_12_legal_balance"].to_list()
    legal[0] = str(Decimal(legal[0]) + Decimal("0.07"))
    legal[1] = str(Decimal(legal[1]) - Decimal("1.234"))
    t3.raw = t3.raw.with_columns(pl.Series("f3_12_legal_balance", legal))
    log = _validate(files, profiles)
    computed = build_report(files, log, control={}, spec_versions={})["reconciliation"]["computed"]
    loans = set(t3.raw["f3_01_loan_identifier"].to_list()[:7])
    _, opening, skipped = split_skipped(stage_rows(files, log), loans)
    check_bridge(computed["currencies"], opening, skipped)
    eur = opening["currencies"]["EUR"]
    assert eur["accounts"] + eur["accounts_without_balance"] == 23
    assert skipped["currencies"]["EUR"]["accounts"] == 7
    assert "balancing_line" in skipped["currencies"]["EUR"]["components"]


# --- Property: opening + skipped == DQ computed, per currency ----------------------------------

_cents = st.integers(min_value=-30_000, max_value=200_000)


def _money(cents: int) -> str:
    sign = "-" if cents < 0 else ""
    return f"{sign}{abs(cents) // 100}.{abs(cents) % 100:02d}"


_rows = st.builds(
    lambda account, kind, ref, period, due, amount, paid, currency: row(
        account,
        type=kind,
        piece=ref,
        periode=period,
        echeance=due,
        montant=None if amount is None else _money(amount),
        regle=None if paid is None else _money(paid),
        devise=currency,
    ),
    st.sampled_from(["A1", "A2", "A3"]),
    st.sampled_from([None, "FACTURE", "AVOIR"]),
    st.sampled_from([None, None, "F1", "F2"]),  # few numbers: duplicates and conflicts
    st.sampled_from([None, "01/2026", "02/2026"]),  # colliding derived refs
    st.sampled_from([None, "05/01/2026", "05/02/2026"]),
    st.one_of(st.none(), _cents),
    st.one_of(st.none(), st.just(0), st.integers(min_value=0, max_value=250_000)),
    st.sampled_from([None, "EUR", "USD"]),
)
_file_rows = st.lists(_rows, min_size=1, max_size=10).flatmap(
    # exact duplicate rows (boarded once)
    lambda rs: st.lists(st.sampled_from(rs), max_size=3).map(lambda extra: rs + extra)
)
_batches = st.one_of(
    _file_rows.map(lambda rs: [rs]),
    st.tuples(_file_rows, _file_rows).map(list),
    _file_rows.map(lambda rs: [rs, rs]),  # the same file sent twice
)


@settings(max_examples=150, deadline=None)
@given(batch=_batches, skip=st.sets(st.sampled_from(["A1", "A2", "A3"])))
def test_opening_plus_skipped_equals_the_dq_report(
    batch: list[list[dict[str, str | None]]], skip: set[str]
) -> None:
    files = [civil_file(f"f{i}", rows) for i, rows in enumerate(batch)]
    _bridge(files, skip)


def test_bridge_on_a_synthetic_civil_tape() -> None:
    rows = [
        row("C1", piece="F1", montant="1250.00", regle="250.00"),
        row("C1", piece="F2", montant="500.00"),
        row("C1", piece="AV1", type="AVOIR", montant="100.00"),
        row("C2", piece="F3", montant="70.00", regle="70.00"),
        row("C2", piece="F4", montant="10.00", regle="12.00"),
        row("C3", periode="03/2026", montant="700.00"),
        row("C3", periode="03/2026", montant="90.00"),
    ]
    _bridge([civil_file("f1", rows)], {"C2"})
    _bridge([civil_file("f1", rows), civil_file("f2", rows)], set())
