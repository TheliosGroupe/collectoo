"""Money helpers. Amounts are integer minor units; rates and intermediate maths use Decimal.

Never use float for money (CLAUDE.md non-negotiables).
"""

from decimal import ROUND_HALF_UP, Decimal

CENT = Decimal("0.01")


def to_minor_units(amount: Decimal) -> int:
    """Round a major-unit Decimal amount half-up to the cent and return minor units."""
    if not amount.is_finite():
        raise ValueError(f"amount must be finite, got {amount}")
    return int((amount.quantize(CENT, rounding=ROUND_HALF_UP) * 100).to_integral_value())


def split_evenly(total_minor: int, parts: int) -> list[int]:
    """Split an amount into `parts` instalments that differ by at most one cent.

    The remainder goes to the first instalments, so the sum always equals the total.
    """
    if parts <= 0:
        raise ValueError("parts must be positive")
    if total_minor < 0:
        raise ValueError("total must be non-negative")
    base, remainder = divmod(total_minor, parts)
    return [base + 1 if i < remainder else base for i in range(parts)]
