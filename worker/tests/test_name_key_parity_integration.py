"""M2c-7d-1 (needs `make up`; plan docs/design/m2c-7-plan.md §6.2.7, §6.6 [check 2] gap 4; ADR-0014
« M2c-7d-1 »): the two twins of the name key — `private.epc_name_key` (the holder rule of
`propose_payout_account`) and `remittance.pain001.name_key` — give the same key on generated text
(every `_SPELLED` letter, Latin-1 and Latin Extended-A, the combining marks of U+0300-U+036F and
U+034F, punctuation, any Unicode), and the pinned literals of the plan. A difference between the two
Unicode tables can only ever give no key (an explanation asked), never a false match."""

from __future__ import annotations

from typing import Any

import psycopg
import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from integration_helpers import DB

from collectoo_worker.remittance.pain001 import name_key

pytestmark = pytest.mark.integration

SPELLED = "œŒæÆßẞøØđĐðÐłŁþÞı\u2019\u2018\u02bc\u00b4\u2013\u2014\u2010\u2011\u00a0\u202f"
PINNED = {
    "Bœuf SARL": "BOEUF SARL",
    "Æther": "AETHER",
    "Straße": "STRASSE",
    "Þór": "THOR",
    "Œuvre d'Élan": "OEUVRE D ELAN",
    "Bœuf d'Élan \u2013 SARL": "BOEUF D ELAN SARL",
    "SOCIETE  MARTIN": "SOCIETE MARTIN",
    "Пётр Иванов": None,
    "Jean͏Dupont": None,
    # a character whose decomposition is spelled again (« ŉ » → U+02BC n; U+1D6A4 → U+0131)
    "Ma\u0149 SARL": "MA N SARL",
    "\U0001d6a4stanbul SA": "ISTANBUL SA",
}


@pytest.fixture(scope="module")
def conn() -> Any:
    with psycopg.connect(DB) as c:
        yield c


def _sql(conn: psycopg.Connection[Any], name: str) -> str | None:
    row = conn.execute("select private.epc_name_key(%s)", (name,)).fetchone()
    assert row is not None
    return row[0]  # type: ignore[no-any-return]


def test_the_pinned_literals(conn: psycopg.Connection[Any]) -> None:
    for name, key in PINNED.items():
        assert (_sql(conn, name), name_key(name)) == (key, key), name


@settings(
    max_examples=400, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture]
)
@given(
    st.text(
        alphabet=st.one_of(
            st.sampled_from(SPELLED),
            st.characters(min_codepoint=0x20, max_codepoint=0x17F),
            st.characters(min_codepoint=0x300, max_codepoint=0x36F),
            st.sampled_from("'-., /&()͏"),
            st.characters(max_codepoint=0x2FFF, blacklist_categories=("Cs", "Cc", "Cn")),
        ),
        max_size=30,
    )
)
def test_the_twins_agree(conn: psycopg.Connection[Any], name: str) -> None:
    assert _sql(conn, name) == name_key(name)
