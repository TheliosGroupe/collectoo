"""The worker never writes ledger tables directly: only through private.ledger_* functions.

Its login role owns the tables, so this static check is its only DML barrier short of triggers.
"""

import re
from pathlib import Path

SRC = Path(__file__).parents[1] / "src"
RAW = re.compile(
    r"\b(insert\s+into|update(\s+only)?|delete\s+from(\s+only)?|truncate(\s+table)?(\s+only)?|copy|merge\s+into)"
    r"\s+(public\.)?\"?ledger_(entry|posting|account)\b",
    re.IGNORECASE,
)
IDENTIFIER = re.compile(r"Identifier\([^)]*['\"]ledger_(entry|posting|account)['\"]")


def test_no_raw_dml_on_ledger_tables() -> None:
    offenders = []
    for path in SRC.rglob("*.py"):
        text = path.read_text(encoding="utf-8")  # whole file: SQL often spans lines
        for match in (*RAW.finditer(text), *IDENTIFIER.finditer(text)):
            line = text.count("\n", 0, match.start()) + 1
            offenders.append(f"{path.relative_to(SRC)}:{line}")
    assert offenders == []


def test_the_guard_catches_the_usual_forms() -> None:
    for sql in (
        "insert into ledger_posting values (1)",
        'insert into\n  public."ledger_entry" (id)',
        "copy public.ledger_posting from stdin",
        "update only public.ledger_entry set x = 1",
        "delete from ledger_account",
        "truncate table public.ledger_entry",
    ):
        assert RAW.search(sql), sql
