"""M2c-7c-1 (needs `make up`; plan docs/design/m2c-7-plan.md §5.2.3, §5.7 « Worker »): the SQL plan
of a client's payment (private.client_payment_plan, the core private.client_settlement_plan and the
commands run) and its pure Python twin (remittance.client_payments.plan_client_payment) give the
same parts for the same documents — random documents, amounts, designations and recoveries, the
« may the client pay it » flag an input of both (Hypothesis)."""

from __future__ import annotations

import json
import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Any

import psycopg
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from integration_helpers import DB

from collectoo_worker.remittance.client_payments import (
    PayableDocument,
    WrittenOff,
    considered_open,
    plan_client_payment,
)

pytestmark = pytest.mark.integration
ON = date(2026, 11, 20)
T0 = datetime(2026, 11, 1, 9, tzinfo=UTC)


@st.composite
def cases(draw: st.DrawFn) -> tuple[list[PayableDocument], int, list[str], list[WrittenOff], bool]:
    docs: list[PayableDocument] = []
    for k in range(draw(st.integers(0, 6))):
        open_minor = draw(st.integers(1, 40_000))
        payable = draw(st.integers(0, 4)) > 0
        did = str(
            uuid.UUID(int=draw(st.integers(1, 2**60)) * 16 + k)
        )  # unique per document, random order
        if draw(st.booleans()):
            docs.append(
                PayableDocument(
                    "invoice",
                    did,
                    open_minor,
                    draw(st.integers(0, open_minor // 5)),
                    payable,
                    draw(st.one_of(st.none(), st.dates(date(2026, 10, 1), date(2026, 12, 31)))),
                    2026,
                    draw(st.integers(1, 5)) * 10 + k,
                )
            )
        else:
            docs.append(
                PayableDocument(
                    "advance",
                    did,
                    open_minor,
                    0,
                    payable,
                    born_on=draw(st.dates(date(2026, 10, 1), date(2026, 11, 30))),
                    created_at=T0 + timedelta(minutes=draw(st.integers(0, 3))),
                )
            )
    designated = draw(st.booleans())
    named = (
        [d.id for d in draw(st.permutations(docs))][: draw(st.integers(0, len(docs)))]
        if designated
        else []
    )
    recover = (
        [
            WrittenOff(str(uuid.uuid4()), draw(st.integers(1, 20_000)), draw(st.integers(0, 3)) > 0)
            for _ in range(draw(st.integers(0, 2)))
        ]
        if designated
        else []
    )
    return docs, draw(st.integers(1, 150_000)), named, recover, draw(st.booleans())


def _as_json(docs: list[PayableDocument]) -> str:
    return json.dumps(
        [
            {
                "kind": d.kind,
                "id": d.id,
                "open": str(d.open_minor),
                "pending_vat": str(d.pending_vat_minor),
                "payable": d.payable,
                "due_date": d.due_date.isoformat() if d.due_date else None,
                "year": d.year,
                "seq": d.seq,
                "born_on": d.born_on.isoformat() if d.born_on else None,
                "created_at": d.created_at.isoformat() if d.created_at else None,
            }
            for d in docs
        ]
    )


def _recover_json(recover: list[WrittenOff]) -> str:
    """The recoveries as private.client_payment_recoveries gives them: whether the client may repay
    each on the payment's date an input of both (review round 1, MONEY-1)."""
    return json.dumps(
        [{"id": w.id, "available": str(w.available_minor), "payable": w.payable} for w in recover]
    )


@pytest.fixture(scope="module")
def conn() -> Any:
    with psycopg.connect(DB) as c:
        c.execute("set role postgres")  # the definer functions' owner: internal, never a client's
        yield c


@settings(max_examples=400, deadline=None)
@given(cases())
def test_the_sql_plan_and_its_twin_agree(
    conn: psycopg.Connection[Any],
    case: tuple[list[PayableDocument], int, list[str], list[WrittenOff], bool],
) -> None:
    docs, amount, named, recover, procedure = case
    rows = conn.execute(
        """select ord, document_kind, document_id::text, amount_minor, vat_moved_minor, cause
           from private.client_payment_plan(%s::jsonb, %s, %s::uuid[], %s::jsonb, %s, %s)
           order by ord""",
        (
            _as_json(docs),
            amount,
            named,
            _recover_json(recover),
            procedure,
            ON,
        ),
    ).fetchall()
    twin = plan_client_payment(docs, amount, named, recover, procedure=procedure, on=ON)
    assert [tuple(r) for r in rows] == [
        (r.ord, r.document_kind, r.document_id, r.amount_minor, r.vat_moved_minor, r.cause)
        for r in twin
    ]
    considered = conn.execute(
        "select private.client_payment_considered(%s::jsonb, %s::uuid[], %s::jsonb)",
        (
            _as_json(docs),
            named,
            _recover_json(recover),
        ),
    ).fetchone()
    assert considered is not None and int(considered[0]) == considered_open(docs, named, recover)
