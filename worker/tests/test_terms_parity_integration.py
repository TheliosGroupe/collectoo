"""M2c-2 (design §8.5): the money-terms validators agree in Python (pydantic,
collectoo_worker.remittance.terms) and in SQL (private.commission_schedule_valid /
private.remittance_terms_valid, the CHECK constraints of mandate_terms) on 5,000 generated
schedules and 5,000 generated remittance terms, valid and invalid; and the back-fill's schedule is
the Python one."""

import json
from typing import Any

import psycopg
import pytest
from integration_helpers import DB
from terms_cases import schedules, terms

from collectoo_worker.remittance.terms import (
    commission_schedule_valid,
    legacy_schedule,
    remittance_terms_valid,
)

pytestmark = pytest.mark.integration
N = 5_000


def _sql_verdicts(function: str, docs: list[Any]) -> list[bool]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            f"select private.{function}(t.e) from jsonb_array_elements(%s::jsonb)"  # noqa: S608
            " with ordinality t (e, n) order by t.n",
            (json.dumps(docs),),
        ).fetchall()
    return [bool(r[0]) for r in rows]


@pytest.mark.parametrize(
    ("function", "generate", "python"),
    [
        ("commission_schedule_valid", schedules, commission_schedule_valid),
        ("remittance_terms_valid", terms, remittance_terms_valid),
    ],
)
def test_sql_and_python_give_the_same_verdict(function: str, generate: Any, python: Any) -> None:
    docs = generate(N, seed=20261111)
    sql = _sql_verdicts(function, docs)
    py = [python(d) for d in docs]
    differ = [(i, docs[i], py[i], sql[i]) for i in range(N) if py[i] != sql[i]]
    assert not differ, differ[:5]
    # both verdicts well represented: the corpus tests the rules, not only the happy path
    assert 1_000 < sum(py) < N - 1_000


def test_the_back_fill_schedule_is_the_python_one() -> None:
    with psycopg.connect(DB) as conn:
        for rate in ("0.15", "0", "1", "0.1234"):
            sql = conn.execute(
                "select private.legacy_commission_schedule(%s::numeric)", (rate,)
            ).fetchone()
            assert sql is not None
            assert sql[0] == legacy_schedule(rate)
            assert commission_schedule_valid(sql[0])
