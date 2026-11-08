"""`synth` command: synthetic tapes, civil-claim files, bank statements and the dev seed.

uv run synth eba --rows 1000 --seed 1 --out ../tmp/synth/eba
uv run synth civil --kind b2b_invoice --dialect fr_semicolon --rows 500 --seed 1 --out ../tmp/synth
uv run synth civil-all --rows 200 --seed 1 --out ../tmp/synth
uv run synth seed-sql > ../supabase/seed.sql
uv run synth camt053 --lines 500 --seed 1 --iban FR76... --overlap 2 --out ../tmp/synth/bank
"""

from __future__ import annotations

import argparse
import datetime as dt
import random
import sys
from pathlib import Path

from collectoo_worker.synth.camt053 import (
    balance_before,
    generate_entries,
    make_doc,
    write_statement,
)
from collectoo_worker.synth.civil import DIALECTS, KINDS, write_civil
from collectoo_worker.synth.eba import generate_eba, write_tape
from collectoo_worker.synth.ids import iban_fr
from collectoo_worker.synth.seed import seed_sql


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="synth", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    eba = sub.add_parser("eba", help="EU NPL template tape (CSV per table)")
    eba.add_argument("--rows", type=int, default=1000, help="number of loans")
    eba.add_argument("--seed", type=int, default=1)
    eba.add_argument("--cutoff", type=dt.date.fromisoformat, default=dt.date(2026, 9, 30))
    eba.add_argument("--out", type=Path, required=True)

    civil = sub.add_parser("civil", help="one civil/commercial claims file + defect manifest")
    civil.add_argument("--kind", choices=KINDS, required=True)
    civil.add_argument("--dialect", choices=DIALECTS, required=True)
    civil.add_argument("--rows", type=int, default=500)
    civil.add_argument("--seed", type=int, default=1)
    civil.add_argument("--out", type=Path, required=True)

    every = sub.add_parser("civil-all", help="every kind x dialect")
    every.add_argument("--rows", type=int, default=200)
    every.add_argument("--seed", type=int, default=1)
    every.add_argument("--out", type=Path, required=True)

    seed = sub.add_parser("seed-sql", help="print supabase/seed.sql")
    seed.add_argument("--seed", type=int, default=1)

    camt = sub.add_parser("camt053", help="bank statement of a client-funds account + manifest")
    camt.add_argument("--lines", type=int, default=1000, help="statement lines (as parsed)")
    camt.add_argument("--seed", type=int, default=1)
    camt.add_argument("--iban", help="the bank account's IBAN (default: a synthetic one)")
    camt.add_argument("--start", type=dt.date.fromisoformat, default=dt.date(2026, 10, 1))
    camt.add_argument("--days", type=int, default=5)
    camt.add_argument("--opening", type=int, default=0, help="opening balance, minor units")
    camt.add_argument("--version", choices=("02", "04", "06", "08"), default="02")
    camt.add_argument("--references", type=Path, help="RF references to pay, one per line")
    camt.add_argument("--overlap", type=int, default=0, help="2nd statement overlapping N days")
    camt.add_argument("--csv", action="store_true", help="the CSV export instead of camt.053")
    camt.add_argument("--out", type=Path, required=True)

    args = parser.parse_args(argv)
    if args.cmd == "eba":
        for path in write_tape(generate_eba(args.rows, args.seed, args.cutoff), args.out):
            print(path)
    elif args.cmd == "civil":
        print(write_civil(args.kind, args.dialect, args.rows, args.seed, args.out))
    elif args.cmd == "civil-all":
        for i, kind in enumerate(KINDS):
            for j, dialect in enumerate(DIALECTS):
                print(write_civil(kind, dialect, args.rows, args.seed * 100 + i * 10 + j, args.out))
    elif args.cmd == "camt053":
        for path in statements(args):
            print(path)
    else:
        sys.stdout.write(seed_sql(args.seed))
    return 0


def statements(args: argparse.Namespace) -> list[Path]:
    """One statement, or two that overlap by `--overlap` days (the second repeats those lines)."""
    iban = args.iban or iban_fr(random.Random(args.seed))
    refs = args.references.read_text("utf-8").split() if args.references else []
    span = args.days * 2 - args.overlap if args.overlap else args.days
    lines = args.lines * span // args.days
    entries = generate_entries(lines, seed=args.seed, start=args.start, days=span, references=refs)
    end = args.start + dt.timedelta(days=args.days - 1)
    first = make_doc(
        entries, iban=iban, from_date=args.start, to_date=end, opening_minor=args.opening
    )
    name = f"camt053-s{args.seed}"
    paths = write_statement(first, args.out, name, version=args.version, csv=args.csv)
    if args.overlap:
        start2 = end - dt.timedelta(days=args.overlap - 1)
        second = make_doc(
            entries,
            iban=iban,
            from_date=start2,
            to_date=start2 + dt.timedelta(days=args.days - 1),
            opening_minor=balance_before(entries, start2, args.opening),
            stmt_id="STMT-2",
            seq=2,
        )
        paths += write_statement(
            second, args.out, f"{name}-overlap", version=args.version, csv=args.csv
        )
    return paths


if __name__ == "__main__":
    raise SystemExit(main())
