"""The worker never writes ledger tables directly: only through private.ledger_* functions.

Its login role owns the tables, so this static check is its only DML barrier short of triggers.
"""

import re
from pathlib import Path

SRC = Path(__file__).parents[1] / "src"
RAW = re.compile(r"(insert\s+into|update|delete\s+from|truncate)\s+public\.ledger_", re.IGNORECASE)


def test_no_raw_dml_on_ledger_tables() -> None:
    offenders = [
        f"{path.relative_to(SRC)}:{n}"
        for path in SRC.rglob("*.py")
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
        if RAW.search(line)
    ]
    assert offenders == []
