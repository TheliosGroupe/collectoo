"""M2c-6b-3a-2 scale (tests-7, ADR-0014 « M2c-6b-3a review fixes » round 1, left to 6b-3a-2; needs
`make up`): transfers cancelled out of a downloaded file and re-issued, beside a large downloaded
file, with the cancellation after download switched on **inside the test's one transaction**
(rolled back: the switch is never committed on, ADR-0014 « M2c-6b-3a-2 »).

SIZE + CANCELLED unidentified credits are imported on one statement and each is refunded in a
transfer file: a first file of CANCELLED refunds (F2), then one of SIZE (F1), both generated,
written by the job and downloaded (the switch off: nothing of it needs the switch). Both files are
dated back to X (« time moved on », as pgTAP 039's fixtures do), and a statement covering X and the
business day after it, produced after them, shows no debit: neither file was executed. Then, in one
transaction with the switch on: F2's cancellation is asked by the ops manager and confirmed by an
admin (its CANCELLED refunds cancelled out of a downloaded file and re-issued); a later statement
shows half of them debited late all the same (by their own end-to-end ids). Timed there, each once:

- the evidence of the large file (`private.transfer_cancel_evidence(F1)`: SIZE transfers, nothing
  debited — every PmtInf, every transfer's own debit and the N branch's reference-less lines read);
- the file's page with the switch on (`public.transfer_file_detail(F1)`, its card's evidence and a
  page of its transfers);
- generation's holds (`public.generate_transfer_file`: the CANCELLED re-issues, those whose
  predecessor was debited late held `already_debited`, the others in the file);
- the nightly checks (`private.run_payment_checks`, `private.run_transfer_checks` in them: C, L, M
  and N over the cancelled filed transfers, the SIZE in flight beside them), the rows they read
  from `bank_transfer` bounded by the servicer's own.

Prints the timings (docs/benchmarks/remittances.md). TRANSFER_CANCEL_SIZE and
TRANSFER_CANCEL_COUNT change the sizes."""

import os
import time
import uuid
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import psycopg
import pytest
from integration_helpers import DB, as_user, one, storage
from psycopg.conninfo import make_conninfo
from psycopg.types.json import Jsonb
from reconciliation_helpers import pay
from remittance_helpers import (
    add_admin,
    approve,
    drain,
    paid_file,
    paris_today,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from stats_helpers import forget_statistics

from collectoo_worker.synth.reconciliation import Credit

pytestmark = pytest.mark.integration
SIZE = int(os.environ.get("TRANSFER_CANCEL_SIZE", "5000"))
CANCELLED = int(os.environ.get("TRANSFER_CANCEL_COUNT", "40"))
ADMIN = make_conninfo(DB, user="supabase_admin")
PARIS = ZoneInfo("Europe/Paris")


def _credits(n: int) -> list[Credit]:
    return [
        Credit(1000 + k, f"PAYEUR {k}", None, (f"VIREMENT {k}",), None, None, "no_match", "none")
        for k in range(n)
    ]


def _refund(tenant: dict[str, Any], limit: int) -> int:
    """Refunds of `limit` unmatched payments, each in the next transfer file (the ops manager)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["staff"], "aal2")
        asked = one(
            conn,
            """select count(public.request_refund('scale-cxl-' || p.id, p.id, p.amount_minor::text,
                        'FR7630004000031234567890143', p.payer_name, 'other', p.review_reason,
                        p.amount_minor::text, 'test d''échelle'))
               from (select * from public.payment
                     where bank_account_id = %s and status = 'unmatched'
                       and not exists (select 1 from public.refund_request r
                                       where r.payment_id = payment.id)
                     order by id limit %s) p""",
            (tenant["bank"], limit),
        )
        conn.execute("reset role")
        conn.execute(
            "delete from pgmq.q_payments where message ->> 'organization_id' = %s",
            (str(tenant["servicer"]),),
        )
    return int(asked)


def _file(tenant: dict[str, Any], n: int) -> str:
    """The account's ordered transfers (n of them) in a file, written by the job and downloaded."""
    generated = staff(
        tenant,
        "select public.generate_transfer_file(%s, %s, null)",
        str(uuid.uuid4()),
        tenant["bank"],
    )
    assert generated["nb_of_txs"] == n and generated["held"] == [], generated
    drain()  # the transfer_file job
    with psycopg.connect(DB) as conn:
        digest = one(
            conn,
            "select file_sha256 from public.transfer_file where id = %s",
            (generated["file_id"],),
        )
    staff(tenant, "select public.transfer_file_download(%s, %s)", generated["file_id"], digest)
    return str(generated["file_id"])


def _backdate(conn: psycopg.Connection[Any], file_id: str, day: date) -> None:
    """The file dated back to `day` (its items too), as pgTAP 039's pg_temp.backdate."""
    conn.execute("set constraints public.transfer_file_superseded_by_fkey immediate")
    conn.execute("alter table public.transfer_file disable trigger transfer_file_guard")
    conn.execute(
        "update public.transfer_file set first_execution_date = %s, last_execution_date = %s"
        " where id = %s",
        (day, day, file_id),
    )
    conn.execute("alter table public.transfer_file enable always trigger transfer_file_guard")
    conn.execute(
        "alter table public.transfer_file_item disable trigger transfer_file_item_append_only"
    )
    conn.execute(
        "update public.transfer_file_item set execution_date = %s where file_id = %s",
        (day, file_id),
    )
    conn.execute(
        "alter table public.transfer_file_item enable always trigger transfer_file_item_append_only"
    )
    conn.execute("set constraints public.transfer_file_superseded_by_fkey deferred")


def _statement(  # noqa: PLR0913 - a statement's identity, as pgTAP 039's pg_temp.statement
    conn: psycopg.Connection[Any],
    tenant: dict[str, Any],
    *,
    start: date,
    end: date,
    opening: int,
    debits: list[tuple[str, int]],
    created: datetime,
    kind: str = "refund_out",
) -> int:
    """An imported camt.053 statement of the account from `start` to `end`, its sections as the
    parser gives them (its whole days, balances and the bank's creation time), its lines the
    `debits` (end-to-end id, amount) booked on `end`. Returns its closing balance."""
    closing = opening - sum(a for _, a in debits)
    st = one(
        conn,
        """insert into public.bank_statement (organization_id, bank_account_id, currency, format,
             file_name, file_sha256, size_bytes, storage_path)
           values (%s, %s, 'EUR', 'camt053', 's.xml', %s, 1, %s) returning id""",
        (tenant["servicer"], tenant["bank"], uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
    )
    conn.execute(
        "update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = %s",
        (st,),
    )
    conn.execute(
        """insert into public.bank_transaction (organization_id, bank_account_id, statement_id,
             line_no, dedup_key, direction, amount_minor, currency, booking_date, kind,
             end_to_end_id)
           select %s, %s, %s, d.ord, 'c:' || %s || ':' || d.ord, 'debit',
                  (d.v ->> 'amount')::bigint, 'EUR', %s, %s, d.v ->> 'e2e'
           from jsonb_array_elements(%s) with ordinality d (v, ord)""",
        (
            tenant["servicer"],
            tenant["bank"],
            st,
            str(st),
            end,
            kind,
            Jsonb([{"e2e": e, "amount": a} for e, a in debits]),
        ),
    )
    conn.execute(
        """update public.bank_statement set status = 'imported', from_date = %s, to_date = %s,
             opening_booked_minor = %s, closing_booked_minor = %s, counts = '{}',
             finished_at = clock_timestamp(),
             sections = jsonb_build_array(jsonb_build_object(
               'from_date', %s::date, 'to_date', %s::date, 'covers_from', %s::date,
               'covers_to', %s::date, 'opening_minor', %s::text, 'closing_minor', %s::text,
               'created_at', %s::text))
           where id = %s""",
        (start, end, opening, closing, start, end, start, end, opening, closing,
         created.isoformat(timespec="seconds"), st),
    )  # fmt: skip
    return closing


def _as(conn: psycopg.Connection[Any], user: str, sql: str, *params: Any) -> Any:
    """A command as `user` (aal2) inside the open transaction, then back to the admin role."""
    as_user(conn, user, "aal2")
    try:
        row = conn.execute(sql, params).fetchone()
    finally:
        conn.execute("reset role")
    return row[0] if row else None


def _timed(conn: psycopg.Connection[Any], sql: str, *params: Any) -> tuple[Any, float]:
    started = time.monotonic()
    row = conn.execute(sql, params).fetchone()
    return (row[0] if row else None), time.monotonic() - started


_TRANSFER_READS = (
    "select coalesce(sum(idx_tup_fetch + seq_tup_read), 0) from pg_stat_xact_user_tables"
    " where relid = 'public.bank_transfer'::regclass"
)


def test_transfers_cancelled_out_of_a_downloaded_file_and_reissued_beside_a_large_file() -> None:  # noqa: PLR0915 - one scenario
    tenant = remittance_tenant()
    admin = add_admin(tenant)
    d0 = recent_business_day(back=20)
    # (review M2c-6b-3a-2 round 1, CSC-3, tests-6) the client's collection, imported first (the
    # credits' statement of the same day, imported after it, is the cash check's latest)
    paid_file(tenant, 200_000, day=d0)
    sid = pay(
        tenant, storage(), _credits(2 * SIZE + CANCELLED), prefix="X", start=d0, days=1,
        allocate=False,
    )  # fmt: skip
    asking = time.monotonic()
    # the client's run, approved: its payout x goes in the small file with the CANCELLED refunds,
    # and is cancelled and re-issued with them (y)
    rr = request_run(tenant)
    approve(tenant, rr)
    drain()  # the approval job
    assert run_row(rr)["status"] == "approved"
    assert _refund(tenant, CANCELLED) == CANCELLED
    small = _file(tenant, CANCELLED + 1)
    assert _refund(tenant, SIZE) == SIZE
    large = _file(tenant, SIZE)
    # SIZE more refunds ordered, filed with the re-issues by the generation with the switch on
    assert _refund(tenant, SIZE) == SIZE
    setup_s = time.monotonic() - asking
    with psycopg.connect(DB) as conn:
        xp = conn.execute(
            """select t.id, t.end_to_end_id, t.amount_minor from public.bank_transfer t
               where t.run_id = %s and t.kind = 'payout'""",
            (rr,),
        ).fetchone()
    assert xp is not None

    # time moved on: both files dated back to X, a statement of X and Y produced after them (no
    # debit: neither executed); the late debits come on the next one
    with psycopg.connect(DB) as conn:
        x = one(
            conn,
            """select min(c.day) from public.business_calendar c
               where c.scope = 'FR-conservative' and not c.closed and c.day > %s""",
            (d0 + timedelta(days=2),),
        )
        y = one(conn, "select private.next_business_day(%s)", (x,))
        opening = one(
            conn, "select closing_booked_minor from public.bank_statement where id = %s", (sid,)
        )
        late = conn.execute(
            """select t.end_to_end_id, t.amount_minor from public.transfer_file_item i
               join public.bank_transfer t on t.id = i.transfer_id
               where i.file_id = %s and t.kind = 'refund' order by i.seq limit %s""",
            (small, CANCELLED // 2),
        ).fetchall()
    assert y < paris_today()
    today = paris_today()
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        _backdate(conn, small, x)
        _backdate(conn, large, x)
        closing = _statement(
            conn,
            tenant,
            start=d0 + timedelta(days=1),
            end=y,
            # (the client's collection of 200,000 came on its own statement of the same day)
            opening=int(opening) + 200_000,
            debits=[],
            created=datetime.combine(y + timedelta(days=1), datetime.min.time(), PARIS)
            + timedelta(hours=9),
        )
    for table in (
        "public.bank_transfer",
        "public.transfer_file_item",
        "public.transfer_cancellation_request",
    ):
        forget_statistics(table)

    # the switch on in this transaction only, rolled back at its end with everything it did: never
    # committed (the cancellation, the late debits, the new file and the checks' rows with it)
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        conn.execute(
            "update private.feature_switch set enabled = true"
            " where key = 'downloaded_file_cancellation'"
        )
        version = one(conn, "select version from public.transfer_file where id = %s", (small,))
        asked = _as(
            conn, tenant["staff"],
            """select public.request_transfer_file_cancellation(%s, %s, %s,
                 'Fichier non déposé (test d''échelle)', 'not_uploaded') ->> 'status'""",
            str(uuid.uuid4()), small, version,
        )  # fmt: skip
        assert asked is not None
        confirming = time.monotonic()
        confirmed = _as(
            conn, admin, "select public.confirm_transfer_file_cancellation(%s, %s, %s)",
            str(uuid.uuid4()), small, version,
        )  # fmt: skip
        confirm_s = time.monotonic() - confirming
        assert confirmed["status"] == "superseded", confirmed  # its transfers re-issued
        reissued = one(
            conn,
            """select count(*) from public.bank_transfer y
               join public.bank_transfer x on x.id = y.replaces_transfer_id
               join public.transfer_file_item i on i.transfer_id = x.id and i.file_id = %s
               where x.status = 'cancelled' and y.status = 'ordered'""",
            (small,),
        )
        assert reissued == CANCELLED + 1  # the refunds and the payout x (re-issued as y)
        # the bank executed half of them all the same, late (their own end-to-end ids)
        _statement(
            conn,
            tenant,
            start=y + timedelta(days=1),
            end=today,
            opening=closing,
            debits=[(str(e), int(a)) for e, a in late],
            created=datetime.now(PARIS),
        )

        evidence, evidence_s = _timed(
            conn, "select private.transfer_cancel_evidence(%s, null)", large
        )
        assert evidence["refusal"] is None and evidence["covered"] is True, evidence
        one_tr = one(
            conn,
            "select transfer_id from public.transfer_file_item where file_id = %s limit 1",
            (large,),
        )
        _, evidence_one_s = _timed(
            conn, "select private.transfer_cancel_evidence(%s, %s)", large, one_tr
        )
        showing = time.monotonic()
        detail = _as(
            conn, tenant["staff"], "select public.transfer_file_detail(%s, null, null)", large
        )
        detail_s = time.monotonic() - showing
        assert detail["cancellation_after_download"] is True
        assert detail["cancellation"]["evidence"]["refusal"] is None, detail["cancellation"]

        generating = time.monotonic()
        generated = _as(
            conn, tenant["staff"], "select public.generate_transfer_file(%s, %s, null)",
            str(uuid.uuid4()), tenant["bank"],
        )  # fmt: skip
        generate_s = time.monotonic() - generating
        held = {h["reason"] for h in generated["held"]}
        assert len(generated["held"]) == len(late), generated["held"][:3]
        assert held == {"already_debited"}, held  # its predecessor debited late
        # the re-issues not held (y among them) and the SIZE refunds ordered since
        assert generated["nb_of_txs"] == CANCELLED - len(late) + 1 + SIZE
        new_file = generated["file_id"]
        # the job's write, emulated in this transaction (as pgTAP's pg_temp.write): the file is
        # generated, not downloaded — the late predecessor's booking withdraws it
        conn.execute(
            """select private.transfer_file_record(f.id, f.job_token,
                 md5(f.id::text) || md5(f.id::text), 1234,
                 f.organization_id || '/' || f.id || '/' || f.number || '.xml', false,
                 'pain001-1', f.nb_of_txs, f.ctrl_sum_minor)
               from public.transfer_file f where f.id = %s""",
            (new_file,),
        )

        # (review M2c-6b-3a-2 round 1, CSC-3, tests-6) x executed late all the same, its own
        # end-to-end id on today's statement: the nightly checks read the chained run (its re-issue
        # y in the generated file)
        lp_closing = _statement(
            conn,
            tenant,
            start=today,
            end=today,
            opening=closing,
            debits=[(str(xp[1]), int(xp[2]))],
            created=datetime.now(PARIS),
            kind="transfer_out",
        )
        assert lp_closing is not None
        lx = one(
            conn,
            """select id from public.bank_transaction
               where bank_account_id = %s and end_to_end_id = %s""",
            (tenant["bank"], xp[1]),
        )

        before = one(conn, _TRANSFER_READS)
        run, nightly_s = _timed(conn, "select private.run_payment_checks(%s)", tenant["servicer"])
        nightly_reads = int(one(conn, _TRANSFER_READS)) - int(before)
        breaches: dict[str, int] = dict(
            conn.execute(
                """select code, count(*) from public.payment_check_result
                   where run_id = %s group by code""",
                (run["run_id"],),
            ).fetchall()
        )

        # « Comptabiliser… » on x's line: the late predecessor, its re-issue y in the generated file
        # of CANCELLED - late + 1 + SIZE transfers — the booking withdraws that file (its transfers
        # back in the queue), cancels y and books the run
        opening_sheet = time.monotonic()
        options = _as(conn, tenant["staff"], "select public.transfer_line_options(%s)", lx)
        options_s = time.monotonic() - opening_sheet
        assert options["proposals"], {k: options[k] for k in ("class", "refusal", "refusal_detail")}
        proposal = options["proposals"][0]
        (lp_part,) = [p for p in proposal["preview"]["parts"] if p["kind"] == "payout"]
        assert lp_part["late_predecessor"] is True and lp_part["supersedes_file_number"], lp_part
        booking = time.monotonic()
        _as(
            conn, tenant["staff"], "select public.book_transfer_line(%s, %s, %s, %s, %s)",
            str(uuid.uuid4()), lx, Jsonb(proposal["request"]), proposal["preview"]["expected_text"],
            "exécuté en retard (test d'échelle)",
        )  # fmt: skip
        book_s = time.monotonic() - booking
        after = conn.execute(
            """select (select status from public.transfer_file where id = %s),
                      (select status from public.remittance_run where id = %s),
                      (select status from public.bank_transfer where replaces_transfer_id = %s),
                      (select count(*) from public.bank_transfer
                       where debtor_bank_account_id = %s and status = 'ordered'
                         and kind = 'refund')""",
            (new_file, rr, xp[0], tenant["bank"]),
        ).fetchone()
        assert after is not None
    with psycopg.connect(DB) as conn:
        assert one(conn, "select enabled from private.feature_switch"
                         " where key = 'downloaded_file_cancellation'") is False  # fmt: skip
    print(
        f"\n{SIZE} transfers in a downloaded file, {CANCELLED} cancelled out of another and"
        f" re-issued ({len(late)} of them debited late): set-up {setup_s:.1f}s; confirmation of the"
        f" cancellation {confirm_s:.2f}s; evidence of the large file {evidence_s:.2f}s (one of its"
        f" transfers {evidence_one_s:.3f}s); its page with the switch on {detail_s:.2f}s;"
        f" generation with the holds {generate_s:.2f}s ({len(generated['held'])} held,"
        f" {generated['nb_of_txs']} in the file); nightly checks {nightly_s:.2f}s"
        f" ({nightly_reads} bank_transfer rows read; breaches {breaches}); the late predecessor's"
        f" options {options_s:.2f}s, its booking {book_s:.2f}s (the generated file withdrawn,"
        f" {after[3]} refunds ordered again)"
    )
    # the late predecessor booked as its run's payout: the generated file withdrawn, y cancelled,
    # the run booked, the file's refunds back in the queue (review M2c-6b-3a-2 round 1, CSC-3)
    assert after[0] == "superseded" and after[1] == "booked" and after[2] == "cancelled", after
    # (the held re-issues were never filed: still ordered beside them)
    assert after[3] == CANCELLED + SIZE, after
    # the late debits alerted, each once (C: a cancelled transfer debited after all)
    assert breaches.get("cancelled_transfer_debited", 0) >= len(late), breaches
    # the commands within the API's 8 s; the nightly checks within plan §1.4's 5 s
    assert confirm_s < 8
    assert evidence_s < 8
    assert detail_s < 8
    assert generate_s < 8
    assert nightly_s < 5
    # CSC-3: the late predecessor's sheet and booking, its re-issue in a file of SIZE transfers,
    # within 4 s each (the booking holds the payments and remit locks for its whole length)
    assert options_s < 4
    assert book_s < 4
    # each transfer read by key a bounded number of times (never every servicer's, never n²): 12
    # reads for each transfer of the downloaded files, as before; (review M2c-6b-3a-2 round 1) 24
    # for each of the SIZE refunds ordered since and filed in the generated file with y (in
    # flight, not downloaded: C, L and M's probes read each), the payout x and its re-issue y —
    # 86,438 and 146,726 rows measured in two runs (8.6 and 14.6 per transfer)
    assert nightly_reads <= 12 * (SIZE + 2 * CANCELLED) + 24 * (SIZE + 2) + 2_000, nightly_reads
