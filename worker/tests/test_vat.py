"""VAT on the commission (design §3, §8.4, §8.5, §9.6; rule pack `vat/fr`): the rate rows and their
references, the rounding bounds (Hypothesis), and the tripwire of the 2027 recodification.

The tripwire: from `review.due_from` (2026-12-01 for the 2027 recodification) CI fails until a human
re-reads every text due — the CIBS L213-151 rate row and the exigibility, invoicing and credit-note
texts (CIBS L211-4, L214-6, L214-9, L216-25, L216-30, the maintained CGI 269 2 c …) —, records
`reviewed_on` / `reviewed_by` on all of them in worker/rule_packs/vat/fr.yaml (the loader refuses
them recorded apart) and a migration copies the rate row's into public.vat_rate (the integration
test checks the table equals the file)."""

from datetime import UTC, date, datetime
from decimal import Decimal
from fractions import Fraction
from itertools import pairwise

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.receipts import paris_date
from collectoo_worker.remittance.packs import vat_pack
from collectoo_worker.remittance.vat import (
    VatRateMissingError,
    credit_note_vat,
    div_half_up,
    rate_on,
    rate_row,
    reviews_due,
    scaled,
    texts_due,
    vat_moved,
    vat_of,
)

rates = st.integers(0, 10_000).map(lambda n: Decimal(n) / 10_000)


def test_the_standard_rate_and_its_texts() -> None:
    assert rate_on(date(2026, 11, 10)) == Decimal("0.2")
    assert rate_row(date(2026, 12, 31)).legal_ref.title == "CGI art. 278"
    assert rate_row(date(2027, 1, 1)).legal_ref.title == "CIBS art. L213-151"
    assert rate_on(date(2031, 6, 1)) == Decimal("0.2")
    with pytest.raises(VatRateMissingError):
        rate_on(date(2013, 12, 31))
    with pytest.raises(VatRateMissingError):
        rate_on(date(2026, 11, 10), territory="FR-971")
    pack = vat_pack()
    for row in pack.rates:
        assert row.legal_ref.quote and "20 %" in row.legal_ref.quote
    texts = {t.title for r in pack.references for t in r.texts}
    assert {"CGI art. 256 I", "CGI art. 269 2 c", "CGI art. 289 I 1 a", "CIBS art. L214-6"} <= texts


def test_the_review_tripwire_logic() -> None:
    pack = vat_pack()
    row = next(r for r in pack.rates if r.review is not None)
    assert row.review is not None
    if row.review.reviewed_on is None:
        assert reviews_due(date(2026, 11, 30)) == [] and texts_due(date(2026, 11, 30)) == []
        assert reviews_due(row.review.due_from) == [row]
        due = {t.title for t in texts_due(row.review.due_from)}
        # the texts the engine and the documents rely on from 2027, not only the rate
        assert {
            "CIBS art. L213-151",
            "CIBS art. L211-4",
            "CIBS art. L214-6",
            "CIBS art. L214-9",
            "CIBS art. L216-30 1°",
            "CIBS art. L216-25 al. 2",
            "CGI art. 269 2 c",
        } <= due
    assert row.review.due_from < row.valid_from, "reviewed before it applies"
    for text, applies, review in pack.texts():
        if applies is not None and applies > pack.read_on:
            assert review is not None and review.due_from < applies, text.title


def test_vat_pack_review_tripwire() -> None:
    """Fails CI from the review date until every 2027 text is re-read and marked reviewed."""
    due = texts_due(paris_date(datetime.now(UTC)))
    assert not due, (
        "VAT rule pack review due: re-read "
        + ", ".join(f"{t.title} ({t.url or t.note})" for t in due)
        + " on LibreJustice, record reviewed_on / reviewed_by on each in"
        " worker/rule_packs/vat/fr.yaml and copy the rate row's into public.vat_rate by a new"
        " migration"
    )


@settings(max_examples=500)
@given(ht=st.integers(0, 10**13), rate=rates)
def test_invoice_vat_is_within_half_a_cent(ht: int, rate: Decimal) -> None:
    vat = vat_of(ht, rate)
    exact = Fraction(ht) * Fraction(str(rate))
    assert abs(vat - exact) <= Fraction(1, 2)
    assert vat - exact != Fraction(-1, 2), "half-up: a half cent goes up"


@settings(max_examples=500)
@given(ht=st.integers(1, 10**11), rate=rates, cuts=st.lists(st.integers(0, 10**11), max_size=8))
def test_credit_note_vat_by_cumulative_difference(ht: int, rate: Decimal, cuts: list[int]) -> None:
    """Credit notes on one invoice, in any steps: each gives back ≥ 0, never more than the invoice's
    VAT in all, and exactly it once the invoice is fully credited."""
    points = sorted({c % (ht + 1) for c in cuts} | {0, ht})
    given_back = [credit_note_vat(ht, rate, a, b) for a, b in pairwise(points)]
    assert all(v >= 0 for v in given_back)
    assert sum(given_back) == vat_of(ht, rate)
    partial = points[len(points) // 2]
    assert credit_note_vat(ht, rate, 0, partial) <= vat_of(ht, rate)


@settings(max_examples=500)
@given(
    ttc=st.integers(1, 10**11),
    share=st.integers(0, 10_000),
    cuts=st.lists(st.integers(0, 10**11), max_size=8),
)
def test_vat_moved_on_settlement(ttc: int, share: int, cuts: list[int]) -> None:
    """VAT pending → due as a document is settled in parts: each move ≥ 0, the whole VAT once the
    whole TTC is settled, whatever the parts (§9.6)."""
    vat = ttc * share // 10_000
    points = sorted({c % (ttc + 1) for c in cuts} | {0, ttc})
    moved = [vat_moved(vat, ttc, a, b) for a, b in pairwise(points)]
    assert all(m >= 0 for m in moved)
    assert sum(moved) == vat


@given(n=st.integers(-(10**15), 10**15), d=st.integers(1, 10**6))
def test_div_half_up(n: int, d: int) -> None:
    q = div_half_up(n, d)
    exact = Fraction(n, d)
    assert abs(q - exact) <= Fraction(1, 2)
    if abs(q - exact) == Fraction(1, 2):
        assert abs(q) > abs(exact), "a half goes away from zero"


def test_refusals() -> None:
    with pytest.raises(ValueError, match="4 decimals"):
        scaled(Decimal("0.12345"))
    with pytest.raises(ValueError, match="4 decimals"):
        scaled(Decimal("1.5"))
    with pytest.raises(ValueError, match="not negative"):
        vat_of(-1, Decimal("0.2"))
    with pytest.raises(ValueError, match="within"):
        credit_note_vat(100, Decimal("0.2"), 50, 40)
    with pytest.raises(ValueError, match="within"):
        credit_note_vat(100, Decimal("0.2"), 0, 101)
    with pytest.raises(ValueError, match="within"):
        vat_moved(20, 120, 0, 121)
    with pytest.raises(ValueError, match="d > 0"):
        div_half_up(1, 0)
