"""Synthetic civil and commercial claim files, as SMB clients export them from their tools.

Three "accounting export" dialects, realistic French data, and deliberately injected defects.
Each file comes with a manifest listing every defect (row number + type): the test oracle for
the M1 boarding pipeline (profiling, transformations, validation, data-quality report).
"""

from __future__ import annotations

import csv
import datetime as dt
import json
import random
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Literal

from faker import Faker

from collectoo_worker.synth.ids import iban_fr, siren, siret

Kind = Literal["b2b_invoice", "b2c_invoice", "rent"]
DialectName = Literal["fr_semicolon", "en_comma", "tab_dotted"]
KINDS: tuple[Kind, ...] = ("b2b_invoice", "b2c_invoice", "rent")
DIALECTS: tuple[DialectName, ...] = ("fr_semicolon", "en_comma", "tab_dotted")

DEFECTS = (
    "missing_contact",  # no email and no phone
    "duplicate_row",  # exact copy of the previous row
    "invalid_siren",  # bad Luhn key (B2B only)
    "impossible_date",  # e.g. 31/02
    "mixed_date_format",  # ISO date inside a French-format file
    "negative_amount",  # negative amount on an invoice (not a credit note)
    "overpaid",  # amount paid greater than the amount due
)


@dataclass(frozen=True)
class Dialect:
    delimiter: str
    date_format: str
    decimal_comma: bool
    thousands: str
    headers: dict[str, str]


_HEADERS_FR = {
    "client_ref": "Compte client",
    "debtor_name": "Raison sociale / Nom",
    "first_name": "Prénom",
    "siren": "SIREN",
    "siret": "SIRET",
    "email": "Email",
    "phone": "Téléphone",
    "address": "Adresse",
    "postcode": "Code postal",
    "city": "Ville",
    "iban": "IBAN",
    "document_type": "Type",
    "document_ref": "N° pièce",
    "issue_date": "Date pièce",
    "due_date": "Échéance",
    "amount": "Montant TTC",
    "amount_paid": "Montant réglé",
    "currency": "Devise",
    "lease_ref": "Bail",
    "period": "Période",
}

DIALECT_SPECS: dict[DialectName, Dialect] = {
    "fr_semicolon": Dialect(";", "%d/%m/%Y", True, "", _HEADERS_FR),
    "en_comma": Dialect(",", "%Y-%m-%d", False, "", {k: k for k in _HEADERS_FR}),
    "tab_dotted": Dialect(
        "\t", "%d.%m.%Y", True, "\u00a0", {k: v.upper() for k, v in _HEADERS_FR.items()}
    ),
}

COLUMNS: dict[Kind, list[str]] = {
    "b2b_invoice": [
        "client_ref", "debtor_name", "siren", "siret", "email", "phone", "address", "postcode",
        "city", "iban", "document_type", "document_ref", "issue_date", "due_date", "amount",
        "amount_paid", "currency",
    ],
    "b2c_invoice": [
        "client_ref", "debtor_name", "first_name", "email", "phone", "address", "postcode", "city",
        "document_type", "document_ref", "issue_date", "due_date", "amount", "amount_paid",
        "currency",
    ],
    "rent": [
        "lease_ref", "debtor_name", "first_name", "email", "phone", "address", "postcode", "city",
        "period", "due_date", "amount", "amount_paid", "currency",
    ],
}  # fmt: skip


def _amount(value: Decimal, d: Dialect) -> str:
    q = value.quantize(Decimal("0.01"))
    sign = "-" if q < 0 else ""
    units, cents = f"{abs(q):.2f}".split(".")
    if d.thousands:
        units = f"{int(units):,}".replace(",", d.thousands)
    return f"{sign}{units}{',' if d.decimal_comma else '.'}{cents}"


def _record(
    kind: Kind, fake: Faker, rng: random.Random, n: int, today: dt.date
) -> dict[str, object]:
    issue = today - dt.timedelta(days=rng.randint(45, 400))
    due = issue + dt.timedelta(days=rng.choice([30, 45, 60]))
    amount = Decimal(rng.randint(8_000, 1_500_000 if kind == "b2b_invoice" else 60_000)) / 100
    paid = (amount * Decimal(rng.choice([0, 0, 0, 20, 50]))) / 100
    rec: dict[str, object] = {
        "email": fake.email() if rng.random() < 0.8 else "",
        "phone": fake.phone_number() if rng.random() < 0.85 else "",
        "address": fake.street_address(),
        "postcode": fake.postcode(),
        "city": fake.city(),
        "due_date": due,
        "amount": amount,
        "amount_paid": paid,
        "currency": "EUR",
    }
    if kind == "b2b_invoice":
        sir = siren(rng)
        credit_note = rng.random() < 0.05
        rec.update(
            client_ref=f"C{rng.randint(1000, 9999)}",
            debtor_name=fake.company(),
            siren=sir,
            siret=siret(rng, sir),
            iban=iban_fr(rng) if rng.random() < 0.5 else "",
            document_type="AVOIR" if credit_note else "FACTURE",
            document_ref=f"F{today.year}-{n:05d}",
            issue_date=issue,
            amount=-amount if credit_note else amount,
            amount_paid=Decimal(0) if credit_note else paid,
        )
    elif kind == "b2c_invoice":
        rec.update(
            client_ref=f"ABO-{rng.randint(100000, 999999)}",
            debtor_name=fake.last_name().upper(),
            first_name=fake.first_name(),
            document_type="FACTURE",
            document_ref=f"FAC-{n:06d}",
            issue_date=issue,
        )
    else:
        month = today.replace(day=1) - dt.timedelta(days=30 * rng.randint(1, 12))
        rec.update(
            lease_ref=f"BAIL-{rng.randint(100, 999)}",
            debtor_name=fake.last_name().upper(),
            first_name=fake.first_name(),
            period=month.strftime("%m/%Y"),
            due_date=month.replace(day=5),
            amount=Decimal(rng.randint(45_000, 180_000)) / 100,
        )
    return rec


def _inject(kind: Kind, rec: dict[str, object], defect: str, rng: random.Random) -> None:
    match defect:
        case "missing_contact":
            rec["email"], rec["phone"] = "", ""
        case "invalid_siren":
            s = str(rec["siren"])
            rec["siren"] = s[:-1] + str((int(s[-1]) + 1) % 10)
        case "impossible_date":
            rec["due_date"] = ("IMPOSSIBLE", rec["due_date"])
        case "mixed_date_format":
            rec["due_date"] = ("ISO", rec["due_date"])
        case "negative_amount":
            rec["amount"] = -abs(Decimal(str(rec["amount"])))
            if "document_type" in rec:
                rec["document_type"] = "FACTURE"
        case "overpaid":
            rec["amount_paid"] = Decimal(str(rec["amount"])) + Decimal(rng.randint(100, 5000)) / 100


def _render(rec: dict[str, object], cols: list[str], d: Dialect) -> list[str]:
    out = []
    for c in cols:
        v = rec.get(c, "")
        if isinstance(v, tuple) and v[0] == "ISO":  # mixed_date_format
            out.append(v[1].isoformat())
        elif isinstance(v, tuple):  # impossible_date: 31 February, in the file's own format
            fmt = d.date_format.replace("%d", "31").replace("%m", "02")
            out.append(fmt.replace("%Y", str(v[1].year)))
        elif isinstance(v, dt.date):
            out.append(v.strftime(d.date_format))
        elif isinstance(v, Decimal):
            out.append(_amount(v, d))
        else:
            out.append(str(v))
    return out


def generate_civil(  # noqa: PLR0913 - explicit generation parameters read best here
    kind: Kind,
    dialect: DialectName,
    rows: int,
    seed: int,
    *,
    defect_rate: float = 0.1,
    today: dt.date = dt.date(2026, 10, 15),
) -> tuple[list[list[str]], dict[str, object]]:
    """Returns (header + data rows, manifest). Row numbers in the manifest are 1-based data rows."""
    rng = random.Random(seed)
    fake = Faker("fr_FR")
    fake.seed_instance(seed)
    d = DIALECT_SPECS[dialect]
    cols = COLUMNS[kind]
    allowed = [x for x in DEFECTS if x != "invalid_siren" or kind == "b2b_invoice"]
    if dialect == "en_comma":
        allowed.remove("mixed_date_format")  # ISO is the dialect's own format
    data: list[list[str]] = []
    defects: list[dict[str, object]] = []
    for n in range(1, rows + 1):
        rec = _record(kind, fake, rng, n, today)
        defect = rng.choice(allowed) if rng.random() < defect_rate else None
        if defect == "duplicate_row" and data:
            data.append(list(data[-1]))
            defects.append({"row": len(data), "type": defect, "duplicate_of": len(data) - 1})
            continue
        if defect and defect != "duplicate_row":
            _inject(kind, rec, defect, rng)
            defects.append({"row": len(data) + 1, "type": defect})
        data.append(_render(rec, cols, d))
    manifest: dict[str, object] = {
        "kind": kind,
        "dialect": dialect,
        "seed": seed,
        "rows": len(data),
        "delimiter": d.delimiter,
        "date_format": d.date_format,
        "decimal_comma": d.decimal_comma,
        "columns": {c: d.headers[c] for c in cols},
        "defects": defects,
    }
    return [[d.headers[c] for c in cols], *data], manifest


def write_civil(kind: Kind, dialect: DialectName, rows: int, seed: int, out_dir: Path) -> Path:
    table, manifest = generate_civil(kind, dialect, rows, seed)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{kind}_{dialect}.csv"
    d = DIALECT_SPECS[dialect]
    with path.open(
        "w", newline="", encoding="utf-8-sig" if dialect == "fr_semicolon" else "utf-8"
    ) as fh:
        csv.writer(fh, delimiter=d.delimiter).writerows(table)
    manifest["file"] = path.name
    path.with_suffix(".manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False)
    )
    return path
