"""Reconciliation through the database (M2-08, needs `make up`): statements imported, the match
job queued by the import, decisions recorded and gated in SQL, scored against the truth."""

import json
import random
import string
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, storage
from reconciliation_helpers import pay, score, world_into_db
from statement_helpers import bank_tenant

from collectoo_worker.payments.matching import ref_key
from collectoo_worker.synth.reconciliation import (
    generate_credits,
    history_credits,
    synthetic_world,
)

pytestmark = pytest.mark.integration


def test_the_synthetic_statement_is_matched_through_the_database() -> None:
    """The acceptance criterion through the real path: ≥ 95 % matched automatically, none wrong,
    every other credit in the queue with the reason ops will see."""
    tenant = bank_tenant()
    store = storage()
    world = world_into_db(tenant, synthetic_world(600, seed=7))
    history = history_credits(world, seed=7)
    hist = score(pay(tenant, store, history, prefix="H"), history, "H")
    assert hist.wrong == [] and hist.auto == hist.total  # what teaches the IBAN memory
    credits = generate_credits(world, 1_500, seed=8, earlier=history)
    result = score(pay(tenant, store, credits, prefix="M"), credits, "M")
    print("\n" + json.dumps(result.report(), indent=1))
    assert result.wrong == [], result.wrong[:5]
    assert result.bad_reason == [], result.bad_reason[:5]
    assert result.rate >= 0.95, result.report()
    assert result.ready_rate >= 0.95, result.report()  # and not held by the gating


def test_sql_and_python_read_references_alike() -> None:
    rng = random.Random(5)
    alphabet = string.ascii_letters + string.digits + " -/._°éÉ\n\t"
    texts = ["".join(rng.choice(alphabet) for _ in range(rng.randint(0, 20))) for _ in range(2000)]
    with psycopg.connect(DB) as conn:
        rows: list[Any] = conn.execute(
            "select x, private.ref_key(x)"
            " from unnest(%s::text[]) with ordinality t (x, i) order by i",
            (texts,),
        ).fetchall()
    assert [(x, k) for x, k in rows] == [(x, ref_key(x)) for x in texts]
