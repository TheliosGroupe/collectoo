"""M2c-6a review T3 (pain001#2, pain001#4, concurrency-perf#1): the database holds a transfer out of
the file when the pain.001 writer could not carry it, so the two must agree (needs `make up`).

* `private.epc_name_empty(name)` is true exactly when `pain001.epc_text(name, 70)` is empty (a
  payee name with no EPC basic Latin character once transliterated), on the review's names and on
  generated text (characters Python's Unicode database assigns: their NFKD is stable across
  versions);
* `private.sepa_scheme_country` and `pain001.SEPA_COUNTRIES` hold the same codes (EPC409-09 v8.0).
"""

from __future__ import annotations

import psycopg
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from integration_helpers import DB

from collectoo_worker.remittance import pain001

pytestmark = pytest.mark.integration

NAMES = [
    "Иван Петров",
    "王伟",
    "Γιώργος Παπαδόπουλος",
    "محمد",
    "Ωμέγα",
    "株式会社",
    "@@@",
    "",
    " ",
    "\u00a0\u202f",
    "Société Œuvres & Bâtiments",
    "L\u2019Oréal",
    "\u2019",
    "\u2013",
    "\u01ff",
    "\ufb01",
    "\uff21",
    "\u00b2",
    "\u1e9e",
    "Straße",
    "Ærø",
    "Łódź",
    "Þór",
    "\u0131",
    "MARTIN SAS",
    "« »",
    "€",
]


def _sql(names: list[str]) -> list[bool]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select private.epc_name_empty(x) from unnest(%s::text[]) with ordinality u (x, o)
               order by o""",
            (names,),
        ).fetchall()
    return [bool(r[0]) for r in rows]


def test_the_sql_twin_agrees_with_the_writer_on_the_reviews_names() -> None:
    assert _sql(NAMES) == [pain001.epc_text(n, 70) == "" for n in NAMES]


_TEXT = st.text(
    alphabet=st.characters(
        codec="utf-8", exclude_categories=("Cs", "Cn", "Co"), exclude_characters="\x00"
    ),
    max_size=20,
)


@settings(max_examples=40, deadline=None)
@given(st.lists(_TEXT, min_size=1, max_size=50))
def test_the_sql_twin_agrees_with_the_writer(names: list[str]) -> None:
    assert _sql(names) == [pain001.epc_text(n, 70) == "" for n in names]


def test_the_sepa_lists_are_the_same() -> None:
    with psycopg.connect(DB) as conn:
        codes = {r[0] for r in conn.execute("select code from private.sepa_scheme_country")}
        iban = conn.execute(
            "select private.iban_in_sepa('CH9300762011623852957'),"
            " private.iban_in_sepa('TN5910006035183598478831')"
        ).fetchone()
    assert codes == pain001.SEPA_COUNTRIES
    assert iban == (True, False)
