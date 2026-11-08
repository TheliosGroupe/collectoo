"""Duplicate rows (M1-15 / M1-17): the hash-based check is exact on any input."""

import polars as pl
from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.boarding.profile import profile_frame
from collectoo_worker.boarding.validate import first_distinct

cell = st.one_of(st.none(), st.sampled_from(["", "a", "b", "1,00", " a"]))
rows = st.lists(st.tuples(cell, cell, cell), max_size=40)


def _frame(data: list[tuple[str | None, ...]]) -> pl.DataFrame:
    return pl.DataFrame(data, schema=["x", "y", "z"], orient="row", schema_overrides={})


@settings(max_examples=200, deadline=None)
@given(rows)
def test_first_distinct_matches_a_full_row_comparison(data: list[tuple[str | None, ...]]) -> None:
    df = _frame(data).cast(pl.Utf8)
    expected = df.select(pl.struct(pl.all()).is_first_distinct()).to_series().to_list()
    assert first_distinct(df).to_list() == expected


def test_profile_counts_extra_copies_of_identical_rows() -> None:
    df = _frame([("a", "1", None), ("a", "1", None), ("a", "1", None), ("b", "1", None)])
    assert profile_frame(df.cast(pl.Utf8).lazy())["duplicate_rows"] == 2
