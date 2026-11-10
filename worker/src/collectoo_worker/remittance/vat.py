"""VAT on the commission (design §3, §8.4, §9.6; rule pack `vat/fr`; ADR-0014 M2c-3).

Exact integer arithmetic on minor units; one rounding, half-up to the cent, where the design says:
* an invoice's VAT = R(HT x rate), per invoice and rate (242 nonies A 11°);
* a credit note's VAT on a corrected invoice, by cumulative difference:
  R(credited HT after x rate) - R(credited HT before x rate) — never more than the invoice's VAT,
  exactly it on a full credit (§8.4 step 5);
* VAT moving from pending (44574) to due (44571) as a document is settled: R(VAT x settled / TTC) -
  what moved before — the last settlement moves the rest (§9.6).
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from collectoo_worker.remittance.packs import LegalRef, VatPack, VatRateRow, vat_pack

RATE_SCALE = 10_000  # rates have at most 4 decimals (numeric(6,4))


class VatRateMissingError(LookupError):
    """No VAT row covers the day (SQL twin: private.vat_rate_on raises 22023)."""


def rate_row(
    day: date, code: str = "standard", territory: str = "FR-metro", pack: VatPack | None = None
) -> VatRateRow:
    pack = pack or vat_pack()
    for row in pack.rates:
        if row.code == code and row.territory == territory and row.covers(day):
            return row
    raise VatRateMissingError(f"vat rate: no {code} rate for {territory} on {day.isoformat()}")


def rate_on(day: date, code: str = "standard", territory: str = "FR-metro") -> Decimal:
    return rate_row(day, code, territory).rate_decimal


def scaled(rate: Decimal) -> int:
    """A rate as an exact integer over RATE_SCALE ("0.2" → 2000); refused beyond 4 decimals."""
    n = rate * RATE_SCALE
    if n != n.to_integral_value() or not Decimal(0) <= rate <= Decimal(1):
        raise ValueError(f"a rate in [0, 1] with at most 4 decimals, not {rate}")
    return int(n)


def div_half_up(n: int, d: int) -> int:
    """n / d rounded half-up (away from zero for a negative n: symmetric), d > 0."""
    if d <= 0:
        raise ValueError("d > 0")
    q = (2 * abs(n) + d) // (2 * d)
    return q if n >= 0 else -q


def vat_of(ht_minor: int, rate: Decimal) -> int:
    """R(HT x rate): the VAT of an invoice (HT ≥ 0)."""
    if ht_minor < 0:
        raise ValueError("an invoice's HT is not negative")
    return div_half_up(ht_minor * scaled(rate), RATE_SCALE)


def credit_note_vat(
    invoice_ht: int, rate: Decimal, credited_before: int, credited_after: int
) -> int:
    """The VAT a credit note gives back on one corrected invoice (positive magnitude), by cumulative
    difference."""
    if not 0 <= credited_before <= credited_after <= invoice_ht:
        raise ValueError("credited HT grows within the invoice's HT")
    return vat_of(credited_after, rate) - vat_of(credited_before, rate)


def vat_moved(vat: int, ttc: int, settled_before: int, settled_after: int) -> int:
    """The VAT that becomes due when a document's settled part grows from `settled_before` to
    `settled_after` (magnitudes). Settling the whole TTC moves the whole VAT, whatever the steps."""
    if ttc <= 0 or not 0 <= vat <= ttc or not 0 <= settled_before <= settled_after <= ttc:
        raise ValueError("settled parts grow within the TTC")
    return div_half_up(vat * settled_after, ttc) - div_half_up(vat * settled_before, ttc)


def texts_due(today: date, pack: VatPack | None = None) -> list[LegalRef]:
    """Every text whose review is due and not recorded — the rate rows' and the exigibility,
    invoicing and credit-note texts of the 2027 recodification (the CI tripwire)."""
    pack = pack or vat_pack()
    return [
        text
        for text, _, review in pack.texts()
        if review is not None and review.reviewed_on is None and review.due_from <= today
    ]


def reviews_due(today: date, pack: VatPack | None = None) -> list[VatRateRow]:
    """Rows whose review is due and not recorded (the `vat_pack_review` alert of
    private.reference_data_alerts: the row stands for every text reviewed with it)."""
    pack = pack or vat_pack()
    return [
        r
        for r in pack.rates
        if r.review is not None and r.review.reviewed_on is None and r.review.due_from <= today
    ]
