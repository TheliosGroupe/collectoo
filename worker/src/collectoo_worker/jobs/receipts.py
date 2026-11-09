"""Job `payments.receipts` (M2-10, CPCE R124-6; design §9, §10): the receipts of these payments.

Queued (200 payments per message) by every ledger entry tagged with a payment and by a payment
given a file, taken off one or gated (migration 20261110090000), and once by that migration for the
payments matched before it (backfill). One transaction (the queue's, exactly once):

1. take the servicer's receipts lock: receipts of one servicer are issued one job at a time (one
   number counter, a payment's versions in order); the allocation lock is not taken, so receipts
   never hold up allocations or ops commands;
2. `private.receipt_prepare`: for each payment, the payload built in SQL from the ledger at the
   job's start (`known_at`); a version is due only when it differs from the current one (the job is
   idempotent), a void one when the payment left its file; numbers are drawn for first versions;
3. render each PDF (`payments.receipt_pdf`, deterministic) and upload it to the private bucket
   `documents` at its key (the same key and bytes if a failed attempt is replayed), uploads running
   alongside the rendering (`UPLOADS` at a time);
4. `private.receipt_issue`: one `document` (SHA-256) and one `receipt` row per version.

At most `CHUNK` payments per run: the rest of a longer list is queued in the same transaction. No
model, no LLM: every amount comes from the ledger (CLAUDE.md).
"""

from __future__ import annotations

import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.payments.receipt_pdf import RENDERER_VERSION, pdf_sha256, render_receipt
from collectoo_worker.payments.receipts import TEMPLATE_VERSION, ReceiptDocument
from collectoo_worker.runtime.storage import Storage

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.payments")
CHUNK = int(os.environ.get("RECEIPTS_CHUNK", "200"))  # design §9: 200 per message
UPLOADS = int(os.environ.get("RECEIPTS_UPLOADS", "8"))  # concurrent uploads to Storage
BUCKET = "documents"


def run_receipts(conn: Conn, storage: Storage, payload: dict[str, Any]) -> dict[str, Any]:
    org = str(payload["organization_id"])
    ids = list(dict.fromkeys(str(x) for x in payload.get("payment_ids") or ()))
    if len(ids) > CHUNK:
        rest = {"type": "receipts", "organization_id": org, "payment_ids": ids[CHUNK:]}
        conn.execute("select pgmq.send('payments', %s)", (Jsonb(rest),))
        ids = ids[:CHUNK]
    if not ids:
        return {"payments": 0, "issued": 0}
    started = time.monotonic()
    conn.execute("select pg_advisory_xact_lock(hashtext('receipts:' || %s))", (org,))
    conn.execute("select private.receipt_begin()")
    rows = conn.execute(
        """select payment_id::text, number, version, kind, known_at, storage_path, payload
           from private.receipt_prepare(%s, %s::uuid[])""",
        (org, ids),
    ).fetchall()
    prepared = time.monotonic()
    rendered: list[tuple[str, str]] = []
    # Rendering is CPU-bound (one at a time); uploads wait on the network: they run alongside.
    with ThreadPoolExecutor(max_workers=UPLOADS) as pool:
        uploads = []
        for payment_id, number, version, kind, known_at, path, body in rows:
            pdf = render_receipt(ReceiptDocument(number, int(version), kind, known_at, body))
            uploads.append(pool.submit(storage.upload, BUCKET, path, pdf, "application/pdf"))
            rendered.append((payment_id, pdf_sha256(pdf)))
        for upload in uploads:
            upload.result()  # a failed upload fails the job (retried by the queue)
    stored = time.monotonic()
    with (
        conn.cursor() as cur,
        cur.copy("copy pg_temp._receipt_pdf (payment_id, pdf_sha256) from stdin") as copy,
    ):
        for row in rendered:
            copy.write_row(row)
    found = conn.execute(
        "select private.receipt_issue(%s, %s)", (TEMPLATE_VERSION, RENDERER_VERSION)
    ).fetchone()
    issued = int(found[0]) if found else 0
    log.info(
        "receipts %s: %d payments, %d issued; prepare %.2fs, render + store %.2fs, record %.2fs",
        org,
        len(ids),
        issued,
        prepared - started,
        stored - prepared,
        time.monotonic() - stored,
    )
    return {"payments": len(ids), "issued": issued}
