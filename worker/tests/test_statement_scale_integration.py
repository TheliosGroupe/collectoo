"""M2-07 scale: a synthetic camt.053 statement of 50,000 lines (STATEMENT_LINES to change it;
100,000 measured locally, docs/benchmarks/payments.md) imported by the payments job in one
transaction: set-based SQL, one cash_in per statement day (a few entries instead of 50k), then the
same file's lines again in another file (nothing new, ledger unchanged)."""

import logging
import os
import time
from dataclasses import replace
from datetime import timedelta
from pathlib import Path

import pytest
from integration_helpers import storage
from statement_helpers import START, bank_tenant, drain, money_state, paid_by_day, statement, upload

from collectoo_worker.payments.camt053 import parse_camt053
from collectoo_worker.synth.camt053 import (
    expected_lines,
    generate_entries,
    make_doc,
    render_camt053,
)

pytestmark = pytest.mark.integration
LINES = int(os.environ.get("STATEMENT_LINES", "50000"))
DAYS = 5


def _timings(caplog: pytest.LogCaptureFixture) -> str:
    found = [r.getMessage() for r in caplog.records if "imported:" in r.getMessage()]
    return found[-1].split(": ", 1)[1] if found else "?"


def test_import_a_large_statement(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.INFO, logger="collectoo.payments")
    tenant = bank_tenant()
    store = storage()
    entries = generate_entries(LINES, seed=21, start=START, days=DAYS)
    doc = make_doc(
        entries, iban=tenant["iban"], from_date=START, to_date=START + timedelta(days=DAYS - 1)
    )
    data = render_camt053(doc, "02")
    path = tmp_path / "statement.xml"
    path.write_bytes(data)
    expected = expected_lines(doc)
    parse_started = time.monotonic()
    parsed = parse_camt053(path, iban=tenant["iban"], currency="EUR")
    parse_s = time.monotonic() - parse_started
    target = upload(tenant, store, data)
    job_started = time.monotonic()
    drain(store)
    job_s = time.monotonic() - job_started
    s = statement(target["statement_id"])
    state = money_state(tenant["bank"])
    print(
        f"\n{len(expected)}-line camt.053 ({len(data) / 1e6:.0f} MB): parse alone {parse_s:.1f}s;"
        f" import job {job_s:.1f}s ({_timings(caplog)}); payments={state['payments']},"
        f" cash_in entries={state['cash_entries']}"
    )
    assert s["status"] == "imported", s
    assert len(parsed.lines) == len(expected) == s["counts"]["new_lines"] >= LINES
    by_day = paid_by_day(expected)
    assert state["payments_minor"] == sum(by_day.values())
    assert state["cash_entries"] == len(by_day) <= DAYS
    assert s["bank_check"]["difference_minor"] == "0"
    assert job_s < 240

    # The same lines in another file: every line known, nothing booked twice.
    again = upload(tenant, store, render_camt053(replace(doc, msg_id="MSG-AGAIN"), "08"))
    rerun_started = time.monotonic()
    drain(store)
    rerun_s = time.monotonic() - rerun_started
    print(f"same {len(expected)} lines again: {rerun_s:.1f}s ({_timings(caplog)})")
    s2 = statement(again["statement_id"])
    assert s2["status"] == "imported", s2
    assert s2["counts"]["known_lines"] == len(expected) and s2["counts"]["new_lines"] == 0
    assert money_state(tenant["bank"]) == state  # ledger unchanged, to the hash
