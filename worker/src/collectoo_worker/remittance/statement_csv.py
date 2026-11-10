"""The statement's CSV (design §10): UTF-8 with a BOM, `;`, CRLF, fixed French headers, one row per
line in the payload's order, ISO dates (AAAA-MM-JJ), every amount twice — « 1 234,56 » (no-break
space between thousands, decimal comma, no currency sign) and in integer minor units. Bytes =
f(payload): the same payload always gives the same file (golden: tests/test_statement_docs.py).

Columns (`statement.CSV_HEADER`): releve;date_releve;mandat;portefeuille;dossier;debiteur;piece;
composante;nature;date_encaissement;date_imputation;date_limite_reversement;montant;
montant_centimes;regle;taux;base_commission_centimes;commission_ht;commission_ht_centimes;facture;
quittance;hors_delai — the design's list, plus `hors_delai` (« oui — motif » for a line approved
after its latest execution date, §10.2 « hors délai with its cause »).
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


def _cell(value: str) -> str:
    """A field quoted when it holds the separator, a quote or a line break (RFC 4180)."""
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
        out.write(";".join(_cell(c) for c in row) + "\r\n")
    return out.getvalue().encode("utf-8")


def csv_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
