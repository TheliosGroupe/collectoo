"""M2c-7d-1 (plan docs/design/m2c-7-plan.md §6.2.8; founder Q10; ADR-0014 « M2c-7d-1 »): a payment
received after the end of the client's mandate is forwarded with the reason `mandate_ended`. No
schedule lists it (`basis.forwards` has no such key: the mandate ended), so it never earns
commission whatever the schedule says of the other forwards; the statement names it."""

from __future__ import annotations

from dataclasses import replace
from datetime import date
from decimal import Decimal

from test_commission import BASIS, TAU, _file, _line, _one_version

from collectoo_worker.remittance.commission import FORWARD_REASONS, LineKind, compute
from collectoo_worker.remittance.statement import nature
from collectoo_worker.remittance.terms import CommissionSchedule

D0 = date(2026, 11, 2)


def test_a_payment_received_after_the_end_earns_nothing_whatever_the_schedule() -> None:
    every_forward = {
        "file_recalled": True,
        "before_servicing_start": True,
        "client_ratification": True,
    }
    schedule = CommissionSchedule.model_validate(
        {
            "schema": "commission-1",
            "basis": {**BASIS, "forwards": every_forward},
            "rules": [
                {
                    "id": "r",
                    "tier_key": "k",
                    "label_fr": "R",
                    "match": {},
                    "rate": {"kind": "flat", "rate": "0.1"},
                }
            ],
        }
    )
    forward = replace(_line(1, 10_000, D0), kind=LineKind.FORWARD, basis={})
    earned = compute(
        [replace(forward, forward_reason="file_recalled")],
        {"F": _file()},
        _one_version(schedule),
        {},
        TAU,
    )
    assert earned.lines[0].commission_minor == 1_000  # the schedule does price the other forwards
    after_end = compute(
        [replace(forward, forward_reason="mandate_ended")],
        {"F": _file()},
        _one_version(schedule),
        {},
        TAU,
    )
    assert after_end.lines[0].commission_minor == 0
    assert "mandate_ended" not in FORWARD_REASONS
    assert Decimal("0") == Decimal(after_end.lines[0].commission_minor)


def test_the_statement_names_a_payment_received_after_the_end() -> None:
    assert nature("forward", "mandate_ended", None) == (
        "Reversement sans imputation (reçu après la fin du mandat)"
    )
    # the other reasons keep their words
    assert (
        nature("forward", "file_recalled", None) == "Reversement sans imputation (dossier rappelé)"
    )
