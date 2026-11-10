"""M2c-5 documents through the database and storage (needs `make up`; design §10, §14, §18 M2-14 and
M2-15; ADR-0014 M2c-5 addendum).

* an approved run gets its statement (payload built in SQL, CSV and PDF stored with their SHA-256)
  and its invoice's PDF, drawn by the `documents` job the approval queues;
* CSV = PDF = run: the CSV's rows are the run's lines (amounts and commissions add up to the run's
  gross and to the invoices' HT), the PDF's summary carries the run's totals, the payload's totals
  are the run's columns, and the position before the payout is what the ledger owed the client at K;
* the stored bytes are the recorded hashes and are rendered again identically from the stored
  payload (another process too: no clock, no environment);
* a cancelled run's credit note gets its PDF; a due invoice (no netting clause) prints its payment
  date and the own account frozen at issue, whatever the settings say afterwards; the buyer's
  electronic acceptance is read from the payload (CGI 289 VI);
* a failed attempt leaves nothing behind and the job is idempotent.
"""

from __future__ import annotations

import csv
import io
import json
import subprocess
import sys
import uuid
from typing import Any

import httpx
import psycopg
import pytest
from integration_helpers import DB, TERMS, one, storage
from remittance_helpers import (
    add_admin,
    approve,
    drain,
    paid_file,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)

from collectoo_worker.jobs.remittance_documents import run_documents
from collectoo_worker.remittance.invoice import InvoiceDocument, invoice_text
from collectoo_worker.remittance.invoice_pdf import render_invoice_pdf
from collectoo_worker.remittance.statement import CSV_HEADER, statement_text
from collectoo_worker.remittance.statement_csv import csv_sha256, render_statement_csv
from collectoo_worker.remittance.statement_pdf import pdf_sha256, render_statement_pdf

pytestmark = pytest.mark.integration


def _statement(run: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            """select s.*, dp.storage_path as pdf_path, dc.storage_path as csv_path
               from public.remittance_statement s
               join public.document dp on dp.id = s.pdf_document_id
               join public.document dc on dc.id = s.csv_document_id
               where s.run_id = %s""",
            (run,),
        )
        row = cur.fetchone()
        assert row is not None and cur.description is not None, "no statement"
        return {d.name: v for d, v in zip(cur.description, row, strict=True)}


def _invoice_docs(run: str) -> list[dict[str, Any]]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            """select i.id::text, i.number, i.kind, i.issue_date, i.payload, d.pdf_sha256,
                      d.electronic, doc.storage_path, doc.sha256, d.template_version
               from public.commission_invoice i
               left join public.commission_invoice_document d on d.invoice_id = i.id
               left join public.document doc on doc.id = d.document_id
               where i.run_id = %s order by i.seq""",
            (run,),
        )
        assert cur.description is not None
        names = [d.name for d in cur.description]
        return [dict(zip(names, r, strict=True)) for r in cur.fetchall()]


def _download(path: str) -> bytes:
    s = storage()
    url = f"{s._base}/documents/{path}"  # the test reads the stored object back
    resp = httpx.get(url, headers=s._headers, timeout=30)
    resp.raise_for_status()
    return resp.content


def _refs(invoice_id: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select refs from private.commission_invoice_render_rows(array[%s]::uuid[])",
            (invoice_id,),
        ).fetchone()
    assert row is not None
    return dict(row[0])


def test_an_approved_run_has_its_statement_and_its_invoice() -> None:  # noqa: PLR0915
    """§7.2 RV-1: 200 000 collected at 15 % with a netting clause; the statement and FC-…-000001."""
    tenant = remittance_tenant()
    paid_file(tenant, 200_000)
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    r = run_row(run)
    assert r["status"] == "approved", r["last_failure"]
    st = _statement(run)
    payload = st["payload"]
    assert st["number"] == r["number"] and st["line_count"] == 1 and st["file_count"] == 1
    assert st["template_version"] == "releve-reversement-fr-1"
    # the payload's totals are the run's columns
    t = payload["totals"]
    for key, col in (
        ("gross_minor", "gross_minor"),
        ("net_minor", "net_minor"),
        ("settlement_minor", "settlement_minor"),
        ("invoice_ttc_minor", "invoice_ttc_minor"),
        ("commission_taken_minor", "commission_taken_minor"),
    ):
        assert int(t[key]) == int(r[col] or 0), key
    assert (t["gross_minor"], t["invoice_ttc_minor"], t["net_minor"]) == (
        "200000",
        "36000",
        "164000",
    )
    # stored bytes = recorded hashes = a fresh rendering of the stored payload
    pdf, data = _download(st["pdf_path"]), _download(st["csv_path"])
    assert pdf_sha256(pdf) == st["pdf_sha256"] and csv_sha256(data) == st["csv_sha256"]
    assert render_statement_csv(payload) == data
    assert render_statement_pdf(payload, st["csv_sha256"]) == pdf
    # CSV = run: one row per line, the sums are the run's gross and the invoices' HT
    assert data.startswith(b"\xef\xbb\xbf") and b"\r\n" in data
    text = data.decode("utf-8-sig")
    rows = list(csv.reader(io.StringIO(text, newline=""), delimiter=";"))
    assert tuple(rows[0]) == CSV_HEADER
    body = [dict(zip(CSV_HEADER, x, strict=True)) for x in rows[1:]]
    assert len(body) == 1
    assert sum(int(x["montant_centimes"]) for x in body) == r["gross_minor"]
    assert sum(int(x["commission_ht_centimes"]) for x in body) == r["invoice_ht_minor"]
    (line,) = body
    assert (line["montant"], line["commission_ht"], line["nature"]) == (
        "2\u00a0000,00",
        "300,00",
        "Paiement imputé",
    )
    assert line["taux"] == "15\u00a0%" and line["facture"].startswith("FC-")
    assert line["date_encaissement"] and line["date_limite_reversement"]
    # PDF = run: the summary prints the run's totals; « ordonné », never « payé »
    summary = statement_text(payload, st["csv_sha256"])
    for amount in ("2\u202f000,00\u00a0€", "360,00\u00a0€", "1\u202f640,00\u00a0€"):
        assert amount in summary
    assert "Virement de 1\u202f640,00\u00a0€ ordonné le" in summary
    assert "payé" not in summary and "réglé" not in summary
    # the position before the payout: what the ledger owed the client at K
    with psycopg.connect(DB) as conn:
        owed = one(
            conn,
            """select -coalesce(sum(private.ledger_balance(la.id, '9999-12-31', r.known_at)), 0)
               from public.remittance_run r join public.ledger_account la
                 on la.organization_id = r.organization_id and la.book = 'client_payable'
                and la.client_organization_id = r.client_organization_id
                and la.currency = r.currency
               where r.id = %s""",
            (run,),
        )
    assert int(payload["position"]["owed_before_minor"]) == int(owed) == r["gross_minor"]
    # the invoice's PDF, from its frozen payload
    (inv,) = _invoice_docs(run)
    assert inv["pdf_sha256"] is not None and inv["template_version"] == "facture-commission-fr-1"
    stored = _download(inv["storage_path"])
    assert pdf_sha256(stored) == inv["pdf_sha256"] == inv["sha256"]
    doc = InvoiceDocument(
        inv["number"], inv["kind"], inv["issue_date"], inv["payload"], _refs(inv["id"])
    )
    assert render_invoice_pdf(doc) == stored
    words = invoice_text(doc)
    assert "Prestations de services" in words and "Total TTC : 360,00\u00a0€" in words
    assert f"À régler par compensation sur le reversement {r['number']}" in words
    assert "Pas d'escompte pour paiement anticipé." in words
    # nothing left to draw; a second job does nothing
    with psycopg.connect(DB) as conn:
        assert (
            one(
                conn,
                "select count(*) from private.remittance_document_todo where organization_id = %s",
                (tenant["servicer"],),
            )
            == 0
        )
        with conn.transaction():
            assert run_documents(conn, storage(), {"organization_id": tenant["servicer"]}) == {
                "statements": 0,
                "invoices": 0,
            }


def test_the_files_are_the_same_in_another_process() -> None:
    """No clock and no environment reach the bytes: another interpreter renders them again."""
    tenant = remittance_tenant()
    paid_file(tenant, 12_345)
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    st = _statement(run)
    script = (
        "import json, sys;"
        " from collectoo_worker.remittance.statement_csv import render_statement_csv;"
        " from collectoo_worker.remittance.statement_pdf import render_statement_pdf;"
        " import hashlib; p = json.load(sys.stdin); c = render_statement_csv(p);"
        " h = hashlib.sha256(c).hexdigest();"
        " print(h, hashlib.sha256(render_statement_pdf(p, h)).hexdigest())"
    )
    out = subprocess.run(  # noqa: S603 - our own interpreter and code
        [sys.executable, "-c", script],
        input=json.dumps(st["payload"]),
        capture_output=True,
        text=True,
        check=True,
        env={"TZ": "Pacific/Auckland", "PATH": "/usr/bin", "RL_invariant": "0"},
    )
    assert out.stdout.split() == [st["csv_sha256"], st["pdf_sha256"]]


def test_a_due_invoice_prints_the_own_account_frozen_at_issue() -> None:
    """Without a netting clause the gross is remitted and the invoice is due (founder #3): its
    payment date and the own account as they were at issue, not as the settings say later."""
    terms = {**TERMS, "netting": None, "invoice_payment_days": 30}
    tenant = remittance_tenant(terms=terms)
    with psycopg.connect(DB) as conn, conn.transaction():
        own = one(
            conn,
            """insert into public.bank_account (organization_id, purpose, iban, currency, label,
                 opened_on) values (%s, 'own', 'FR7630006000011234567890189', 'EUR',
                 'Compte propre', '2026-01-01') returning id""",
            (tenant["servicer"],),
        )
        conn.execute(
            """insert into public.servicer_billing_settings (organization_id, own_bank_account_id)
               values (%s, %s) on conflict (organization_id)
               do update set own_bank_account_id = excluded.own_bank_account_id""",
            (tenant["servicer"], own),
        )
    paid_file(tenant, 100_000)
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    (inv,) = _invoice_docs(run)
    assert inv["payload"]["settlement"]["mode"] == "due" and inv["electronic"] is False
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "update public.servicer_billing_settings set penalty_text = 'Autre texte'"
            " where organization_id = %s",
            (tenant["servicer"],),
        )
    words = invoice_text(
        InvoiceDocument(inv["number"], inv["kind"], inv["issue_date"], inv["payload"], {})
    )
    assert "par virement sur le compte FR76 3000 6000 0112 3456 7890 189" in words
    assert "Autre texte" not in words and "Banque centrale européenne" in words
    assert (
        "Indemnité forfaitaire pour frais de recouvrement en cas de retard de paiement : "
        "40,00\u00a0€" in words
    )
    st = _statement(run)
    assert int(st["payload"]["totals"]["net_minor"]) == 100_000
    assert "À régler au plus tard le" in statement_text(st["payload"], st["csv_sha256"])


def test_a_cancelled_runs_credit_note_gets_its_pdf() -> None:
    tenant = remittance_tenant()
    paid_file(tenant, 50_000)
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    admin = add_admin(tenant)
    r = run_row(run)
    staff(
        tenant,
        "select public.cancel_remittance_run(%s, %s, %s, 'erreur de saisie')",
        str(uuid.uuid4()),
        run,
        r["version"],
        user=admin,
    )
    drain()
    docs = _invoice_docs(run)
    assert [d["kind"] for d in docs] == ["invoice", "credit_note"]
    assert all(d["pdf_sha256"] for d in docs)
    credit = docs[1]
    words = invoice_text(
        InvoiceDocument(
            credit["number"],
            "credit_note",
            credit["issue_date"],
            credit["payload"],
            _refs(credit["id"]),
        )
    )
    assert f"rectifiant la facture {docs[0]['number']}" in words
    assert words.startswith("Avoir\n")
    # the statement was drawn at approval, before the cancellation: it keeps its bytes
    st = _statement(run)
    assert st["payload"]["status"] == "approved"


def test_a_failed_upload_leaves_nothing_and_the_retry_draws_everything() -> None:
    tenant = remittance_tenant()
    paid_file(tenant, 7_000)
    run = request_run(tenant)
    approve(tenant, run)

    class Failing:
        def __init__(self) -> None:
            self.inner = storage()
            self.removed: list[str] = []

        def upload(self, bucket: str, path: str, data: bytes, content_type: str = "") -> None:
            if path.endswith(".pdf") and path.startswith("invoices/"):
                raise RuntimeError("storage down")
            self.inner.upload(bucket, path, data, content_type)

        def remove(self, bucket: str, paths: list[str]) -> None:
            self.removed += paths
            self.inner.remove(bucket, paths)

        def download(self, *a: Any) -> Any:  # pragma: no cover
            raise NotImplementedError

    # the approval job alone (the documents job is run by hand below)
    with psycopg.connect(DB) as conn:
        msgs = conn.execute(
            "select msg_id, message from pgmq.q_remittances where message ->> 'type' = 'approve'"
            " and message ->> 'run_id' = %s",
            (run,),
        ).fetchall()
    assert msgs
    from collectoo_worker.jobs.remittances import run_approve  # noqa: PLC0415

    with psycopg.connect(DB) as conn, conn.transaction():
        run_approve(conn, dict(msgs[0][1]))
        conn.execute("select pgmq.delete('remittances', %s)", (msgs[0][0],))
    failing = Failing()
    with pytest.raises(RuntimeError), psycopg.connect(DB) as conn, conn.transaction():
        run_documents(conn, failing, {"organization_id": tenant["servicer"]})
    assert failing.removed and all(
        p.startswith(("statements/", "invoices/")) for p in failing.removed
    )
    with psycopg.connect(DB) as conn:
        assert (
            one(conn, "select count(*) from public.remittance_statement where run_id = %s", (run,))
            == 0
        )
    drain()
    st = _statement(run)
    assert pdf_sha256(_download(st["pdf_path"])) == st["pdf_sha256"]
    (inv,) = _invoice_docs(run)
    assert inv["pdf_sha256"]


def test_the_next_run_day_matches_the_schedule() -> None:
    """The client space's « Prochain reversement prévu le … » (SQL) agrees with the pure schedule
    over two months of days (twice monthly; weekly on a Wednesday)."""
    from datetime import timedelta  # noqa: PLC0415

    from collectoo_worker.remittance.calendar import conservative  # noqa: PLC0415
    from collectoo_worker.remittance.schedule import is_scheduled  # noqa: PLC0415
    from collectoo_worker.remittance.terms import RemittanceTerms  # noqa: PLC0415

    cal = conservative()
    for terms in (TERMS, {**TERMS, "frequency": "weekly", "weekday": 3}):
        tenant = remittance_tenant(terms=terms)
        model = RemittanceTerms.model_validate(terms)
        with psycopg.connect(DB) as conn:
            start = one(conn, "select private.paris_today()")
            for k in range(60):
                day = start + timedelta(days=k)
                got = one(
                    conn,
                    "select private.next_scheduled_run_day(%s, %s)",
                    (tenant["client"], day),
                )
                want = next(
                    d
                    for d in (day + timedelta(days=i) for i in range(40))
                    if is_scheduled(model, d, cal)
                )
                assert got == want, (terms["frequency"], day)
