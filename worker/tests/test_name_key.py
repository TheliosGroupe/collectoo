"""M2c-7d-1 (plan docs/design/m2c-7-plan.md §6.2.7; [check 1] gap 10, [check 2] gap 4; ADR-0014
« M2c-7d-1 »): `pain001.name_key`, the Python twin of `private.epc_name_key` — the name as the
pain.001 writer spells it, compared between a payout account's holder and the client's legal name.
The writer's spellings (« Bœuf » → BOEUF, never the one-letter map of `epc_name_empty`), the accents
dropped, upper-cased, every run of other characters one space; null when a character outside Basic
Latin is left (another script, a mark outside U+0300-U+036F, U+034F): never a false match. The SQL
parity is test_name_key_parity_integration.py."""

from __future__ import annotations

import re

import pytest
from hypothesis import given
from hypothesis import strategies as st

from collectoo_worker.remittance.pain001 import epc_text, name_key

SPELLED = "œŒæÆßẞøØđĐðÐłŁþÞı\u2019\u2018\u02bc\u00b4\u2013\u2014\u2010\u2011\u00a0\u202f"


@pytest.mark.parametrize(
    ("name", "key"),
    [
        ("Bœuf SARL", "BOEUF SARL"),
        ("BOEUF SARL", "BOEUF SARL"),
        ("Æther", "AETHER"),
        ("Straße", "STRASSE"),
        ("Þór", "THOR"),
        ("Œuvre d'Élan", "OEUVRE D ELAN"),
        ("OEUVRE D ELAN", "OEUVRE D ELAN"),
        ("Bœuf d'Élan \u2013 SARL", "BOEUF D ELAN SARL"),
        ("Jean-Luc Dupont", "JEAN LUC DUPONT"),
        ("JEAN LUC DUPONT", "JEAN LUC DUPONT"),
        ("Société Martin", "SOCIETE MARTIN"),
        ("SOCIETE  MARTIN", "SOCIETE MARTIN"),
        ("  l\u2019Atelier  Øst  ", "L ATELIER OST"),
    ],
)
def test_the_writer_s_spellings(name: str, key: str) -> None:
    assert name_key(name) == key


@pytest.mark.parametrize(
    "name",
    ["Пётр Иванов", "Jean͏Dupont", "Ζωή", "---", "", "Dupont ᪰"],
)
def test_no_key_when_something_outside_basic_latin_is_left_or_nothing_is(name: str) -> None:
    assert name_key(name) is None


def test_what_the_decomposition_reveals_is_spelled_again() -> None:
    """« ŉ » decomposes to U+02BC and n, U+1D6A4 to U+0131: both spelled as the writer does after
    its NFKD (`epc_text` translates before and after), never left outside Basic Latin."""
    assert name_key("Ma\u0149 SARL") == "MA N SARL" == _collapsed(epc_text("Ma\u0149 SARL", 70))
    assert name_key("\U0001d6a4stanbul SA") == "ISTANBUL SA"


def test_a_title_or_another_word_order_is_another_key() -> None:
    assert name_key("M. Jean Dupont") != name_key("Jean Dupont")
    assert name_key("Dupont Jean") != name_key("Jean Dupont")


def _collapsed(text: str) -> str:
    return re.sub(r"[^A-Z0-9]+", " ", text.upper()).strip()


@given(
    st.text(
        alphabet=st.one_of(
            st.sampled_from(SPELLED),
            st.characters(min_codepoint=0x20, max_codepoint=0x17F),
            st.characters(min_codepoint=0x300, max_codepoint=0x36F),
            st.sampled_from("'-., /&()"),
        ),
        max_size=40,
    )
)
def test_the_key_is_the_name_the_writer_sends(name: str) -> None:
    """[check 2] Whenever the key is not null, it is what the writer sends (before its length
    cut), upper-cased with the same collapse."""
    key = name_key(name)
    if key is not None:
        assert key == _collapsed(epc_text(name, len(name) * 3))
