"""The statement's CSV (design §10): UTF-8 with a BOM, `;`, CRLF, fixed French headers, one row per
line in the payload's order, ISO dates (AAAA-MM-JJ), every amount twice — « 1 234,56 » (no-break
space between thousands, decimal comma, no currency sign) and in integer minor units. Bytes =
f(payload): the same payload always gives the same file (golden: tests/test_statement_docs.py).

Columns (`statement.CSV_HEADER`): releve;date_releve;mandat;portefeuille;dossier;debiteur;piece;
composante;nature;date_encaissement;date_imputation;date_limite_reversement;montant;
montant_centimes;regle;taux;base_commission_centimes;commission_ht;commission_ht_centimes;facture;
quittance;hors_delai — the design's list, plus `hors_delai` (« oui — cause » for a line paid after
its latest execution date, §10.2 « hors délai with its cause »: a category the data supports, never
the approver's free text, review legal#6).

Spreadsheet formulas (review security#0): a text cell whose first character is one of `= + - @`,
TAB or CR — a debtor's name or a file reference from a boarded tape — is written with a leading
apostrophe, so a spreadsheet shows it as text instead of evaluating it. The text columns are
`TEXT_COLUMNS`; amounts, cents, rates and dates are never altered (a negative amount stays
« -12,34 », numeric).
"""

from __future__ import annotations

import hashlib
import io
from collections.abc import Mapping
from typing import Any

from collectoo_worker.payments.receipts import NBSP
from collectoo_worker.remittance.statement import CSV_HEADER, line_records

BOM = "﻿"


def csv_amount(minor: int, exponent: int) -> str:
    """« 1 234,56 », « -0,01 »: integer minor units, French grouping (U+00A0) and decimal comma."""
    units, fraction = divmod(abs(minor), 10**exponent)
    text = f"{units:,}".replace(",", NBSP)
    if exponent:
        text += f",{fraction:0{exponent}d}"
    return ("-" if minor < 0 else "") + text


FORMULA_START = frozenset("=+-@\t\r")
# the columns holding text (boarded, staff-entered or worded): neutralised; every other column is an
# amount, a rate or an ISO date and is written as is
TEXT_COLUMNS = frozenset(
    {
        "releve",
        "mandat",
        "portefeuille",
        "dossier",
        "debiteur",
        "piece",
        "composante",
        "nature",
        "regle",
        "facture",
        "quittance",
        "hors_delai",
    }
)
_TEXT_AT = tuple(name in TEXT_COLUMNS for name in CSV_HEADER)


def neutralise(value: str) -> str:
    """A text cell a spreadsheet would read as a formula, prefixed with an apostrophe."""
    return "'" + value if value[:1] in FORMULA_START else value


def _cell(value: str, text: bool = False) -> str:
    """A field (a text one neutralised first), quoted when it holds the separator, a quote or a
    line break (RFC 4180)."""
    if text:
        value = neutralise(value)
    if any(ch in value for ch in ';"\r\n'):
        return '"' + value.replace('"', '""') + '"'
    return value


def render_statement_csv(payload: Mapping[str, Any]) -> bytes:
    exponent = int(payload["exponent"])
    number = str(payload["number"])
    issued = str(payload["issue_date"])
    out = io.StringIO(newline="")
    out.write(BOM)
    out.write(";".join(CSV_HEADER) + "\r\n")
    for ln in line_records(payload):
        row = (
            number,
            issued,
            ln.mandate,
            ln.portfolio,
            ln.file,
            ln.debtor,
            ln.items,
            ln.components,
            ln.nature,
            ln.encaissement_date,
            ln.effective_date,
            ln.deadline,
            csv_amount(ln.amount_minor, exponent),
            str(ln.amount_minor),
            ln.rules,
            ln.rates,
            str(ln.basis_minor),
            csv_amount(ln.commission_minor, exponent),
            str(ln.commission_minor),
            ln.invoice,
            ln.receipt,
            ln.late,
        )
        out.write(";".join(_cell(c, t) for c, t in zip(row, _TEXT_AT, strict=True)) + "\r\n")
    return out.getvalue().encode("utf-8")


def csv_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
