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

Review fixes (M2c-5 review): one document that cannot be drawn (the bucket refusing its CSV) is
recorded and retried while the others are drawn (perf#2); a run cancelled before its statement is
drawn sets nothing off (legal#2, figures#0); the earlier lines a run prices are in its statement as
the SQL builds them (tests-ui#4); a reversal credited by the run's credit note names it (figures#5).
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
    book_payout,
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
    assert st["template_version"] == "releve-reversement-fr-2"
    assert (st["gross_minor"], st["net_minor"], st["drawn_status"]) == (
        200_000,
        164_000,
        "approved",
    )
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
    assert inv["pdf_sha256"] is not None and inv["template_version"] == "facture-commission-fr-2"
    stored = _download(inv["storage_path"])
    assert pdf_sha256(stored) == inv["pdf_sha256"] == inv["sha256"]
    doc = InvoiceDocument(
        inv["number"], inv["kind"], inv["issue_date"], inv["payload"], _refs(inv["id"])
    )
    assert render_invoice_pdf(doc) == stored
    words = invoice_text(doc)
    assert "Prestations de services" in words and "Total TTC : 360,00\u00a0€" in words
    assert f"À régler par compensation sur le reversement {r['number']} : 360,00\u00a0€" in words
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


class _Refusing:
    """The storage, refusing some keys (the production bucket without `text/csv`, review perf#2)."""

    def __init__(self, refuse: str) -> None:
        self.inner = storage()
        self.refuse = refuse
        self.removed: list[str] = []

    def upload(self, bucket: str, path: str, data: bytes, content_type: str = "") -> None:
        if path.endswith(self.refuse):
            raise RuntimeError(f"mime type {content_type} is not supported")
        self.inner.upload(bucket, path, data, content_type)

    def remove(self, bucket: str, paths: list[str]) -> None:
        self.removed += paths
        self.inner.remove(bucket, paths)

    def download(self, *a: Any) -> Any:  # pragma: no cover
        raise NotImplementedError


def _approve_only(run: str) -> None:
    """The run's approval job alone (the documents job is run by hand afterwards)."""
    from collectoo_worker.jobs.remittances import run_approve  # noqa: PLC0415

    with psycopg.connect(DB) as conn:
        msgs = conn.execute(
            "select msg_id, message from pgmq.q_remittances where message ->> 'type' = 'approve'"
            " and message ->> 'run_id' = %s",
            (run,),
        ).fetchall()
    assert msgs
    with psycopg.connect(DB) as conn, conn.transaction():
        run_approve(conn, dict(msgs[0][1]))
        conn.execute("select pgmq.delete('remittances', %s)", (msgs[0][0],))


def _todo(servicer: str) -> list[tuple[str, int, str | None]]:
    with psycopg.connect(DB) as conn:
        return [
            (str(k), int(a), e)
            for k, a, e in conn.execute(
                """select kind, attempts, last_error from private.remittance_document_todo
                   where organization_id = %s order by kind, ref_id""",
                (servicer,),
            ).fetchall()
        ]


def test_a_document_that_cannot_be_drawn_never_blocks_the_others() -> None:
    """perf#2 (K4): the bucket refuses the statement's CSV — the statement's attempt is rolled back
    to its savepoint, what it uploaded removed, the failure recorded on its row; the invoice's PDF
    is drawn all the same and the job succeeds. The nightly alert names the failure; once the
    bucket accepts it, the retry draws the statement."""
    tenant = remittance_tenant()
    paid_file(tenant, 7_000)
    run = request_run(tenant)
    approve(tenant, run)
    _approve_only(run)
    refusing = _Refusing(".csv")
    with psycopg.connect(DB) as conn, conn.transaction():
        result = run_documents(conn, refusing, {"organization_id": tenant["servicer"]})
    assert (result["statements"], result["invoices"], result["failed"]) == (0, 1, 1)
    assert sorted(p.rsplit(".", 1)[1] for p in refusing.removed) == ["csv", "pdf"]
    ((kind, attempts, error),) = _todo(tenant["servicer"])
    assert (kind, attempts) == ("statement", 1) and error and "text/csv" in error
    (inv,) = _invoice_docs(run)
    assert inv["pdf_sha256"] and pdf_sha256(_download(inv["storage_path"])) == inv["pdf_sha256"]
    with psycopg.connect(DB) as conn:
        assert (
            one(conn, "select count(*) from public.remittance_statement where run_id = %s", (run,))
            == 0
        )
        # a second job draws nothing until the retry time: no head-of-line block, no busy loop
        with conn.transaction():
            assert run_documents(conn, storage(), {"organization_id": tenant["servicer"]}) == {
                "statements": 0,
                "invoices": 0,
            }
        with conn.transaction():
            check = conn.execute(
                "select private.run_payment_checks(%s)", (tenant["servicer"],)
            ).fetchone()
        assert check is not None
        alert = conn.execute(
            """select count, details ->> 'statements' from public.payment_check_result
               where run_id = %s and code = 'remittance_document_failed'""",
            (check[0]["run_id"],),
        ).fetchone()
        assert alert == (1, "1")
        with conn.transaction():
            conn.execute(
                "update private.remittance_document_todo set next_attempt_at = clock_timestamp()"
                " where organization_id = %s",
                (tenant["servicer"],),
            )
            assert one(conn, "select private.queue_remittance_schedule()") >= 1
    drain()  # the hourly schedule queued the documents job: the bucket accepts it now
    st = _statement(run)
    assert pdf_sha256(_download(st["pdf_path"])) == st["pdf_sha256"]
    assert _todo(tenant["servicer"]) == []


def test_a_run_cancelled_before_its_statement_sets_nothing_off() -> None:
    """legal#2, figures#0: cancelled after its approval, before the documents job drew its
    statement — the statement says so: nothing transferred nor set off, the gross still owed; the
    invoice annulled by the cancellation's credit note, both with their PDFs."""
    tenant = remittance_tenant()
    paid_file(tenant, 50_000)
    run = request_run(tenant)
    approve(tenant, run)
    _approve_only(run)
    admin = add_admin(tenant)
    staff(
        tenant,
        "select public.cancel_remittance_run(%s, %s, %s, 'erreur de saisie')",
        str(uuid.uuid4()),
        run,
        run_row(run)["version"],
        user=admin,
    )
    drain()
    st = _statement(run)
    p = st["payload"]
    assert (p["status"], st["drawn_status"]) == ("cancelled", "cancelled")
    assert all(d["settles_minor"] == "0" for d in p["documents"]) and p["earlier_settled"] == []
    pos = p["position"]
    assert pos["owed_after_minor"] == pos["owed_before_minor"] == "50000"
    ttc = sum(int(d["ttc_minor"]) for d in p["documents"])
    assert int(pos["receivable_after_minor"]) == int(pos["receivable_before_minor"]) + ttc
    invoice, credit = p["documents"]
    assert (
        credit["reason"] == "run_cancelled"
        and invoice["cancelled_by"][0]["number"] == credit["number"]
    )
    text = statement_text(p, st["csv_sha256"])
    assert "Montant net" not in text and "présent reversement" not in text
    assert f"Annulée par l'avoir {credit['number']}" in text
    assert all(d["pdf_sha256"] for d in _invoice_docs(run))


def test_the_lines_a_run_prices_for_an_earlier_one_are_in_its_statement() -> None:
    """tests-ui#4: RV-1's commission is left pending (the client's identity incomplete); RV-2 prices
    it with its own collection on another file. RV-2's statement, as the SQL builds it: the earlier
    line at amount 0 naming RV-1, the « repricing » nature, every commission adding up to the
    invoice's HT, and the file with only that line counted apart."""
    tenant = remittance_tenant()
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "update public.billing_identity set is_professional = false where organization_id = %s",
            (tenant["client"],),
        )
    paid_file(tenant, 100_000)
    rv1 = request_run(tenant)
    assert run_row(rv1)["commission_blockers"] == ["client_identity_changed"]
    approve(tenant, rv1)
    drain()
    book_payout(rv1)
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "update public.billing_identity set is_professional = true where organization_id = %s",
            (tenant["client"],),
        )
    paid_file(tenant, 40_000)
    rv2 = request_run(tenant)
    approve(tenant, rv2)
    drain()
    r1, r2 = run_row(rv1), run_row(rv2)
    assert r2["status"] == "approved", r2["last_failure"]
    p = _statement(rv2)["payload"]
    cols = {name: i for i, name in enumerate(p["line_columns"])}
    own, earlier = p["lines"]
    assert (int(own[cols["amount_minor"]]), own[cols["from_run"]]) == (40_000, None)
    assert (int(earlier[cols["amount_minor"]]), earlier[cols["from_run"]]) == (0, r1["number"])
    assert earlier[cols["commission_state"]] == "charged"
    commissions = [int(x[cols["commission_minor"]]) for x in p["lines"]]
    assert commissions == [6_000, 15_000]  # 15 % of each collection, the earlier one priced now
    t = p["totals"]
    assert sum(commissions) == int(t["commission_ht_minor"]) == r2["invoice_ht_minor"]
    assert sum(int(f["commission_minor"]) for f in p["files"]) == int(t["commission_ht_minor"])
    assert (t["line_count"], t["repriced_count"], t["file_count"]) == (1, 1, 1)
    assert (len(p["files"]), t["repriced_only_file_count"]) == (2, 1)
    (rep_nature,) = [n for n in p["natures"] if n["kind"] == "repricing"]
    assert (rep_nature["count"], rep_nature["amount_minor"], rep_nature["commission_minor"]) == (
        "1",
        "0",
        "15000",
    )
    rows = list(
        csv.reader(
            io.StringIO(render_statement_csv(p).decode("utf-8-sig"), newline=""), delimiter=";"
        )
    )[1:]
    assert (
        rows[1][CSV_HEADER.index("nature")]
        == f"Commission sur un encaissement du relevé {r1['number']}"
    )
    assert rows[1][CSV_HEADER.index("montant_centimes")] == "0"
    assert "1 dossier(s) du tableau n'ont pas d'encaissement" in statement_text(p, "0" * 64)


def test_a_reversal_names_the_credit_note_that_credits_it() -> None:
    """figures#5: a collection of RV-1 undone in RV-2 is credited by RV-2's credit note; the CSV's
    `facture` of that line is the credit note (the SQL builder's own shape)."""
    tenant = remittance_tenant()
    f42, p1 = paid_file(tenant, 200_000)
    rv1 = request_run(tenant)
    approve(tenant, rv1)
    drain()
    book_payout(rv1)
    paid_file(tenant, 300_000)
    with psycopg.connect(DB) as conn:
        e2 = one(
            conn,
            "select id from public.ledger_entry where payment_id = %s"
            " and entry_type = 'allocation'",
            (p1,),
        )
    staff(
        tenant,
        "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
        str(uuid.uuid4()),
        p1,
        f42.id,
        [str(e2)],
        "paiement repris par la banque",
    )
    rv3 = request_run(tenant)
    approve(tenant, rv3)
    drain()
    p = _statement(rv3)["payload"]
    cols = {name: i for i, name in enumerate(p["line_columns"])}
    credit = next(d["number"] for d in p["documents"] if d["kind"] == "credit_note")
    reversal = next(x for x in p["lines"] if int(x[cols["amount_minor"]]) < 0)
    assert int(reversal[cols["commission_minor"]]) < 0
    assert reversal[cols["invoice"]] == credit


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
