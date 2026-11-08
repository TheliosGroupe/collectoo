"""`synth` command: synthetic tapes, civil-claim files and the dev seed.

uv run synth eba --rows 1000 --seed 1 --out ../tmp/synth/eba
uv run synth civil --kind b2b_invoice --dialect fr_semicolon --rows 500 --seed 1 --out ../tmp/synth
uv run synth civil-all --rows 200 --seed 1 --out ../tmp/synth
uv run synth seed-sql > ../supabase/seed.sql
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

from collectoo_worker.synth.civil import DIALECTS, KINDS, write_civil
from collectoo_worker.synth.eba import generate_eba, write_tape
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
    else:
        sys.stdout.write(seed_sql(args.seed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
