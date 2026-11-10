"""Job `remittances.documents {organization_id}` (M2c-5; design §10, §14, §16): the statements and
the invoice and credit-note PDFs due for one servicer.

Queued by every new invoice or credit note and by every run's approval (triggers of migration
20261113090000, which also keep the list of what is due: `private.remittance_document_todo`). One
transaction (the queue's, exactly once):

1. take the servicer's documents lock (one job at a time per servicer) and read what is due, oldest
   first — up to `INVOICES` invoice PDFs and `STATEMENTS` statements (a 50,000-line statement is
   one job's work);
2. per statement: its payload built in SQL from the run's frozen facts
   (`private.remittance_statement_prepare`), then its CSV and its PDF (which names the CSV's
   SHA-256); per invoice: its PDF from the payload frozen at issue;
3. upload the files to the private bucket `documents` at their keys (uploads alongside the
   rendering), then record them (`private.remittance_documents_record`: one `document` per file
   with its SHA-256, the statement and invoice-document rows, the work done off the list).

The files are uploaded before the transaction that records them commits. A failed attempt removes
what it uploaded (best effort) before failing; a retry renders the same bytes at the same keys (the
payload of an invoice is frozen and a statement's is a function of the run's frozen facts). What
is left when more is due is queued again. No model, no LLM (CLAUDE.md).
"""

from __future__ import annotations

import logging
import os
import time
from concurrent.futures import Future, ThreadPoolExecutor
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.remittance.invoice import TEMPLATE_VERSION as INVOICE_TEMPLATE
from collectoo_worker.remittance.invoice import InvoiceDocument
from collectoo_worker.remittance.invoice_pdf import pdf_sha256, render_invoice_pdf
from collectoo_worker.remittance.pdf import RENDERER_VERSION
from collectoo_worker.remittance.statement import TEMPLATE_VERSION as STATEMENT_TEMPLATE
from collectoo_worker.remittance.statement_csv import csv_sha256, render_statement_csv
from collectoo_worker.remittance.statement_pdf import render_statement_pdf
from collectoo_worker.runtime.storage import Storage

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.remittances")
BUCKET = "documents"
INVOICES = int(os.environ.get("DOCUMENTS_INVOICES", "200"))  # invoice PDFs per job
STATEMENTS = int(os.environ.get("DOCUMENTS_STATEMENTS", "1"))  # statements per job
UPLOADS = int(os.environ.get("DOCUMENTS_UPLOADS", "8"))  # concurrent uploads


def _remove_quietly(storage: Storage, paths: list[str]) -> None:
    if not paths:
        return
    try:
        storage.remove(BUCKET, paths)
    except Exception:
        log.exception("documents: %d uploaded files not removed (left to the sweep)", len(paths))


def run_documents(conn: Conn, storage: Storage, payload: dict[str, Any]) -> dict[str, Any]:
    org = str(payload["organization_id"])
    started = time.monotonic()
    due = conn.execute(
        """select kind, ref_id::text, number, pdf_path, csv_path
           from private.remittance_documents_begin(%s, %s, %s)""",
        (org, INVOICES, STATEMENTS),
    ).fetchall()
    if not due:
        return {"statements": 0, "invoices": 0}
    uploaded: list[str] = []
    timings: dict[str, float] = {}
    try:
        with ThreadPoolExecutor(max_workers=UPLOADS) as pool:
            uploads: list[Future[None]] = []

            def put(path: str, data: bytes, content_type: str) -> None:
                uploaded.append(path)
                uploads.append(pool.submit(storage.upload, BUCKET, path, data, content_type))

            for kind, run, _number, pdf_path, csv_path in due:
                if kind != "statement":
                    continue
                t0 = time.monotonic()
                row = conn.execute(
                    "select private.remittance_statement_prepare(%s)", (run,)
                ).fetchone()
                assert row is not None  # noqa: S101 - the function returns a payload or raises
                body = row[0]
                t1 = time.monotonic()
                csv = render_statement_csv(body)
                csv_hash = csv_sha256(csv)
                t2 = time.monotonic()
                pdf = render_statement_pdf(body, csv_hash)
                t3 = time.monotonic()
                timings.update(build=t1 - t0, csv=t2 - t1, pdf=t3 - t2)
                put(csv_path, csv, "text/csv")
                put(pdf_path, pdf, "application/pdf")
                conn.execute(
                    "insert into pg_temp._rd_statement_files (run_id, pdf_sha256, csv_sha256)"
                    " values (%s, %s, %s)",
                    (run, pdf_sha256(pdf), csv_hash),
                )
            invoices = {ref: path for kind, ref, _n, path, _c in due if kind == "invoice"}
            if invoices:
                rows = conn.execute(
                    """select invoice_id::text, number, kind, issue_date, payload, refs
                       from private.commission_invoice_render_rows(%s::uuid[])""",
                    (list(invoices),),
                ).fetchall()
                rendered = []
                for inv, number, kind, issued, body, refs in rows:
                    pdf = render_invoice_pdf(InvoiceDocument(number, kind, issued, body, refs))
                    put(invoices[inv], pdf, "application/pdf")
                    rendered.append((inv, pdf_sha256(pdf)))
                with (
                    conn.cursor() as cur,
                    cur.copy(
                        "copy pg_temp._rd_invoice_pdf (invoice_id, pdf_sha256) from stdin"
                    ) as cp,
                ):
                    for r in rendered:
                        cp.write_row(r)
            for upload in uploads:
                upload.result()  # a failed upload fails the job (retried by the queue)
        stored = time.monotonic()
        found = conn.execute(
            "select private.remittance_documents_record(%s, %s, %s, %s)",
            (org, STATEMENT_TEMPLATE, INVOICE_TEMPLATE, RENDERER_VERSION),
        ).fetchone()
    except BaseException:
        _remove_quietly(storage, uploaded)
        raise
    result = dict(found[0]) if found else {}
    if result.get("more"):
        conn.execute(
            "select pgmq.send('remittances', %s)",
            (Jsonb({"type": "documents", "organization_id": org}),),
        )
    log.info(
        "documents %s: %s statements, %s invoices; %s; render + store %.2fs, record %.2fs",
        org,
        result.get("statements"),
        result.get("invoices"),
        ", ".join(f"{k} {v:.2f}s" for k, v in timings.items()) or "no statement",
        stored - started,
        time.monotonic() - stored,
    )
    return result
