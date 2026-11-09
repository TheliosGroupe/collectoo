"""The allocation job's gating (design §8.4, review fixes of M2b-4): the hold is reported before the
cut-off, and ops' decisions add up — a payment behind two gates passes both once ops released each,
whatever the order (it never alternates between them). Mirrors private.gate_assignments and the
backstop in private.post_allocations."""

from __future__ import annotations

from datetime import date
from itertools import permutations

import pytest

from collectoo_worker.jobs.allocation import FileFacts, Target, gate

START = date(2026, 10, 1)


def _target(*releases: str, booked: date = date(2026, 9, 28), currency: str = "EUR") -> Target:
    return Target(
        id="p",
        amount_minor=10_000,
        currency=currency,
        booking_date=booked,
        account_id="f",
        own_file=True,
        designation=(),
        releases=frozenset(releases),
    )


def _file(*, holds: int = 1, credit_note: bool = False, status: str = "in_collection") -> FileFacts:
    return FileFacts("f", status, "EUR", "commercial_b2b", "c", "pf", START, holds, credit_note)


def test_the_hold_is_reported_before_the_cut_off() -> None:
    # booked before the servicing start on a held file: held (the client is told), then the cut-off
    assert gate(_target(), _file()) == "hold_blocks_allocation"
    assert gate(_target("hold_blocks_allocation"), _file()) == "before_servicing_start"


def test_closed_and_other_currency_come_first() -> None:
    assert gate(_target(), _file(status="closed_recalled")) == "account_closed"
    assert gate(_target(currency="USD"), _file()) == "currency_mismatch"


@pytest.mark.parametrize("credit_note", [False, True])
def test_a_payment_behind_several_gates_passes_once_each_is_released(credit_note: bool) -> None:
    gates = ["hold_blocks_allocation", "before_servicing_start"] + (
        ["credit_note_to_apply"] if credit_note else []
    )
    f = _file(credit_note=credit_note)
    # ops release what the page shows, one decision at a time: each gate shows once, then ready
    released: list[str] = []
    for _ in range(len(gates) + 1):
        reason = gate(_target(*released), f)
        if reason is None:
            break
        assert reason not in released  # a released gate never comes back
        released.append(reason)
    assert sorted(released) == sorted(gates)
    # the decisions add up whatever their order (a single release alternated between two gates)
    for order in permutations(gates):
        for k in range(1, len(order)):
            assert gate(_target(*order[:k]), f) not in order[:k]
        assert gate(_target(*order), f) is None


def test_a_release_never_opens_a_gate_it_does_not_name() -> None:
    assert gate(_target("overpayment"), _file()) == "hold_blocks_allocation"
    assert gate(_target("credit_note_to_apply"), _file(holds=0)) == "before_servicing_start"
    no_start = FileFacts("f", "in_collection", "EUR", "commercial_b2b", "c", "pf", None, 0)
    assert gate(_target("before_servicing_start"), no_start) == "before_servicing_start"
