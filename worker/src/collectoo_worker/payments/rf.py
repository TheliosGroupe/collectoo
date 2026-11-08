"""RF creditor references (ISO 11649) and the ISO 7064 MOD 97-10 check they share with IBANs.

Twin of private.mod97 / rf_valid / rf_make / rf_normalise / iban_valid
(supabase/migrations/20261109090000_payments_ledger.sql). An integration test compares both on
random strings: they must give the same answer for every input.

An RF reference is "RF", two check digits (02 to 98) and a body of 1 to 21 characters among 0-9
and A-Z. It is valid when the string with its first four characters moved to the end, letters
written as two digits (A = 10 … Z = 35), is ≡ 1 (mod 97). Collectoo issues RF + 2 check digits +
12 random digits (RF + 14 digits), printed in groups of four.
"""

from __future__ import annotations

import re
import secrets

RF_RE = re.compile(r"RF(0[2-9]|[1-8][0-9]|9[0-8])[0-9A-Z]{1,21}")
ISSUED_RE = re.compile(r"RF[0-9]{14}")
BODY_RE = re.compile(r"[0-9A-Z]{1,21}")
IBAN_RE = re.compile(r"[A-Z]{2}(0[2-9]|[1-8][0-9]|9[0-8])[0-9A-Z]{11,30}")
ALNUM_RE = re.compile(r"[0-9A-Z]+")
WHITESPACE_RE = re.compile(r"[ \t\n\r\f\v]")
ASCII_UPPER = str.maketrans("abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
BODY_DIGITS = 12


def mod97(text: str) -> int:
    """Remainder mod 97 of an upper-case alphanumeric string, letters as two digits."""
    if not ALNUM_RE.fullmatch(text):
        raise ValueError(f"mod97 takes characters among 0-9 and A-Z, got {text!r}")
    return int("".join(str(int(c, 36)) for c in text)) % 97


def rf_valid(ref: str | None) -> bool:
    """True for a well-formed ISO 11649 reference (upper case, no spaces) whose check holds."""
    if ref is None or not RF_RE.fullmatch(ref):
        return False
    return mod97(ref[4:] + ref[:4]) == 1


def rf_make(body: str) -> str:
    """The reference for a body: check digits = 98 - (body + "RF00" mod 97)."""
    if not BODY_RE.fullmatch(body):
        raise ValueError("an RF reference body has 1 to 21 characters among 0-9 and A-Z")
    return f"RF{98 - mod97(body + 'RF00'):02d}{body}"


def random_body() -> str:
    """12 random digits (a reference says nothing about the size of a portfolio)."""
    return f"{secrets.randbelow(10**BODY_DIGITS):0{BODY_DIGITS}d}"


def rf_normalise(text: str) -> str:
    """What a person typed or a bank printed: ASCII spaces and line breaks removed, ASCII letters
    upper-cased; anything else is kept (and then fails validation), exactly as in SQL."""
    return WHITESPACE_RE.sub("", text).translate(ASCII_UPPER)


def rf_format(ref: str) -> str:
    """Groups of four, as printed on letters: RF18 5390 0754 7034."""
    return " ".join(ref[i : i + 4] for i in range(0, len(ref), 4))


# ISO 13616 IBAN length per country (SWIFT IBAN registry). Kept identical to the SQL
# private.iban_length and the TypeScript IBAN_LENGTHS (tests/test_iban_lengths.py checks it).
IBAN_LENGTHS: dict[str, int] = {
    "AD": 24,
    "AE": 23,
    "AL": 28,
    "AT": 20,
    "AZ": 28,
    "BA": 20,
    "BE": 16,
    "BG": 22,
    "BH": 22,
    "BI": 27,
    "BR": 29,
    "BY": 28,
    "CH": 21,
    "CR": 22,
    "CY": 28,
    "CZ": 24,
    "DE": 22,
    "DJ": 27,
    "DK": 18,
    "DO": 28,
    "EE": 20,
    "EG": 29,
    "ES": 24,
    "FI": 18,
    "FK": 18,
    "FO": 18,
    "FR": 27,
    "GB": 22,
    "GE": 22,
    "GI": 23,
    "GL": 18,
    "GR": 27,
    "GT": 28,
    "HN": 28,
    "HR": 21,
    "HU": 28,
    "IE": 22,
    "IL": 23,
    "IQ": 23,
    "IS": 26,
    "IT": 27,
    "JO": 30,
    "KW": 30,
    "KZ": 20,
    "LB": 28,
    "LC": 32,
    "LI": 21,
    "LT": 20,
    "LU": 20,
    "LV": 21,
    "LY": 25,
    "MC": 27,
    "MD": 24,
    "ME": 22,
    "MK": 19,
    "MN": 20,
    "MR": 27,
    "MT": 31,
    "MU": 30,
    "NI": 28,
    "NL": 18,
    "NO": 15,
    "OM": 23,
    "PK": 24,
    "PL": 28,
    "PS": 29,
    "PT": 25,
    "QA": 29,
    "RO": 24,
    "RS": 22,
    "RU": 33,
    "SA": 24,
    "SC": 31,
    "SD": 18,
    "SE": 24,
    "SI": 19,
    "SK": 24,
    "SM": 27,
    "SO": 23,
    "ST": 25,
    "SV": 28,
    "TL": 23,
    "TN": 24,
    "TR": 26,
    "UA": 29,
    "VA": 22,
    "VG": 24,
    "XK": 20,
    "YE": 30,
}


def iban_valid(iban: str | None) -> bool:
    """ISO 13616: a registry country, check digits 02-98, that country's exact length, and
    ≡ 1 (mod 97) once rearranged."""
    if iban is None or not IBAN_RE.fullmatch(iban):
        return False
    if IBAN_LENGTHS.get(iban[:2]) != len(iban):
        return False
    return mod97(iban[4:] + iban[:4]) == 1
