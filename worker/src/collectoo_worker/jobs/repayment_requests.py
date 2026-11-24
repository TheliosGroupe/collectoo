"""Job `remittances.repayment_request {request_id}` (M2c-7c-2; plan docs/design/m2c-7-plan.md
§5.2.7, §5.4): the letter « Demande de remboursement d'avance » of one request.

Queued by `public.request_advance_repayment`. In the queue's transaction (exactly once):

1. the request's row held (`private.repayment_request_job`: two jobs never draw it at once, nor
   does a withdrawal interleave); a request already drawn is left as it is (a replay draws nothing),
   a request withdrawn before its letter was drawn gets none (review round 1, NIGHT-1);
2. the PDF drawn from the payload frozen when the request was made
   (`remittance.repayment_request_pdf`: deterministic, no clock, no model, no LLM — every amount and
   date is the payload's, from the ledger);
3. uploaded to the private bucket `documents` at `repayment-requests/<servicer>/<request>.pdf`, then
   recorded (`private.repayment_request_document_done`: the document with the bytes' SHA-256, once).

A failed attempt removes what it uploaded (best effort, as the documents job) and fails the job: the
queue retries it a few times, then archives it; the nightly checks raise
`repayment_request_document_missing` for a letter of a request not withdrawn still not drawn one
hour after its request (ops then withdraw it and request again). A retry renders the same bytes at
the same key.
"""

from __future__ import annotations

import logging
from datetime import date
from typing import Any

import psycopg

from collectoo_worker.remittance.pdf import RENDERER_VERSION
from collectoo_worker.remittance.repayment_request import RepaymentRequestDocument
from collectoo_worker.remittance.repayment_request_pdf import pdf_sha256, render_request_pdf
from collectoo_worker.runtime.storage import Storage

Conn = psycopg.Connection[Any]
log = logging.getLogger("collectoo.remittances")
BUCKET = "documents"


def run_repayment_request(conn: Conn, storage: Storage, payload: dict[str, Any]) -> dict[str, Any]:
    request = str(payload["request_id"])
    row = conn.execute("select private.repayment_request_job(%s)", (request,)).fetchone()
    job = row[0] if row else None
    if not job:
        log.warning("repayment request %s: no such request", request)
        return {"drawn": False}
    if job.get("document_id"):
        return {"drawn": False, "document_id": job["document_id"]}
    if job.get("withdrawn_on"):
        # (review round 1, NIGHT-1, CC-1) withdrawn before its letter was drawn: none is drawn (the
        # request's row held, a withdrawal never interleaves; the document would be refused)
        log.info("repayment request %s: withdrawn before its letter was drawn", request)
        return {"drawn": False, "withdrawn": True}
    doc = RepaymentRequestDocument(
        number=str(job["number"]),
        issue_date=date.fromisoformat(str(job["issue_date"])),
        payload=job["payload"],
        template_version=str(job["template_version"]),
    )
    data = render_request_pdf(doc)
    path = str(job["storage_path"])
    try:
        storage.upload(BUCKET, path, data, "application/pdf")
        with conn.transaction():
            recorded = conn.execute(
                "select private.repayment_request_document_done(%s, %s, %s)",
                (request, pdf_sha256(data), RENDERER_VERSION),
            ).fetchone()
    except BaseException:
        try:
            storage.remove(BUCKET, [path])
        except Exception:
            log.exception("repayment request %s: %s not removed (left to the sweep)", request, path)
        raise
    log.info("repayment request %s: letter %s drawn (%d bytes)", request, doc.number, len(data))
    return {"drawn": True, "document_id": str(recorded[0]) if recorded else None}
