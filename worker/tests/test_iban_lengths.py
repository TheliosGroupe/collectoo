"""The IBAN length table is the same in Python, SQL and TypeScript (ISO 13616 registry)."""

import re
from pathlib import Path

from collectoo_worker.payments.rf import IBAN_LENGTHS, iban_valid, mod97

ROOT = Path(__file__).resolve().parents[2]


def test_sql_table_matches() -> None:
    sql = (ROOT / "supabase/migrations/20261109090000_payments_ledger.sql").read_text()
    body = sql[sql.index("function private.iban_length") : sql.index("function private.iban_valid")]
    assert (
        dict((c, int(n)) for c, n in re.findall(r"\('([A-Z]{2})', (\d+)\)", body)) == IBAN_LENGTHS
    )


def test_typescript_table_matches() -> None:
    ts = (ROOT / "apps/web/src/lib/payments/iban.ts").read_text()
    body = ts[ts.index("IBAN_LENGTHS") : ts.index("};", ts.index("IBAN_LENGTHS"))]
    assert dict((c, int(n)) for c, n in re.findall(r"\b([A-Z]{2}): (\d+),", body)) == IBAN_LENGTHS


def _with_check(country: str, bban: str) -> str:
    check = 98 - mod97(bban + country + "00")
    return f"{country}{check:02d}{bban}"


def test_country_and_length_are_checked() -> None:
    fr = _with_check("FR", "30004000031234567890143")  # 27 characters
    assert iban_valid(fr)
    assert not iban_valid(_with_check("FR", "3000400003123456789014"))  # 26: one short
    assert not iban_valid(_with_check("ZZ", "12345678901"))  # not a registry country
    assert not iban_valid("RF18539007547034")  # an RF reference is not an IBAN
