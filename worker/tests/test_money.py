from decimal import Decimal

import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.money import split_evenly, to_minor_units


@pytest.mark.parametrize(
    ("amount", "expected"),
    [("12.345", 1235), ("12.344", 1234), ("0.005", 1), ("-1.005", -101), ("100", 10000)],
)
def test_to_minor_units_rounds_half_up(amount: str, expected: int) -> None:
    assert to_minor_units(Decimal(amount)) == expected


def test_to_minor_units_rejects_non_finite() -> None:
    with pytest.raises(ValueError, match="finite"):
        to_minor_units(Decimal("NaN"))


@given(
    total=st.integers(min_value=0, max_value=10**12),
    parts=st.integers(min_value=1, max_value=360),
)
def test_split_evenly_preserves_total_and_is_fair(total: int, parts: int) -> None:
    instalments = split_evenly(total, parts)
    assert len(instalments) == parts
    assert sum(instalments) == total
    assert max(instalments) - min(instalments) <= 1
    assert instalments == sorted(instalments, reverse=True)
