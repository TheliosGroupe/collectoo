"""RF references and IBANs: SQL and Python give the same answer (M2-06, needs `make up`)."""

import random
import string

import psycopg
import pytest
from integration_helpers import DB

from collectoo_worker.payments.rf import iban_valid, mod97, rf_make, rf_normalise, rf_valid

pytestmark = pytest.mark.integration

ALNUM = string.digits + string.ascii_uppercase
NOISE = ALNUM + "rfab -\n\t.é" + chr(0xA0)  # a no-break space is kept, then refused


def _iban(rng: random.Random) -> str:
    country = rng.choice(["FR", "DE", "BE", "MC", "ES"])
    bban = "".join(rng.choice(ALNUM) for _ in range(rng.randint(11, 30)))
    return f"{country}{98 - mod97(bban + country + '00'):02d}{bban}"


def _mutate(rng: random.Random, s: str) -> str:
    i = rng.randrange(len(s))
    kind = rng.randrange(4)
    if kind == 0:
        return s[:i] + rng.choice(ALNUM) + s[i + 1 :]
    if kind == 1 and i < len(s) - 1:
        return s[:i] + s[i + 1] + s[i] + s[i + 2 :]
    if kind == 2:
        return s[:i] + " " + s[i:]
    return s.lower()


def _strings(n: int, seed: int) -> list[str]:
    rng = random.Random(seed)
    out: list[str] = []
    for i in range(n):
        body = "".join(rng.choice(ALNUM) for _ in range(rng.randint(1, 21)))
        kind = i % 5
        if kind == 0:
            out.append(rf_make(body))
        elif kind == 1:
            out.append(_mutate(rng, rf_make(body)))
        elif kind == 2:
            out.append("RF" + "".join(rng.choice(ALNUM) for _ in range(rng.randint(0, 26))))
        elif kind == 3:
            iban = _iban(rng)
            out.append(iban if rng.random() < 0.5 else _mutate(rng, iban))
        else:
            out.append("".join(rng.choice(NOISE) for _ in range(rng.randint(0, 30))))
    return out


def test_sql_and_python_agree_on_10k_random_strings() -> None:
    strings = _strings(10_000, seed=11)
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select x, private.rf_valid(x), private.rf_normalise(x), private.iban_valid(x)
               from unnest(%s::text[]) with ordinality as t (x, i) order by i""",
            (strings,),
        ).fetchall()
    assert [r[0] for r in rows] == strings
    for x, sql_rf, sql_norm, sql_iban in rows:
        assert sql_rf == rf_valid(x), x
        assert sql_norm == rf_normalise(x), x
        assert sql_iban == iban_valid(x), x
    valid = sum(1 for r in rows if r[1])
    assert 2000 <= valid <= 4000, valid  # a real mix of valid and invalid references
    assert sum(1 for r in rows if r[3]) >= 500


def test_sql_and_python_make_the_same_references() -> None:
    rng = random.Random(7)
    bodies = ["".join(rng.choice(ALNUM) for _ in range(rng.randint(1, 21))) for _ in range(2000)]
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select private.rf_make(b), private.mod97(b)
               from unnest(%s::text[]) with ordinality as t (b, i) order by i""",
            (bodies,),
        ).fetchall()
    assert [r[0] for r in rows] == [rf_make(b) for b in bodies]
    assert [r[1] for r in rows] == [mod97(b) for b in bodies]
