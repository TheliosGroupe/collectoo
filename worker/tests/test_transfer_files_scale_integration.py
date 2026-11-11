"""M2c-6a scale (needs `make up`; design §19 « pain.001 ≤ 200 transfers < 0.2 s », the brief's
file of 5,000 transfers and the cash check under load).

5,000 unidentified credits are imported on one statement and each is refunded in the transfer file
(`request_refund`, execution mode `file`: 5,000 RFD transfers ordered); then « Générer le fichier »
(one command: the per-transfer checks, the cash check, the items, the transfers in the file), the
`transfer_file` job (5,000 transactions written, checked, uploaded), the download, the cash check
and « Virements » with the 5,000 in flight, then a statement showing their 5,000 debits (each seen
by its RFD id: none in flight any more). The new tables' statistics are forgotten first (the state
CI meets). Prints the timings (docs/benchmarks/remittances.md). TRANSFER_FILE_SIZE changes the
size."""

import hashlib
import logging
import os
import time
import uuid
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, one, storage
from reconciliation_helpers import pay
from remittance_helpers import drain, recent_business_day, staff
from statement_helpers import bank_tenant
from stats_helpers import forget_statistics

from collectoo_worker.remittance import pain001
from collectoo_worker.synth.reconciliation import Credit

pytestmark = pytest.mark.integration
SIZE = int(os.environ.get("TRANSFER_FILE_SIZE", "5000"))


def _credits(n: int) -> list[Credit]:
    return [
        Credit(1000 + k, f"PAYEUR {k}", None, (f"VIREMENT {k}",), None, None, "no_match", "none")
        for k in range(n)
    ]


def _cash(tenant: dict[str, Any]) -> tuple[dict[str, Any], float]:
    started = time.monotonic()
    with psycopg.connect(DB) as conn:
        cash = one(conn, "select private.transfer_cash_position(%s)", (tenant["bank"],))
    return dict(cash), time.monotonic() - started


def test_a_file_of_5000_transfers(  # noqa: PLR0915 - one scenario, its timings printed together
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO, logger="collectoo.remittances")
    tenant = bank_tenant()
    day = recent_business_day()
    sid = pay(tenant, storage(), _credits(SIZE), prefix="U", start=day, days=1, allocate=False)
    with psycopg.connect(DB) as conn, conn.transaction():
        n = one(
            conn,
            "select count(*) from public.payment"
            " where bank_account_id = %s and status = 'unmatched'",
            (tenant["bank"],),
        )
    assert n == SIZE
    for table in (
        "public.bank_transfer",
        "public.refund_request",
        "public.transfer_file",
        "public.transfer_file_item",
    ):
        forget_statistics(table)

    asking = time.monotonic()
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select set_config('request.jwt.claims', %s, true)",
            (f'{{"sub": "{tenant["staff"]}", "role": "authenticated", "aal": "aal2"}}',),
        )
        conn.execute("set local role authenticated")
        asked = one(
            conn,
            """select count(public.request_refund('scale-rfd-' || p.id, p.id, p.amount_minor::text,
                        'FR7630004000031234567890143', p.payer_name, 'other', p.review_reason,
                        p.amount_minor::text, 'test d''échelle'))
               from public.payment p where p.bank_account_id = %s and p.status = 'unmatched'""",
            (tenant["bank"],),
        )
        conn.execute("reset role")
        # the debit job each refund queues has nothing to find: taken off the payments queue
        conn.execute(
            "delete from pgmq.q_payments where message ->> 'organization_id' = %s",
            (str(tenant["servicer"]),),
        )
    asked_s = time.monotonic() - asking
    assert asked == SIZE

    generating = time.monotonic()
    generated = staff(
        tenant,
        "select public.generate_transfer_file(%s, %s, null)",
        str(uuid.uuid4()),
        tenant["bank"],
    )
    generate_s = time.monotonic() - generating
    assert generated["nb_of_txs"] == SIZE and generated["held"] == []
    writing = time.monotonic()
    drain()  # the transfer_file job
    write_s = time.monotonic() - writing
    with psycopg.connect(DB) as conn:
        path, digest, status = conn.execute(
            "select storage_path, file_sha256, status from public.transfer_file where id = %s",
            (generated["file_id"],),
        ).fetchone() or (None, None, None)
    assert status == "generated"
    dest = tmp_path / "file.xml"
    storage().download("transfer-files", str(path), dest)
    data = dest.read_bytes()
    assert hashlib.sha256(data).hexdigest() == digest
    checking = time.monotonic()
    facts = pain001.check(data, "pain.001.001.09")
    check_s = time.monotonic() - checking
    assert facts["nb_of_txs"] == SIZE
    assert facts["ctrl_sum_minor"] == int(generated["ctrl_sum_minor"])

    downloading = time.monotonic()
    staff(tenant, "select public.transfer_file_download(%s, %s)", generated["file_id"], digest)
    download_s = time.monotonic() - downloading
    cash, cash_s = _cash(tenant)
    assert int(cash["in_flight_minor"]) == int(generated["ctrl_sum_minor"])
    assert cash["in_flight_count"] == SIZE
    showing = time.monotonic()
    overview = staff(tenant, "select public.transfer_overview()")
    overview_s = time.monotonic() - showing
    assert overview["accounts"][0]["files"][0]["nb_of_txs"] == SIZE

    # their debits on the next statement: none in flight any more
    with psycopg.connect(DB) as conn, conn.transaction():
        st = one(
            conn,
            """insert into public.bank_statement (organization_id, bank_account_id, currency,
                 format, file_name, file_sha256, size_bytes, storage_path)
               values (%s, %s, 'EUR', 'camt053', 'debits.xml', %s, 1, %s) returning id""",
            (tenant["servicer"], tenant["bank"], uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
        )
        conn.execute(
            "update public.bank_statement set status = 'uploaded', uploaded_at = now()"
            " where id = %s",
            (st,),
        )
        conn.execute(
            """insert into public.bank_transaction (organization_id, bank_account_id, statement_id,
                 line_no, dedup_key, direction, amount_minor, currency, booking_date, kind,
                 end_to_end_id)
               select t.organization_id, t.debtor_bank_account_id, %s,
                      row_number() over (order by t.id), 'e:' || t.id, 'debit', t.amount_minor,
                      'EUR', private.paris_today(), 'refund_out', t.end_to_end_id
               from public.bank_transfer t where t.transfer_file_id = %s""",
            (st, generated["file_id"]),
        )
        closing = one(
            conn,
            "select closing_booked_minor from public.bank_statement where id = %s",
            (sid,),
        )
        conn.execute(
            """update public.bank_statement set status = 'imported',
                 from_date = private.paris_today(), to_date = private.paris_today(),
                 opening_booked_minor = %s, closing_booked_minor = %s, counts = '{}',
                 finished_at = now() where id = %s""",
            (closing, closing - int(generated["ctrl_sum_minor"]), st),
        )
    seen, seen_s = _cash(tenant)
    assert seen["in_flight_minor"] == "0" and seen["in_flight_count"] == 0

    logs = [r.getMessage() for r in caplog.records if r.getMessage().startswith("transfer file ")]
    print(
        f"\n{SIZE} transfers: refunds asked in {asked_s:.1f}s; generation (command)"
        f" {generate_s:.2f}s; job {write_s:.2f}s ({'; '.join(logs)}); structural check"
        f" {check_s:.2f}s; {len(data)} bytes; download (command) {download_s:.2f}s; cash check with"
        f" {SIZE} in flight {cash_s:.2f}s, once their debits are seen {seen_s:.2f}s; « Virements »"
        f" {overview_s:.2f}s"
    )
    # the commands within the API's 8 s; the job well within the queue's visibility timeout
    assert generate_s < 8
    assert download_s < 8
    assert overview_s < 8
    assert write_s < 60
