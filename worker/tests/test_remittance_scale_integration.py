"""M2c-4 scale (needs `make up`; design §19): one client's run of 50,000 lines.

The files are boarded from the synthetic EU loan tape (as the M2-08/M2-09 scale tests: their mandate
has complete terms, 15 % flat with a netting clause); a statement paying each file by its RF
reference is imported, matched and allocated; then « Préparer maintenant » (the reservation under
the allocation lock), the prepare job (facts, deadlines, commission, documents, settlement plan,
COPY), the approval command and its job (the lines frozen, the invoice numbered with one charge per
file, its entry, the payout ordered), the nightly checks (I14 to I18, R124-6), then the
cancellation by an admin (a synchronous command under the API's 8 s: the transfer cancelled, one
full credit note with one allocation per file, the lines released, the items back in the queue, the
tier history restored) and the checks again. The remittance tables are never analysed (the state CI
meets): the plans must not rest on statistics. Prints the timings (docs/benchmarks/remittances.md).
REMIT_FILES changes the size."""

import json
import logging
import os
import time
import uuid
from pathlib import Path

import psycopg
import pytest
from debit_helpers import checks
from integration_helpers import DB, one, storage
from reconciliation_helpers import pay
from remittance_helpers import (
    add_admin,
    confirm_payout,
    drain,
    recent_business_day,
    run_row,
    staff,
)
from statement_helpers import bank_tenant
from stats_helpers import forget_statistics
from test_allocation_scale_integration import _credits, _files
from test_matching_scale_integration import _board

pytestmark = pytest.mark.integration
FILES = int(os.environ.get("REMIT_FILES", "50000"))


def test_a_run_of_50k_lines(  # noqa: PLR0915 - one scenario, its timings printed together
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="collectoo.remittances")
    tenant = bank_tenant()
    _board(tenant, tmp_path, count=FILES)
    files = [f for f in _files(tenant) if f[2] > 0][:FILES]
    # imported, matched, allocated; collected a week ago (no deadline near)
    pay(tenant, storage(), _credits(files), prefix="V", start=recent_business_day(8), days=5)
    with psycopg.connect(DB) as conn, conn.transaction():
        confirm_payout(conn, tenant, str(tenant["client"]))
    admin = add_admin(tenant)
    for table in (
        "private.remittance_pending",
        "private.remittance_draft_line",
        "public.remittance_line",
    ):
        forget_statistics(table)
    with psycopg.connect(DB) as conn:
        items = one(
            conn,
            "select count(*) from private.remittance_pending where organization_id = %s",
            (tenant["servicer"],),
        )
    assert items >= len(files) * 0.9, items

    started = time.monotonic()
    result = staff(
        tenant,
        "select public.request_remittance_run(%s, %s, 'EUR')",
        str(uuid.uuid4()),
        tenant["client"],
    )
    requested = time.monotonic()
    run = str(result["run_id"])
    drain()  # the prepare job
    prepared = time.monotonic()
    draft = run_row(run)
    assert draft["prepared_at"] is not None, draft["last_failure"]
    assert draft["line_count"] == items
    # « Reversements » and the nightly checks with the draft waiting (its items reserved: the
    # overview and the schedule read only the unreserved ones, review perf#6)
    shown = time.monotonic()
    overview = staff(tenant, "select public.remittance_overview('a-valider')")
    overview_s = time.monotonic() - shown
    assert [r["id"] for r in overview["runs"]] == [run]
    shown = time.monotonic()
    checks(tenant)
    draft_checks_s = time.monotonic() - shown
    item = [
        {"run_id": run, "inputs_hash": draft["inputs_hash"], "net_text": str(draft["net_minor"])}
    ]
    approving = time.monotonic()
    queued = staff(
        tenant,
        "select public.approve_remittance_runs(%s, %s)",
        str(uuid.uuid4()),
        json.dumps(item),
    )
    commanded = time.monotonic()
    assert queued["results"][0]["status"] == "queued", queued
    drain()  # the approval job
    approved = time.monotonic()
    done = run_row(run)
    assert done["status"] == "approved", done["last_failure"]
    run_checks = checks(tenant)
    checked = time.monotonic()
    with psycopg.connect(DB) as conn:
        lines, commission, live = conn.execute(
            """select count(*), sum(commission_minor), count(*) filter (where not released)
               from public.remittance_line where run_id = %s""",
            (run,),
        ).fetchone() or (0, 0, 0)
        invoice = conn.execute(
            """select i.ht_minor, i.ttc_minor,
                      (select count(*) from public.commission_invoice_charge c
                       where c.invoice_id = i.id)
               from public.commission_invoice i where i.run_id = %s""",
            (run,),
        ).fetchone()
        pending = one(
            conn,
            "select count(*) from private.remittance_pending where client_organization_id = %s",
            (tenant["client"],),
        )
        transfer = one(
            conn, "select amount_minor from public.bank_transfer where run_id = %s", (run,)
        )
    assert (lines, live, pending) == (items, items, 0)
    assert invoice is not None and invoice[0] == commission
    assert invoice[2] == len(files)
    assert transfer == done["net_minor"] == done["gross_minor"] - invoice[1]
    with psycopg.connect(DB) as conn:
        found = conn.execute(
            """select code from public.payment_check_result where run_id = %s
               and severity = 'violation'""",
            (run_checks["run_id"],),
        ).fetchall()
    assert found == [], found

    # the cancellation (§9.7): one synchronous command, within the API's 8 s statement timeout
    cancelling = time.monotonic()
    cancelled = staff(
        tenant,
        "select public.cancel_remittance_run(%s, %s, %s, %s)",
        str(uuid.uuid4()),
        run,
        done["version"],
        "Test d'échelle",
        user=admin,
    )
    cancel_s = time.monotonic() - cancelling
    assert cancelled["status"] == "cancelled" and cancelled["lines_released"] == items
    with psycopg.connect(DB) as conn:
        back, credit = conn.execute(
            """select (select count(*) from private.remittance_pending
                       where client_organization_id = %s and draft_run_id is null),
                      (select count(*) from public.commission_credit_alloc a
                       join public.commission_invoice n on n.id = a.credit_note_id
                       where n.run_id = %s and n.reason = 'run_cancelled')""",
            (tenant["client"], run),
        ).fetchone() or (0, 0)
    assert (back, credit) == (items, len(files))
    after = checks(tenant)
    with psycopg.connect(DB) as conn:
        found = conn.execute(
            """select code from public.payment_check_result where run_id = %s
               and severity = 'violation'""",
            (after["run_id"],),
        ).fetchall()
    assert found == [], found
    logs = [r.getMessage() for r in caplog.records if r.getMessage().startswith("prepare ")]
    print(
        f"\n{items} items: reserved (command) in {requested - started:.2f}s; prepared in"
        f" {prepared - requested:.1f}s ({'; '.join(logs)}); approval command"
        f" {commanded - approving:.2f}s, job {approved - commanded:.1f}s; nightly checks"
        f" {checked - approved:.1f}s (with the draft waiting {draft_checks_s:.1f}s); overview"
        f" with the draft {overview_s:.2f}s; cancellation (command) {cancel_s:.2f}s"
    )
    # design §19 targets, with room for a shared CI runner (the commands: the API's 8 s)
    assert requested - started < 8
    assert approved - commanded < 60
    assert cancel_s < 8
