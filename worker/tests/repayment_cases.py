"""Synthetic payloads of the letter « Demande de remboursement d'avance » (M2c-7c-2; plan
docs/design/m2c-7-plan.md §5.3), as private.advance_repayment_payload freezes them: amounts as
text in minor units, dates ISO, no payer data. Design §7.2's Martin (synthetic) and one row per
origin the plan names."""

from __future__ import annotations

from typing import Any

ISSUER = {
    "name": "Collectoo",
    "siren": "732829320",
    "legal_form": "SAS",
    "share_capital_minor": "1000000",
    "currency": "EUR",
    "rcs_city": "Paris",
    "registered_office": {
        "line1": "1 rue de la Paix",
        "postcode": "75002",
        "city": "Paris",
        "country": "FR",
    },
    "in_liquidation": False,
    "entrepreneur_individuel": False,
}
RECIPIENT = {
    "name": "Martin SAS",
    "address": {
        "line1": "12 avenue des Tilleuls",
        "postcode": "69003",
        "city": "Lyon",
        "country": "FR",
    },
}
OWN_ACCOUNT = {"holder": "Collectoo", "iban": "FR7610107001011234567890129", "bic": None}


def _reversal(**origin: Any) -> dict[str, Any]:
    """A remitted collection taken back after its payout's debit (« Désimputer », the default)."""
    base: dict[str, Any] = {
        "collected_on": "2026-10-12",
        "file_ref": "F-103",
        "run_number": "RV-2026-000001",
        "paid_how": "paid",
        "paid_on": "2026-11-03",
        "paid_run_number": "RV-2026-000001",
        "returned_via": None,
        "reversal": "bank_return",
        "reversed_on": "2026-11-12",
        "returned_minor": None,
        "reversed_minor": "200000",
        "in_flight": False,
    }
    return base | origin


def row(  # noqa: PLR0913 - one row's facts, by keyword
    origin: dict[str, Any],
    *,
    cause: str = "remitted_reversal",
    amount: str = "200000",
    repaid: str = "0",
    open_minor: str | None = None,
    mandate: str | None = "MAND-MARTIN-2026",
    recorded_on: str = "2026-11-20",
    advance_id: str = "00000000-0000-4000-8000-000000000001",
) -> dict[str, Any]:
    return {
        "advance_id": advance_id,
        "recorded_on": recorded_on,
        "mandate": mandate,
        "cause": cause,
        "amount_minor": amount,
        "repaid_minor": repaid,
        "open_minor": open_minor if open_minor is not None else str(int(amount) - int(repaid)),
        "origin": origin,
    }


def request_payload(
    rows: list[dict[str, Any]] | None = None, number: str = "DRA-2026-000001"
) -> dict[str, Any]:
    rs = rows if rows is not None else [row(_reversal())]
    return {
        "template": "demande-remboursement-avance-fr-1",
        "number": number,
        "issue_date": "2026-11-20",
        "currency": "EUR",
        "issuer": ISSUER,
        "recipient": RECIPIENT,
        "own_account": OWN_ACCOUNT,
        "total_minor": str(sum(int(r["open_minor"]) for r in rs)),
        "rows": rs,
    }


def reversal(**origin: Any) -> dict[str, Any]:
    return _reversal(**origin)


def every_origin_payload() -> dict[str, Any]:
    """One row per origin of plan §5.3 (a multi-mandate request): each reversal's kind after the
    payout's debit and while its run was in flight (before the payout's bank date, and after it),
    a partial bank return, each `paid_how`, an overrun, a double payout with and without its run,
    a forward on no file."""
    rows = [
        row(reversal(), advance_id="00000000-0000-4000-8000-000000000001"),
        row(
            reversal(reversal="unallocated", reversed_on="2026-11-13"),
            amount="15000",
            advance_id="00000000-0000-4000-8000-000000000002",
        ),
        row(
            reversal(returned_minor="9000", reversed_minor="15000", reversed_on="2026-11-14"),
            amount="15000",
            repaid="5000",
            advance_id="00000000-0000-4000-8000-000000000003",
        ),
        row(
            reversal(in_flight=True, reversed_on="2026-11-01", paid_on="2026-11-03"),
            amount="12000",
            advance_id="00000000-0000-4000-8000-000000000004",
        ),
        row(
            reversal(in_flight=True, reversal="unallocated", reversed_on="2026-11-02"),
            amount="11000",
            advance_id="00000000-0000-4000-8000-000000000005",
        ),
        # (review round 1, TUI-1) recorded while the run was in flight, but the bank had paid the
        # day before (its statement imported after the « Désimputer »): the payment first
        row(
            reversal(in_flight=True, reversal="unallocated", reversed_on="2026-11-04"),
            amount="4000",
            advance_id="00000000-0000-4000-8000-000000000015",
        ),
        row(
            reversal(paid_on="2026-11-18", paid_run_number="RV-2026-000004", returned_via="run"),
            amount="10000",
            advance_id="00000000-0000-4000-8000-000000000006",
        ),
        row(
            reversal(
                paid_on="2026-11-18", paid_run_number="RV-2026-000005", returned_via="unplanned"
            ),
            amount="9000",
            advance_id="00000000-0000-4000-8000-000000000007",
        ),
        row(
            reversal(paid_how="unplanned", paid_on="2026-11-06", paid_run_number=None),
            amount="8000",
            advance_id="00000000-0000-4000-8000-000000000008",
        ),
        row(
            reversal(paid_how="set_off", paid_on="2026-11-04", reversal="unallocated"),
            amount="7000",
            advance_id="00000000-0000-4000-8000-000000000009",
        ),
        row(
            reversal(paid_how="netted", paid_on="2026-11-05", reversal="unallocated"),
            amount="6000",
            advance_id="00000000-0000-4000-8000-000000000010",
        ),
        row(
            reversal(file_ref=None, reversal="other", reversed_on="2026-11-15"),
            amount="5000",
            mandate=None,
            advance_id="00000000-0000-4000-8000-000000000011",
        ),
        row(
            {"run_number": "RV-2026-000002", "paid_on": "2026-11-07"},
            cause="payout_overrun",
            amount="3000",
            mandate=None,
            advance_id="00000000-0000-4000-8000-000000000012",
        ),
        row(
            {"executed_on": "2026-11-08", "run_number": "RV-2026-000003"},
            cause="double_payout",
            amount="2000",
            advance_id="00000000-0000-4000-8000-000000000013",
        ),
        row(
            {"executed_on": "2026-11-09", "run_number": None},
            cause="double_payout",
            amount="1000",
            mandate=None,
            advance_id="00000000-0000-4000-8000-000000000014",
        ),
    ]
    return request_payload(rows, number="DRA-2026-000002")
