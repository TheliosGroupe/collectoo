"""Job `remittances.documents {organization_id}` (M2c-5; design §10, §14, §16): the statements and
the invoice and credit-note PDFs due for one servicer.

Queued by every new invoice or credit note and by every run's approval (triggers of migration
20261113090000, which also keep the list of what is due: `private.remittance_document_todo`), and
by the hourly schedule while documents are due (a retry whose delay has passed). One transaction
(the queue's, exactly once):

1. take the servicer's documents lock (one job at a time per servicer) and read what is due, oldest
   first — up to `INVOICES` invoice PDFs and `STATEMENTS` statements (a 50,000-line statement is
   one job's work), leaving aside a document whose last attempt failed until its retry time;
2. per chunk of `CHUNK` invoices, under its own savepoint: each PDF from the payload frozen at
   issue, uploaded to the private bucket `documents` at its key, then recorded
   (`private.remittance_documents_record`: one `document` per file with its SHA-256, the invoice
   document rows, the work done off the list);
3. per statement, under its own savepoint: its payload built in SQL from the run's frozen facts
   (`private.remittance_statement_prepare`, the run row held FOR SHARE to the commit), its CSV and
   its PDF (which names the CSV's SHA-256), uploaded, then recorded.

One document that cannot be drawn never blocks the others (review perf#2): its savepoint is rolled
back, what it uploaded is removed (best effort), a failed chunk is drawn again one invoice at a
time, and the failure is recorded on the document's row (`private.remittance_document_failed`:
attempts, last error, a retry time that doubles up to 6 hours); the job goes on with the rest and
succeeds. The nightly checks raise `remittance_document_failed` until it is drawn and
`remittance_document_missing` for anything still due after 24 hours. A lost connection still fails
the whole job (retried by the queue). A retry renders the same bytes at the same keys (an invoice's
payload is frozen, a statement's a function of the run's frozen facts and the books at K). What is
left when more is due is queued again. No model, no LLM (CLAUDE.md).
"""

from __future__ import annotations

import contextlib
import logging
import os
import time
from collections.abc import Callable, Sequence
from concurrent.futures import Future, ThreadPoolExecutor
from functools import partial
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
CHUNK = int(os.environ.get("DOCUMENTS_CHUNK", "50"))  # invoice PDFs per savepoint
UPLOADS = int(os.environ.get("DOCUMENTS_UPLOADS", "8"))  # concurrent uploads


def _remove_quietly(storage: Storage, paths: list[str]) -> None:
    if not paths:
        return
    try:
        storage.remove(BUCKET, paths)
    except Exception:
        log.exception("documents: %d uploaded files not removed (left to the sweep)", len(paths))


def _fatal(conn: Conn, exc: BaseException) -> bool:
    """What no savepoint can isolate: the connection itself, or the worker being stopped."""
    return (
        not isinstance(exc, Exception)
        or isinstance(exc, psycopg.OperationalError)
        or conn.closed
        or conn.broken
    )


class _Uploads:
    """Uploads of one item, concurrent; every path tried is remembered for a clean-up."""

    def __init__(self, storage: Storage, pool: ThreadPoolExecutor) -> None:
        self.storage, self.pool = storage, pool
        self.paths: list[str] = []
        self.futures: list[Future[None]] = []

    def put(self, path: str, data: bytes, content_type: str) -> None:
        self.paths.append(path)
        self.futures.append(self.pool.submit(self.storage.upload, BUCKET, path, data, content_type))

    def wait(self) -> None:
        for f in self.futures:
            f.result()  # a failed upload fails the item


def _record(conn: Conn, org: str) -> dict[str, Any]:
    row = conn.execute(
        "select private.remittance_documents_record(%s, %s, %s, %s)",
        (org, STATEMENT_TEMPLATE, INVOICE_TEMPLATE, RENDERER_VERSION),
    ).fetchone()
    return dict(row[0]) if row else {}


def _draw_invoices(
    conn: Conn, org: str, items: Sequence[tuple[str, str]], uploads: _Uploads
) -> int:
    """The PDFs of `items` [(invoice id, key)], uploaded and recorded."""
    paths = dict(items)
    rows = conn.execute(
        """select invoice_id::text, number, kind, issue_date, payload, refs
           from private.commission_invoice_render_rows(%s::uuid[])""",
        ([ref for ref, _ in items],),
    ).fetchall()
    rendered = []
    for inv, number, kind, issued, body, refs in rows:
        pdf = render_invoice_pdf(InvoiceDocument(number, kind, issued, body, refs))
        uploads.put(paths[inv], pdf, "application/pdf")
        rendered.append((inv, pdf_sha256(pdf)))
    uploads.wait()
    with (
        conn.cursor() as cur,
        cur.copy("copy pg_temp._rd_invoice_pdf (invoice_id, pdf_sha256) from stdin") as cp,
    ):
        for r in rendered:
            cp.write_row(r)
    return int(_record(conn, org).get("invoices", 0))


def _draw_statement(  # noqa: PLR0913, PLR0917 - the statement's run and keys
    conn: Conn,
    org: str,
    run: str,
    pdf_path: str,
    csv_path: str,
    timings: dict[str, float],
    uploads: _Uploads,
) -> int:
    t0 = time.monotonic()
    row = conn.execute("select private.remittance_statement_prepare(%s)", (run,)).fetchone()
    assert row is not None  # noqa: S101 - the function returns a payload or raises
    body = row[0]
    t1 = time.monotonic()
    csv = render_statement_csv(body)
    csv_hash = csv_sha256(csv)
    t2 = time.monotonic()
    pdf = render_statement_pdf(body, csv_hash)
    t3 = time.monotonic()
    timings.update(build=t1 - t0, csv=t2 - t1, pdf=t3 - t2)
    uploads.put(csv_path, csv, "text/csv")
    uploads.put(pdf_path, pdf, "application/pdf")
    uploads.wait()
    conn.execute(
        "insert into pg_temp._rd_statement_files (run_id, pdf_sha256, csv_sha256)"
        " values (%s, %s, %s)",
        (run, pdf_sha256(pdf), csv_hash),
    )
    return int(_record(conn, org).get("statements", 0))


def _failed(conn: Conn, org: str, kind: str, ref: str, exc: BaseException) -> None:
    log.warning("documents %s: %s %s not drawn: %s", org, kind, ref, exc)
    conn.execute(
        "select private.remittance_document_failed(%s, %s, %s, %s)",
        (org, kind, ref, f"{type(exc).__name__}: {exc}"[:2000]),
    )


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
    result = {"statements": 0, "invoices": 0, "failed": 0}
    kept: list[str] = []  # uploads of the items recorded: removed if the job fails after all
    timings: dict[str, float] = {}

    def attempt(
        pool: ThreadPoolExecutor,
        kind: str,
        refs: Sequence[str],
        work: Callable[[_Uploads], int],
        *,
        record_failure: bool,
    ) -> bool:
        """One item (a statement, a chunk of invoices) under its own savepoint."""
        uploads = _Uploads(storage, pool)
        try:
            with conn.transaction():  # a savepoint: the item alone is rolled back
                result[kind] += work(uploads)
        except BaseException as exc:
            for f in uploads.futures:  # let every upload end before removing what it wrote
                f.cancel()
                if not f.cancelled():
                    with contextlib.suppress(Exception):  # its failure is the one recorded below
                        f.result()
            _remove_quietly(storage, uploads.paths)
            if _fatal(conn, exc):
                raise
            if record_failure:
                for ref in refs:
                    _failed(conn, org, "statement" if kind == "statements" else "invoice", ref, exc)
                    result["failed"] += 1
            return False
        kept.extend(uploads.paths)
        return True

    try:
        with ThreadPoolExecutor(max_workers=UPLOADS) as pool:
            invoices = [(ref, path) for kind, ref, _n, path, _c in due if kind == "invoice"]
            size = max(CHUNK, 1)
            for i in range(0, len(invoices), size):
                chunk = invoices[i : i + size]
                alone = len(chunk) == 1
                if attempt(
                    pool,
                    "invoices",
                    [r for r, _ in chunk],
                    partial(_draw_invoices, conn, org, chunk),
                    record_failure=alone,
                ):
                    continue
                if alone:
                    continue
                for one in chunk:  # the chunk failed: each invoice alone, so only the bad one waits
                    attempt(
                        pool,
                        "invoices",
                        [one[0]],
                        partial(_draw_invoices, conn, org, [one]),
                        record_failure=True,
                    )
            for kind, run, _number, pdf_path, csv_path in due:
                if kind != "statement":
                    continue
                attempt(
                    pool,
                    "statements",
                    [run],
                    partial(_draw_statement, conn, org, run, pdf_path, csv_path, timings),
                    record_failure=True,
                )
    except BaseException:
        _remove_quietly(storage, kept)
        raise
    more = conn.execute("select private.remittance_documents_due(%s)", (org,)).fetchone()
    if more and more[0]:
        conn.execute(
            "select pgmq.send('remittances', %s)",
            (Jsonb({"type": "documents", "organization_id": org}),),
        )
    log.info(
        "documents %s: %s statements, %s invoices, %s failed; %s; %.2fs",
        org,
        result["statements"],
        result["invoices"],
        result["failed"],
        ", ".join(f"{k} {v:.2f}s" for k, v in timings.items()) or "no statement",
        time.monotonic() - started,
    )
    return {**result, "more": bool(more and more[0])}
