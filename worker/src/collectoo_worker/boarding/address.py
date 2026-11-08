"""Postal address normalisation (M1-13): BAN (Base Adresse Nationale) adapter, cache, mock.

CI and tests use the mock. The BAN adapter uses the batch CSV endpoint of
api-adresse.data.gouv.fr. Results are cached in `private.address_cache` so a re-run or
another tape with the same addresses costs nothing.

Manual check against BAN (needs the network allowlist entry):
    uv run python -m collectoo_worker.boarding.address --sample 100 --provider ban
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import re
import time
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from typing import Any, Protocol

import httpx
import psycopg
from psycopg.types.json import Jsonb

BAN_CSV_URL = "https://api-adresse.data.gouv.fr/search/csv/"
CHUNK = 5000
RETRIES = 4


@dataclass(frozen=True)
class AddressResult:
    line: str
    postcode: str | None
    label: str | None
    city: str | None
    citycode: str | None
    score: float

    @property
    def normalised(self) -> bool:
        return self.label is not None and self.score >= 0.6


class Normaliser(Protocol):
    name: str

    def normalise(self, queries: Sequence[tuple[str, str | None]]) -> list[AddressResult]: ...


class MockNormaliser:
    """Deterministic stand-in: tidies the line; 'confident' only with a valid postcode."""

    name = "mock"

    def normalise(self, queries: Sequence[tuple[str, str | None]]) -> list[AddressResult]:
        out = []
        for line, postcode in queries:
            ok = bool(postcode and re.fullmatch(r"\d{5}", postcode))
            tidy = re.sub(r"\s+", " ", line).strip().title()
            out.append(
                AddressResult(
                    line,
                    postcode,
                    f"{tidy} {postcode}" if ok else None,
                    None,
                    None,
                    0.9 if ok else 0.0,
                )
            )
        return out


class BanNormaliser:
    name = "ban"

    def __init__(self, client: httpx.Client | None = None) -> None:
        self._client = client or httpx.Client(timeout=120)

    def normalise(self, queries: Sequence[tuple[str, str | None]]) -> list[AddressResult]:
        out: list[AddressResult] = []
        for start in range(0, len(queries), CHUNK):
            out += self._chunk(queries[start : start + CHUNK])
        return out

    def _chunk(self, queries: Sequence[tuple[str, str | None]]) -> list[AddressResult]:
        buf = io.StringIO()
        writer = csv.writer(buf)
        writer.writerow(["adresse", "postcode"])
        writer.writerows([(line, postcode or "") for line, postcode in queries])
        body = buf.getvalue().encode()
        for attempt in range(RETRIES):
            try:
                resp = self._client.post(
                    BAN_CSV_URL,
                    files={"data": ("addresses.csv", body, "text/csv")},
                    data={"columns": "adresse", "postcode": "postcode"},
                )
                resp.raise_for_status()
                break
            except (httpx.TransportError, httpx.HTTPStatusError):
                if attempt == RETRIES - 1:
                    raise
                time.sleep(2**attempt)
        rows = list(csv.DictReader(io.StringIO(resp.text)))
        results = []
        for (line, postcode), row in zip(queries, rows, strict=True):
            score = float(row.get("result_score") or 0.0)
            results.append(
                AddressResult(
                    line,
                    postcode,
                    row.get("result_label") or None,
                    row.get("result_city") or None,
                    row.get("result_citycode") or None,
                    round(score, 4),
                )
            )
        return results


def _key(normaliser: str, line: str, postcode: str | None) -> str:
    return hashlib.sha256(
        f"{normaliser}|{line.strip().lower()}|{postcode or ''}".encode()
    ).hexdigest()


def normalise_cached(
    normaliser: Normaliser,
    queries: Sequence[tuple[str, str | None]],
    conn: psycopg.Connection[Any] | None,
) -> list[AddressResult]:
    unique = list(dict.fromkeys(queries))
    known: dict[tuple[str, str | None], AddressResult] = {}
    if conn is not None and unique:
        keys = {_key(normaliser.name, line, pc): (line, pc) for line, pc in unique}
        for key, result in conn.execute(
            "select query_hash, result from private.address_cache where query_hash = any(%s)",
            (list(keys),),
        ).fetchall():
            known[keys[key]] = AddressResult(**result)
    missing = [q for q in unique if q not in known]
    if missing:
        fresh = normaliser.normalise(missing)
        for q, r in zip(missing, fresh, strict=True):
            known[q] = r
        if conn is not None:
            with conn.cursor() as cur:
                cur.executemany(
                    """insert into private.address_cache (query_hash, provider, result)
                       values (%s, %s, %s) on conflict (query_hash) do nothing""",
                    [
                        (_key(normaliser.name, q[0], q[1]), normaliser.name, Jsonb(asdict(r)))
                        for q, r in zip(missing, fresh, strict=True)
                    ],
                )
    return [known[q] for q in queries]


# Public places (town halls, squares): real addresses, no personal data. The manual check
# writes each one in 5 messy ways, as client files do.
REFERENCE_ADDRESSES = [
    ("12 rue de la Paix", "75002"),
    ("8 boulevard du Port", "80000"),
    ("1 rue de Rivoli", "75001"),
    ("20 avenue de Ségur", "75007"),
    ("10 place Bellecour", "69002"),
    ("1 place du Capitole", "31000"),
    ("5 place Stanislas", "54000"),
    ("1 place Kléber", "67000"),
    ("1 quai du Port", "13002"),
    ("2 rue de la République", "69002"),
    ("1 avenue Jean Médecin", "06000"),
    ("6 rue Saint-Ferréol", "13001"),
    ("10 rue Sainte-Catherine", "33000"),
    ("1 place de la Bourse", "33000"),
    ("1 rue de la Liberté", "21000"),
    ("1 boulevard de la Croisette", "06400"),
    ("3 place de la Concorde", "75008"),
    ("1 place de la Mairie", "35000"),
    ("4 place du Général de Gaulle", "59800"),
    ("2 place Saint-Pierre", "44000"),
]


def messy_variants(line: str) -> list[str]:
    import unicodedata  # noqa: PLC0415

    plain = unicodedata.normalize("NFKD", line).encode("ascii", "ignore").decode()
    abbreviated = (
        line.replace("boulevard", "bd")
        .replace("avenue", "av.")
        .replace("place", "pl.")
        .replace("rue", "r.")
    )
    return [line, line.lower(), plain.upper(), abbreviated, plain.replace(" ", "  ") + " "]


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - manual check
    parser = argparse.ArgumentParser(prog="address")
    parser.add_argument("--sample", type=int, default=100)
    parser.add_argument("--provider", choices=["ban", "mock"], default="mock")
    args = parser.parse_args(argv)
    queries = [(v, pc) for line, pc in REFERENCE_ADDRESSES for v in messy_variants(line)][
        : args.sample
    ]
    normaliser: Normaliser = BanNormaliser() if args.provider == "ban" else MockNormaliser()
    results = normaliser.normalise(queries)
    ok = sum(r.normalised for r in results)
    print(f"{args.provider}: {ok}/{len(results)} normalised (score >= 0.6)")
    for r in results:
        if not r.normalised:
            print(f"  not normalised: {r.line!r}, {r.postcode} (score {r.score})")
    for r in results[:5]:
        print(f"  {r.line!r}, {r.postcode} -> {r.label} (score {r.score})")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
