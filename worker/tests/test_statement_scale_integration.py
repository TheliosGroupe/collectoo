"""M2-07 scale: a synthetic camt.053 statement of 50,000 lines (STATEMENT_LINES to change it;
100,000 measured locally, docs/benchmarks/payments.md) imported by the payments job in one
transaction: set-based SQL, one cash_in per statement day (a few entries instead of 50k), then the
same file's lines again in another file (nothing new, ledger unchanged). The servicer has 5,000
clients with a confirmed payout IBAN (CLIENT_IBANS): every credit is checked against them, in one
join (M2c-2 review: a list scan per line took 8 s for 50k lines by 5k IBANs)."""

import logging
import os
import random
import time
import uuid
from dataclasses import replace
from datetime import timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, storage
from statement_helpers import START, bank_tenant, drain, money_state, paid_by_day, statement, upload

from collectoo_worker.payments.camt053 import parse_camt053
from collectoo_worker.synth.camt053 import (
    expected_lines,
    generate_entries,
    make_doc,
    render_camt053,
)
from collectoo_worker.synth.ids import iban_fr

pytestmark = pytest.mark.integration
LINES = int(os.environ.get("STATEMENT_LINES", "50000"))
CLIENT_IBANS = int(os.environ.get("CLIENT_IBANS", "5000"))
DAYS = 5


def _timings(caplog: pytest.LogCaptureFixture) -> str:
    found = [r.getMessage() for r in caplog.records if "imported:" in r.getMessage()]
    return found[-1].split(": ", 1)[1] if found else "?"


def _empty_stage_statistics(conn: psycopg.Connection) -> None:
    """The stage as autovacuum can leave it between two imports: emptied, its pages kept, counted
    at zero rows (a planner reading 0 rows a page for whatever the next import stages). Plans over
    the stage must not depend on it (CI: 251 s for a 50k import, M2b-6)."""
    conn.execute(
        """insert into private.bank_import_stage (statement_id, line_no, section_no, dedup_key,
             direction, amount_minor, currency, booking_date, kind, method)
           select '00000000-0000-0000-0000-00000000057a', g, 1, 'stale-' || g, 'credit', 1, 'EUR',
                  date '2026-10-01', 'debtor_credit', 'sct'
           from generate_series(1, 13500) g"""
    )
    conn.execute(
        "delete from private.bank_import_stage"
        " where statement_id = '00000000-0000-0000-0000-00000000057a'"
    )
    conn.execute("vacuum (truncate false) private.bank_import_stage")
    stats = conn.execute(
        "select reltuples, relpages from pg_class where oid = 'private.bank_import_stage'::regclass"
    ).fetchone()
    assert stats is not None and stats[0] == 0 and stats[1] > 0, stats


def _confirmed_client_ibans(tenant: dict[str, Any], n: int) -> None:
    """`n` clients of the servicer, each with a confirmed payout IBAN (proposed by the ops manager,
    confirmed by another person), written set-based as the commands leave them."""
    rng = random.Random(f"clients-{tenant['servicer']}")
    ibans = sorted({iban_fr(rng) for _ in range(n)})
    clients = [uuid.uuid4() for _ in ibans]
    docs = [uuid.uuid4() for _ in ibans]
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            """insert into public.organization (id, kind, servicer_organization_id, legal_name)
               select c, 'creditor_client', %s, 'Client ' || n
               from unnest(%s::uuid[]) with ordinality x (c, n)""",
            (tenant["servicer"], clients),
        )
        conn.execute(
            """insert into public.document (id, organization_id, client_organization_id, kind,
                 storage_bucket, storage_path, sha256, mime_type, file_name)
               select d, %s, c, 'payout_rib', 'documents',
                      'client/' || %s || '/' || c || '/' || d || '.pdf', repeat('a', 64),
                      'application/pdf', 'RIB.pdf'
               from unnest(%s::uuid[], %s::uuid[]) x (c, d)""",
            (tenant["servicer"], tenant["servicer"], clients, docs),
        )
        conn.execute(
            """insert into public.client_payout_account (organization_id, client_organization_id,
                 currency, iban, holder_name, evidence_document_id, proposed_by)
               select %s, c, 'EUR', i, 'CLIENT', d, %s
               from unnest(%s::uuid[], %s::uuid[], %s::text[]) x (c, d, i)""",
            (tenant["servicer"], tenant["staff"], clients, docs, ibans),
        )
        conn.execute(
            """update public.client_payout_account
               set status = 'active', confirmed_by = %s, confirmed_at = now(),
                   confirmed_via = 'second_admin'
               where organization_id = %s and status = 'proposed'""",
            (tenant["user"], tenant["servicer"]),
        )


def test_import_a_large_statement(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    caplog.set_level(logging.INFO, logger="collectoo.payments")
    with psycopg.connect(DB, autocommit=True) as conn:
        # autovacuum kept off the stage meanwhile: the statistics stay as set until the import
        conn.execute("alter table private.bank_import_stage set (autovacuum_enabled = false)")
        try:
            _empty_stage_statistics(conn)
            _import_a_large_statement(tmp_path, caplog)
        finally:
            conn.execute("alter table private.bank_import_stage reset (autovacuum_enabled)")


def _import_a_large_statement(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    tenant = bank_tenant()
    _confirmed_client_ibans(tenant, CLIENT_IBANS)
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
        f"\n{len(expected)}-line camt.053 ({len(data) / 1e6:.0f} MB), {CLIENT_IBANS} client IBANs:"
        f" parse alone {parse_s:.1f}s;"
        f" import job {job_s:.1f}s ({_timings(caplog)}); payments={state['payments']},"
        f" cash_in entries={state['cash_entries']}"
    )
    assert s["status"] == "imported", s
    assert s["counts"]["client_transfers_in"] == 0  # none of the synthetic payers is a client
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
