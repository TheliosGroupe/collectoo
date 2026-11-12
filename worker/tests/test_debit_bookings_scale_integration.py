"""M2c-6b-1 scale (needs `make up`; plan docs/design/m2c-6b-plan.md §1.4; review T6): 5,000 payouts
booked from the bank statement.

The fixture: K + 50 clients created set-based (as pgTAP 035's fixture: each its mandate with
complete terms, 15 % flat with netting; its confirmed payout account; one file with its RF
reference and opening balance); a statement paying each file by its RF imported, matched and
allocated through the payments queue; a run per client requested (the command, set-based),
prepared and approved through the remittances jobs (a few consumers; the documents jobs the
approval queues are left off: they render PDFs and touch no booking); 50 runs cancelled before any
file (their transfers `cancelled`); « Générer le fichier » files the K payouts, the job writes it,
ops download it. The statistics of the tables the bookings read are forgotten first (the state CI
meets). Then:

(b) the file's PmtInf debited as one batch line (no end-to-end id: one booking per member, the
    set-based settlements, the seq row_number, the completeness check on the line's highest seq):
    the funds pass in one transaction, timed, its reads counted, then rolled back;
(a) a statement of the file's K debits, one line per RMT end-to-end id, imported: the debit job
    (the M2b pass, then the funds pass in chunks of 2,000 lines, each its own message), timed per
    chunk from the job's log, its reads counted;

then the nightly checks with the K booked payouts and the 50 cancelled transfers. Targets (plan
§1.4): each funds chunk < 60 s, the job < 120 s, a bounded number of reads of `bank_transfer`,
`transfer_file_item` and `bank_line_booking` per transfer, the nightly checks < 5 s with 0
violations, the checks' reads keyed by the servicer (rows read per table bounded by its own rows,
none of another servicer's read by a sequential scan). Each measured pass runs with the statistics
of the tables it reads forgotten and kept so (autovacuum off on them meanwhile): the bounds on its
reads hold in the state CI meets, not by chance (review round 2, P2).

Review round 2 (P1, P4): a second fixture of SMALL = 200 payouts (plan §1.4: « 200 RMT/SWP lines
≈ 1 s »): their PmtInf as one batch line, its reads bounded per member (the batch rule was n² at a
few hundred members), then their 200 RMT lines in one funds pass, timed. PAYOUT_SMALL_SIZE
changes it."""

import hashlib
import json
import logging
import os
import random
import re
import threading
import time
import uuid
from datetime import date
from typing import Any

import psycopg
import pytest
from debit_helpers import violations
from integration_helpers import DB, SCHEDULE, TERMS, as_user, one, storage
from psycopg.types.json import Jsonb
from reconciliation_helpers import pay
from remittance_helpers import (
    paris_today,
    recent_business_day,
    remittance_tenant,
    run_row,
    staff,
)
from statement_helpers import upload
from stats_helpers import forget_statistics, frozen_statistics
from test_transfer_files_scale_integration import (
    assert_checks_bounded,
    assert_checks_keyed,
    checks_with_reads,
    checks_work,
)

from collectoo_worker.jobs.debits import run_process_debits
from collectoo_worker.jobs.payments import make_handler as payments_handler
from collectoo_worker.jobs.payments import record_dead_job as payments_dead
from collectoo_worker.jobs.remittances import make_handler, record_dead_job
from collectoo_worker.payments.rf import rf_make
from collectoo_worker.remittance import pain001
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.synth.camt053 import debits_of, make_doc, render_camt053
from collectoo_worker.synth.ids import iban_fr
from collectoo_worker.synth.reconciliation import Credit

pytestmark = pytest.mark.integration
SIZE = int(os.environ.get("PAYOUT_FILE_SIZE", "5000"))
CANCELLED = min(50, max(SIZE // 10, 1))
CONSUMERS = 4
SMALL = int(os.environ.get("PAYOUT_SMALL_SIZE", "200"))
READS = ("public.bank_transfer", "public.transfer_file_item", "public.bank_line_booking")
# the tables whose statistics each measured pass forgets (and keeps forgotten), and those whose
# reads it records
FROZEN = (*READS, "public.client_advance", "public.remittance_run")
SEEN = (*FROZEN, "public.remittance_line", "public.transfer_file", "public.client_payout_account")
FUNDS_LOG = re.compile(r"\(funds\): (\d+) lines, (\d+) bookings, .* ([0-9.]+)s$")
OFFICE = '{"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris", "country": "FR"}'


def _clients(tenant: dict[str, Any], n: int) -> tuple[list[str], list[Credit]]:
    """n clients of the tenant's servicer, set-based (pgTAP 035's fixture, sized): each its
    billing identity, portfolio, mandate and complete terms, confirmed payout account and one
    file (its debtor, invoice, ownership, RF reference and opening balance). Their ids, and the
    credit paying each file by its RF."""
    org, staff_id, admin = str(tenant["servicer"]), tenant["staff"], tenant["admin"]
    ks = list(range(1, n + 1))
    rfs = [rf_make(f"{k:012d}") for k in ks]
    ibans = [iban_fr(random.Random(f"scale-payout-{org}-{k}")) for k in ks]
    amounts = [10_000 + 37 * k for k in ks]
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            """create temp table _k on commit drop as
               select x.n, x.iban, x.rf, x.amount, gen_random_uuid() as client,
                      gen_random_uuid() as portfolio, gen_random_uuid() as mandate,
                      gen_random_uuid() as doc_m, gen_random_uuid() as doc_r,
                      gen_random_uuid() as payout, gen_random_uuid() as account,
                      gen_random_uuid() as item, gen_random_uuid() as party
               from unnest(%s::int[], %s::text[], %s::text[], %s::bigint[])
                 x (n, iban, rf, amount)""",
            (ks, ibans, rfs, amounts),
        )
        for sql, params in (
            (
                """insert into public.organization (id, kind, servicer_organization_id,
                     legal_name, siren)
                   select client, 'creditor_client', %s, 'Client échelle ' || n, '552100554'
                   from _k""",
                (org,),
            ),
            (
                """insert into public.billing_identity (organization_id, registered_office,
                     is_professional) select client, %s::jsonb, true from _k""",
                (OFFICE,),
            ),
            (
                """insert into public.portfolio (id, organization_id, client_organization_id, name)
                   select portfolio, %s, client, 'P' from _k""",
                (org,),
            ),
            (
                """insert into public.document (id, organization_id, client_organization_id, kind,
                     storage_path, sha256, mime_type)
                   select d.id, %s, k.client, d.kind, 'client/test/' || d.id || '.pdf',
                          repeat('a', 64), 'application/pdf'
                   from _k k cross join lateral (values (k.doc_m, 'mandate_document'),
                                                        (k.doc_r, 'payout_rib')) d (id, kind)""",
                (org,),
            ),
            (
                """insert into public.mandate (id, organization_id, client_organization_id,
                     reference, mandate_type, signed_on, insurance_clause_ref)
                   select mandate, %s, client, 'MAND-SC-' || n, 'mandate_amicable', '2026-01-01',
                          'art. 9'
                   from _k""",
                (org,),
            ),
            (
                """insert into public.mandate_terms (mandate_id, valid_from, commission_schedule,
                     commission_clause_ref, remittance_terms, remittance_clause_ref, document_id)
                   select mandate, '2026-01-01', %s::jsonb, 'art. 6', %s::jsonb, 'art. 7', doc_m
                   from _k""",
                (json.dumps(SCHEDULE), json.dumps(TERMS)),
            ),
            (
                """update public.portfolio p set mandate_id = k.mandate from _k k
                   where p.id = k.portfolio""",
                (),
            ),
            (
                """insert into public.client_payout_account (id, organization_id,
                     client_organization_id, currency, iban, holder_name, evidence_document_id,
                     proposed_by)
                   select payout, %s, client, 'EUR', iban, 'CLIENT ECHELLE ' || n, doc_r, %s
                   from _k""",
                (org, staff_id),
            ),
            (
                """update public.client_payout_account a set status = 'active',
                     confirmed_at = now(), confirmed_via = 'second_admin', confirmed_by = %s
                   from _k k where a.id = k.payout""",
                (admin,),
            ),
            (
                """insert into public.account (id, organization_id, client_organization_id,
                     portfolio_id, claim_type_code, external_ref, legal_regime, currency, status)
                   select account, %s, client, portfolio, 'b2b_invoice', 'SC-' || n,
                          'commercial_b2b', 'EUR', 'in_collection'
                   from _k""",
                (org,),
            ),
            (
                """insert into public.party (id, organization_id, client_organization_id, kind,
                     display_name)
                   select party, %s, client, 'legal_entity', 'Débiteur ' || n from _k""",
                (org,),
            ),
            (
                """insert into public.account_party (account_id, party_id, role, capacity)
                   select account, party, 'borrower', 'legal_entity' from _k""",
                (),
            ),
            (
                """insert into public.claim_item (id, account_id, kind, ref, issue_date, due_date,
                     original_minor)
                   select item, account, 'invoice', 'INV-1', '2026-08-01', '2026-09-01', amount
                   from _k""",
                (),
            ),
            (
                """insert into public.claim_ownership_period (account_id, owner_organization_id,
                     servicer_organization_id, mandate_type, valid_from)
                   select account, client, %s, 'mandate_amicable', '2026-09-30' from _k""",
                (org,),
            ),
            (
                """insert into public.payment_reference (organization_id, client_organization_id,
                     portfolio_id, account_id, rf)
                   select %s, client, portfolio, account, rf from _k""",
                (org,),
            ),
        ):
            conn.execute(sql, params)
        clients = [str(r[0]) for r in conn.execute("select client from _k order by n").fetchall()]
        files = conn.execute("select account, item, amount from _k order by n").fetchall()
    # the openings, 200 files a transaction (private.ledger_post creates its working tables per
    # call: thousands in one transaction run out of lock slots)
    opened = 0
    for k in range(0, n, 200):
        with psycopg.connect(DB) as conn, conn.transaction():
            opened += one(
                conn,
                """select count(*) from unnest(%s::uuid[], %s::uuid[], %s::bigint[])
                     f (account, item, amount)
                   cross join lateral private.ledger_post(%s, 'adjustment', '2026-09-30',
                     'opening:' || f.account,
                     jsonb_build_array(
                       jsonb_build_object('book', 'debtor_receivable', 'amount_minor', f.amount,
                                          'currency', 'EUR', 'claim_item_id', f.item,
                                          'component', 'principal'),
                       jsonb_build_object('book', 'owner_claim', 'amount_minor', -f.amount,
                                          'currency', 'EUR', 'component', 'principal')),
                     jsonb_build_object('account_id', f.account,
                                        'reason', 'ouverture (test d''échelle)')) e""",
                (
                    [str(f[0]) for f in files[k : k + 200]],
                    [str(f[1]) for f in files[k : k + 200]],
                    [int(f[2]) for f in files[k : k + 200]],
                    org,
                ),
            )
    assert opened == n
    credits = [
        Credit(a, f"PAYEUR {k}", None, ("VIREMENT",), rf, None, "auto", "allocation")
        for k, a, rf in zip(ks, amounts, rfs, strict=True)
    ]
    return clients, credits


def _drain_remittances() -> None:
    """The remittances queue drained by a few consumers (the prepare jobs run side by side; the
    approvals serialise on their locks); the documents jobs taken off unrun."""
    handle = make_handler(storage())

    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        if payload.get("type") != "documents":
            handle(payload, conn)

    def consume() -> None:
        consumer = QueueConsumer(DB, "remittances", handler, on_dead=record_dead_job)
        while consumer.poll_once():
            pass

    threads = [threading.Thread(target=consume) for _ in range(CONSUMERS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    consume()  # what a consumer left invisible a moment


def _drain_payments(*, debits: bool = True) -> None:
    """The payments queue; `debits=False`: the debit job's messages taken off unrun."""
    handle = payments_handler(storage())

    def handler(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        if debits or payload.get("type") != "process_debits":
            handle(payload, conn)

    consumer = QueueConsumer(DB, "payments", handler, on_dead=payments_dead)
    while consumer.poll_once():
        pass


def _reads(seq: bool = False) -> dict[str, int]:
    """Rows of each table the bookings read, since the statistics were last reset (every
    backend's, flushed); `seq`: those read by sequential scans only."""
    with psycopg.connect(DB) as conn:
        conn.execute("select pg_stat_force_next_flush()")
        rows = conn.execute(
            """select relid::regclass::text,
                      case when %s then coalesce(seq_tup_read, 0)
                           else coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) end
               from pg_stat_user_tables where relid = any(%s::regclass[])""",
            (seq, list(SEEN)),
        ).fetchall()
    return {("public." + r[0]).replace("public.public.", "public."): int(r[1]) for r in rows}


def _xact_reads(conn: psycopg.Connection[Any], seq: bool = False) -> dict[str, int]:
    """The same, read by this transaction alone."""
    rows = conn.execute(
        """select relid::regclass::text,
                  case when %s then coalesce(seq_tup_read, 0)
                       else coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) end
           from pg_stat_xact_user_tables where relid = any(%s::regclass[])""",
        (seq, list(SEEN)),
    ).fetchall()
    return {("public." + r[0]).replace("public.public.", "public."): int(r[1]) for r in rows}


def _runs(tenant: dict[str, Any], clients: list[str]) -> list[str]:
    """A run per client, requested by ops (set-based, as one session would issue the commands),
    prepared and approved through the remittances jobs."""
    runs: list[str] = []
    for k in range(0, len(clients), 500):  # 500 commands a transaction
        with psycopg.connect(DB) as conn, conn.transaction():
            as_user(conn, tenant["staff"], "aal2")
            runs += [
                str(r[0])
                for r in conn.execute(
                    """select (public.request_remittance_run('scale-rq-' || c.id, c.id, 'EUR')
                               ->> 'run_id')::uuid
                       from unnest(%s::uuid[]) with ordinality c (id, n) order by n""",
                    (clients[k : k + 500],),
                ).fetchall()
            ]
    requested = time.monotonic()
    _drain_remittances()  # the prepare jobs
    prepared = time.monotonic()
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select id::text, inputs_hash, net_minor::text from public.remittance_run
               where id = any(%s::uuid[]) and status = 'draft' and prepared_at is not null""",
            (runs,),
        ).fetchall()
    assert len(rows) == len(runs), (len(rows), len(runs))
    for k in range(0, len(rows), 200):  # « Valider »: 200 runs a command
        items = [{"run_id": r, "inputs_hash": h, "net_text": t} for r, h, t in rows[k : k + 200]]
        out = staff(
            tenant,
            "select public.approve_remittance_runs(%s, %s)",
            str(uuid.uuid4()),
            json.dumps(items),
        )
        assert {x["status"] for x in out["results"]} == {"queued"}, out
    commanded = time.monotonic()
    _drain_remittances()  # the approval jobs
    print(
        f"\n{len(runs)} runs: prepare jobs {prepared - requested:.1f}s, approval commands"
        f" {commanded - prepared:.1f}s, approval jobs {time.monotonic() - commanded:.1f}s"
    )
    with psycopg.connect(DB) as conn:
        approved = one(
            conn,
            "select count(*) from public.remittance_run where id = any(%s::uuid[])"
            " and status = 'approved'",
            (runs,),
        )
    assert approved == len(runs)
    return runs


# keyed reads per transfer, at most (ARCHITECTURE §4: every probe keyed). Measured at 5,000
# (2026-11-12): an RMT line, 10 of bank_transfer (the candidates' composite row, the re-check's
# laterals, the guard's four, the settlement and the cover), 2 of transfer_file_item, 3 of
# bank_line_booking; a batch line's member 12, 6 (the PmtInf's items, read by the candidates and by
# the batch rule) and 3
PER_TRANSFER = {
    "public.bank_transfer": 16,
    "public.transfer_file_item": 4,
    "public.bank_line_booking": 4,
}
PER_MEMBER = {**PER_TRANSFER, "public.transfer_file_item": 8}
SLACK = 1_000  # the other sessions' reads in the window (statistics flushed late)
XACT_SLACK = 50  # one transaction's own reads: no other session in them
# plan §1.4: « 200 RMT/SWP lines ≈ 1 s » in one funds pass. Measured (review round 2, P4) on the
# 200-payout fixture, the 4-vCPU VM shared with another stack: 0.6 to 0.9 s in five runs (the job's
# log, to 0.1 s; docs/benchmarks/remittances.md); the bound keeps twice the worst
SMALL_FUNDS_PASS_S = 2.0


def _file_payouts(
    factory: pytest.TempPathFactory, size: int, cancelled: int, label: str
) -> dict[str, Any]:
    """size + cancelled clients' runs approved through the jobs, `cancelled` of them cancelled
    before any file, the file of the `size` payouts generated, written and downloaded."""
    timings: dict[str, float] = {}
    started = time.monotonic()
    tenant = remittance_tenant()  # its servicer's identity complete, an admin
    clients, credits = _clients(tenant, size + cancelled)
    timings["clients"] = time.monotonic() - started
    mark = time.monotonic()
    pay(tenant, storage(), credits, prefix=f"K{uuid.uuid4().hex[:5].upper()}",
        start=recent_business_day(), days=1)  # fmt: skip
    timings["collections"] = time.monotonic() - mark
    mark = time.monotonic()
    runs = _runs(tenant, clients)
    timings["runs"] = time.monotonic() - mark
    for r in runs[size:]:  # cancelled before any file: their transfers `cancelled`
        out = staff(
            tenant,
            "select public.cancel_remittance_run(%s, %s, %s, %s)",
            str(uuid.uuid4()),
            r,
            run_row(r)["version"],
            "Test d'échelle",
            user=tenant["admin"],
        )
        assert out["status"] == "cancelled", out
    mark = time.monotonic()
    generated = staff(
        tenant, "select public.generate_transfer_file(%s, %s, null)", str(uuid.uuid4()),
        tenant["bank"],
    )  # fmt: skip
    timings["generate"] = time.monotonic() - mark
    assert generated["nb_of_txs"] == size and generated["held"] == [], generated
    _drain_remittances()  # the transfer_file job
    with psycopg.connect(DB) as conn:
        path, digest = conn.execute(
            "select storage_path, file_sha256 from public.transfer_file where id = %s",
            (generated["file_id"],),
        ).fetchone() or (None, None)
    dest = factory.mktemp(label) / "payouts.xml"
    storage().download("transfer-files", str(path), dest)
    data = dest.read_bytes()
    assert hashlib.sha256(data).hexdigest() == digest
    staff(tenant, "select public.transfer_file_download(%s, %s)", generated["file_id"], digest)
    payouts = pain001.read(data)
    assert payouts.nb_of_txs == size
    print(
        f"\n{size} payouts (+{cancelled} cancelled), the fixture: clients"
        f" {timings['clients']:.1f}s, collections {timings['collections']:.1f}s, runs"
        f" requested/prepared/approved {timings['runs']:.1f}s; « Générer le fichier »"
        f" {timings['generate']:.2f}s"
    )
    return {
        "size": size,
        "cancelled": cancelled,
        "tenant": tenant,
        "org": str(tenant["servicer"]),
        "file_id": str(generated["file_id"]),
        "payouts": payouts,
        "paid": runs[:size],
    }


@pytest.fixture(scope="module")
def filed(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """K + 50 clients' runs, 50 cancelled before any file, the file of the K payouts."""
    return _file_payouts(tmp_path_factory, SIZE, CANCELLED, "payouts")


@pytest.fixture(scope="module")
def filed_small(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """SMALL clients' runs (plan §1.4's 200 lines; review round 2, P1 and P4), their file."""
    return _file_payouts(tmp_path_factory, SMALL, 0, "small")


def _statement(conn: psycopg.Connection[Any], filed: dict[str, Any], name: str) -> str:
    st = one(
        conn,
        """insert into public.bank_statement (organization_id, bank_account_id, currency,
             format, file_name, file_sha256, size_bytes, storage_path)
           values (%s, %s, 'EUR', 'camt053', %s, %s, 1, %s) returning id""",
        (filed["org"], filed["tenant"]["bank"], name, uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
    )
    conn.execute(
        "update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = %s",
        (st,),
    )
    return str(st)


def _batch_pass(filed: dict[str, Any]) -> tuple[float, int, dict[str, int], dict[str, int]]:
    """Each PmtInf of the file debited as one batch line (no end-to-end id), the funds pass in one
    transaction with the statistics of the tables it reads forgotten (and kept so: autovacuum off
    on them meanwhile), then rolled back: its time, the payouts it booked, its reads (keyed and by
    sequential scans) — this transaction's own."""
    org, tenant, payouts = filed["org"], filed["tenant"], filed["payouts"]
    with frozen_statistics(*FROZEN), psycopg.connect(DB) as conn:
        for t in FROZEN:
            forget_statistics(t)
        try:
            st = _statement(conn, filed, "batch.xml")
            for n, p in enumerate(payouts.payment_infos, start=1):
                conn.execute(
                    """insert into public.bank_transaction (organization_id, bank_account_id,
                         statement_id, line_no, dedup_key, direction, amount_minor, currency,
                         booking_date, kind, payment_info_id)
                       values (%s, %s, %s, %s, %s, 'debit', %s, 'EUR', private.paris_today(),
                               'batch_unsplit', %s)""",
                    (org, tenant["bank"], st, n, f"t:{st}:{n}", p.ctrl_sum_minor, p.pmt_inf_id),
                )
            conn.execute(
                """update public.bank_statement set status = 'imported',
                     from_date = private.paris_today(), to_date = private.paris_today(),
                     opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
                     finished_at = now() where id = %s""",
                (st,),
            )
            before, seq_before = _xact_reads(conn), _xact_reads(conn, seq=True)
            mark = time.monotonic()
            summary = run_process_debits(conn, {"organization_id": org, "funds_after": None})
            elapsed = time.monotonic() - mark
            after, seq_after = _xact_reads(conn), _xact_reads(conn, seq=True)
            booked = one(
                conn,
                """select count(*) from public.bank_line_booking b
                   join public.bank_transaction l on l.id = b.bank_transaction_id
                   where l.statement_id = %s and b.kind = 'payout'""",
                (st,),
            )
        finally:
            conn.rollback()
    assert booked == filed["size"], summary
    reads = {t: after.get(t, 0) - before.get(t, 0) for t in SEEN}
    seq_reads = {t: seq_after.get(t, 0) - seq_before.get(t, 0) for t in SEEN}
    return elapsed, int(booked), reads, seq_reads


def _rmt_pass(
    filed: dict[str, Any], caplog: pytest.LogCaptureFixture
) -> tuple[float, float, list[tuple[int, int, float]], dict[str, int], dict[str, int], date]:
    """The statement of the file's debits, one line per RMT end-to-end id, imported; the debit
    job (the M2b pass, then the funds pass in chunks of 2,000 lines, each its own message), with
    the statistics of the tables the funds pass reads forgotten and kept so: the import's time,
    the job's, the funds chunks (lines, bookings, s), the reads of every session meanwhile (keyed
    and by sequential scans), the debit day."""
    caplog.set_level(logging.INFO, logger="collectoo.payments")
    tenant, payouts = filed["tenant"], filed["payouts"]
    with psycopg.connect(DB) as conn:
        opening, last = conn.execute(
            """select closing_booked_minor, to_date from public.bank_statement
               where bank_account_id = %s and status = 'imported'
               order by to_date desc, created_at desc limit 1""",
            (tenant["bank"],),
        ).fetchone() or (0, None)
    day = max(paris_today(), last)
    entries = debits_of(payouts, booking_date=day, ref_prefix=f"P{uuid.uuid4().hex[:5].upper()}")
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(entries, iban=tenant["iban"], from_date=day, to_date=day,
                   opening_minor=int(opening), stmt_id=stmt)  # fmt: skip
    mark = time.monotonic()
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{stmt}.xml")
    _drain_payments(debits=False)  # the import; its debit job's message taken off
    imported = time.monotonic() - mark
    with frozen_statistics(*FROZEN):
        for t in FROZEN:
            forget_statistics(t)
        with psycopg.connect(DB) as conn, conn.transaction():
            conn.execute(
                "select pgmq.send('payments', %s)",
                (Jsonb({"type": "process_debits", "organization_id": filed["org"]}),),
            )
        caplog.clear()
        time.sleep(1.5)  # the statistics of the import's sessions flushed first
        reads_before, seq_before = _reads(), _reads(seq=True)
        mark = time.monotonic()
        _drain_payments()
        book_s = time.monotonic() - mark
        reads_after, seq_after = _reads(), _reads(seq=True)
    for t in FROZEN:  # as the fixture left them (the analysis on leaving the block undone)
        forget_statistics(t)
    reads = {t: reads_after.get(t, 0) - reads_before.get(t, 0) for t in SEEN}
    seq_reads = {t: seq_after.get(t, 0) - seq_before.get(t, 0) for t in SEEN}
    chunks = [
        (int(m.group(1)), int(m.group(2)), float(m.group(3)))
        for r in caplog.records
        if (m := FUNDS_LOG.search(r.getMessage()))
    ]
    return imported, book_s, chunks, reads, seq_reads, day


def _booked(filed: dict[str, Any], day: date) -> tuple[int, int, int, int, int]:
    with psycopg.connect(DB) as conn:
        return conn.execute(
            """select (select count(*) from public.bank_line_booking b
                       join public.bank_transfer t on t.id = b.transfer_id
                       where t.transfer_file_id = %s and b.kind = 'payout'),
                      (select count(distinct b.transfer_id) from public.bank_line_booking b
                       join public.bank_transfer t on t.id = b.transfer_id
                       where t.transfer_file_id = %s and b.kind = 'payout'),
                      (select count(*) from public.remittance_run
                       where id = any(%s::uuid[]) and status = 'booked' and booked_on = %s),
                      (select count(*) from public.ledger_entry
                       where source_id = any(%s::text[]) and entry_type = 'client_settlement'),
                      (select count(*) from public.bank_transfer
                       where organization_id = %s and kind = 'payout' and status = 'cancelled')""",
            (filed["file_id"], filed["file_id"], filed["paid"], day, filed["paid"], filed["org"]),
        ).fetchone() or (0, 0, 0, 0, 0)


# a table of a few hundred rows (the 200-payout fixture's, alone in a fresh database) read whole by
# a sequential scan is the planner's right choice; every servicer's 5,000 transfers never are
TINY_TABLE = 1_000


def _no_whole_table(seq_reads: dict[str, int]) -> None:
    """ARCHITECTURE §4: the funds pass reads transfers by key only, whatever the statistics (a
    sequential scan reads every servicer's transfers, once per chunk) — the tables of transfers
    read by a sequential scan only while they are tiny."""
    over = {t: seq_reads[t] for t in READS if seq_reads[t] > TINY_TABLE}
    assert over == {}, seq_reads


def test_a_batch_line_of_200_members_reads_each_member_a_bounded_number_of_times(
    filed_small: dict[str, Any],
) -> None:
    """Review round 2, P1: a batch line of a few hundred members, booked in one funds pass, reads
    each member's item and transfer a bounded number of times (the batch rule's grouped members
    were re-read once per row of the line: 150 members read 23,250 items, n²)."""
    n = filed_small["size"]
    elapsed, booked, reads, seq_reads = _batch_pass(filed_small)
    print(
        f"\n(P1) a batch line of {n} members: the funds pass {elapsed:.2f}s, reads {reads}"
        f" (by sequential scans {seq_reads})"
    )
    assert booked == n
    for t, per in PER_MEMBER.items():
        assert reads[t] <= per * n + XACT_SLACK, (t, reads)
    _no_whole_table(seq_reads)


def test_200_rmt_debits_in_one_funds_pass(
    filed_small: dict[str, Any], caplog: pytest.LogCaptureFixture
) -> None:
    """Review round 2, P4 — plan §1.4: « 200 RMT/SWP lines ≈ 1 s ». The statement of the 200
    payouts' debits (one line per RMT id) imported, the debit job: one funds pass books them
    (an SWP line takes the same rules and reads: the sweep's transfer, by its id), each transfer
    read by key, none by a sequential scan."""
    n = filed_small["size"]
    imported, book_s, chunks, reads, seq_reads, day = _rmt_pass(filed_small, caplog)
    assert _booked(filed_small, day) == (n, n, n, n, 0)
    print(
        f"\n(P4) {n} RMT debits: import {imported:.1f}s; the debit job {book_s:.2f}s, funds"
        f" chunks (lines, bookings, s) {chunks}, reads {reads} (by sequential scans {seq_reads})"
    )
    assert [(lines, bookings) for lines, bookings, _ in chunks] == [(n, n)], chunks
    assert chunks[0][2] <= SMALL_FUNDS_PASS_S, chunks
    for t, per in PER_TRANSFER.items():
        assert reads[t] <= per * n + SLACK, (t, reads)
    _no_whole_table(seq_reads)


def test_the_file_s_pmt_inf_as_one_batch_line_books_every_member(filed: dict[str, Any]) -> None:
    """(b) Each PmtInf of the file debited as one batch line (no end-to-end id): one booking per
    member, in one funds pass (one transaction: the set-based settlements, the seq row_number,
    the completeness check on the line's highest seq), timed and counted, then rolled back (the
    statement's RMT lines, test (a), book the file for real)."""
    elapsed, booked, reads, seq_reads = _batch_pass(filed)
    filed["batch_seq_reads"] = seq_reads
    print(
        f"\n(b) {len(filed['payouts'].payment_infos)} batch line(s) of {SIZE} members: the funds"
        f" pass {elapsed:.1f}s, reads {reads} (by sequential scans {seq_reads})"
    )
    assert booked == SIZE
    # plan §1.4: within a minute, each member read by key a bounded number of times
    assert elapsed < 60, elapsed
    for t, per in PER_MEMBER.items():
        assert reads[t] <= per * SIZE + XACT_SLACK, (t, reads, seq_reads)


def test_5000_rmt_debits_booked_by_the_debit_job_then_the_nightly_checks(
    filed: dict[str, Any], caplog: pytest.LogCaptureFixture
) -> None:
    """(a) The statement of the file's K debits, one line per RMT end-to-end id, imported; the
    debit job (the M2b pass, then the funds pass in chunks of 2,000 lines, each its own message)
    books every payout once, its run settled; then the nightly checks with the K booked payouts
    and the 50 cancelled transfers."""
    imported, book_s, chunks, reads, seq_reads, day = _rmt_pass(filed, caplog)
    filed["seq_reads"] = seq_reads
    assert _booked(filed, day) == (SIZE, SIZE, SIZE, SIZE, CANCELLED)
    run, nightly_s, check_reads = checks_with_reads(filed["tenant"])
    assert violations(str(run["run_id"])) == []
    print(
        f"\n(a) {SIZE} RMT debits: import {imported:.1f}s; the debit job {book_s:.1f}s, funds"
        f" chunks (lines, bookings, s) {chunks}, reads {reads} (by sequential scans"
        f" {seq_reads}); nightly checks with {SIZE}"
        f" booked payouts and {CANCELLED} cancelled transfers {nightly_s:.2f}s"
        f" (rows read: {check_reads})"
    )
    # plan §1.4: each chunk within a minute, the job within two (the queue's visibility: 300 s)
    assert chunks and sum(n for n, _, _ in chunks) == SIZE, chunks
    assert all(sec < 60 for _, _, sec in chunks), chunks
    assert book_s < 120, book_s
    for t, per in PER_TRANSFER.items():  # keyed: the reads per transfer
        assert reads[t] <= per * SIZE + SLACK, (t, reads, seq_reads)
    assert_checks_keyed(filed["org"], check_reads)
    assert_checks_bounded(filed["org"], checks_work(filed["tenant"]))
    assert nightly_s < 5, nightly_s


def test_the_funds_pass_reads_no_table_of_transfers_in_full(filed: dict[str, Any]) -> None:
    """ARCHITECTURE §4 for (a) and (b), review round 2 (P2): with the statistics of the tables
    it reads forgotten (and kept so during the pass), the funds pass reads no table of transfers
    by a sequential scan — the update of the transfers booked included (it hashed every
    servicer's transfers, once per chunk: 15,150 rows read for 5,050 transfers)."""
    _no_whole_table(filed["batch_seq_reads"])
    _no_whole_table(filed["seq_reads"])
