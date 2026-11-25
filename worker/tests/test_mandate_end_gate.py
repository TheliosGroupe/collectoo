"""M2c-7d-1 (plan docs/design/m2c-7-plan.md §6.2.8; founder Q10; ADR-0014 « M2c-7d-1 »): the
allocation job's gate, the twin of `private.gate_assignments`, holds a payment booked on or after
the end of the client's mandate (`FileFacts.ended_on`: a death, a tutelle or a mandate end recorded
by the time the job reads the file) `client_mandate_ended` — so an end recorded after the payment
was assigned, before the job allocated it, still keeps it from allocation (and from commission). It
comes first, as in SQL: no release opens it (ops forward the payment or restore it to the payer)."""

from __future__ import annotations

from dataclasses import replace
from datetime import date

import pytest
from test_allocation_job import _file, _target

from collectoo_worker.jobs.allocation import gate

END = date(2026, 10, 15)
RELEASES = ("hold_blocks_allocation", "before_servicing_start", "credit_note_to_apply")


@pytest.mark.parametrize(
    ("booked", "reason"),
    [
        (date(2026, 10, 16), "client_mandate_ended"),
        (END, "client_mandate_ended"),
        (date(2026, 10, 14), None),
    ],
)
def test_a_payment_booked_on_or_after_the_end_is_held(booked: date, reason: str | None) -> None:
    f = replace(_file(holds=0), servicing_start=date(2026, 10, 1), ended_on=END)
    assert gate(_target(booked=booked), f) == reason


def test_it_comes_before_every_other_gate_and_no_release_opens_it() -> None:
    f = replace(_file(credit_note=True, status="closed_recalled"), ended_on=END)
    assert gate(_target(*RELEASES, booked=END), f) == "client_mandate_ended"
    assert gate(_target(*RELEASES, "client_mandate_ended", booked=END), f) == "client_mandate_ended"


def test_no_end_recorded_changes_nothing() -> None:
    assert gate(_target(), _file()) == "hold_blocks_allocation"
    assert replace(_file(), ended_on=None) == _file()
