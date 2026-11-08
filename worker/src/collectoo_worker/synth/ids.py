"""French identifiers with valid check digits, for synthetic data and validator tests."""

from __future__ import annotations

import random
import string


def luhn_valid(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 1:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
    return total % 10 == 0


def _luhn_complete(prefix: str) -> str:
    for check in "0123456789":
        if luhn_valid(prefix + check):
            return prefix + check
    raise AssertionError("unreachable")  # pragma: no cover


def siren(rng: random.Random) -> str:
    """9-digit SIREN with a valid Luhn key."""
    return _luhn_complete(str(rng.randint(10_000_000, 99_999_999)))


def siret(rng: random.Random, siren_: str | None = None) -> str:
    """14-digit SIRET (SIREN + NIC) valid under Luhn."""
    base = (siren_ or siren(rng)) + f"{rng.randint(0, 9999):04d}"
    return _luhn_complete(base)


def _mod97(text: str) -> int:
    numeric = "".join(str(int(c, 36)) for c in text)
    return int(numeric) % 97


def iban_fr(rng: random.Random) -> str:
    """French IBAN with a valid RIB key and IBAN check digits."""
    bank, branch = f"{rng.randint(10000, 99999)}", f"{rng.randint(10000, 99999)}"
    account = "".join(rng.choice(string.digits) for _ in range(11))
    rib_key = 97 - (89 * int(bank) + 15 * int(branch) + 3 * int(account)) % 97
    bban = f"{bank}{branch}{account}{rib_key:02d}"
    check = 98 - _mod97(bban + "FR00")
    return f"FR{check:02d}{bban}"


def iban_valid(iban: str) -> bool:
    s = iban.replace(" ", "").upper()
    return len(s) >= 15 and _mod97(s[4:] + s[:4]) == 1
