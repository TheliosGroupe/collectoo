"""M2c-6b-2a foundations through the database, the worker, storage and the real parsers (needs
`make up`; plan docs/design/m2c-6b-2-plan.md §2, §8.2 « Integration (6b-2a) »):

* the statement's own detail of an entry kept unsplit, through the real camt.053 import (the
  parser, the stage's COPY as Jsonb, private.ingest_statement): the details of ours, their count,
  NbOfTxs and the charges kept on the line; the same entries again skipped; a CSV keeps none;
* the real `process_debits` job reviews a flagged return of a transfer that has an open unplanned
  booking (seeded as 6b-2b posts it for S03) `unplanned_payout_return`, and a return of a transfer
  whose second debit is on a statement and not booked `return_debit_pending` — both when the job's
  facts are fresh and when they are stale (the booking or the debit lands between the candidates
  read and private.apply_bank_bookings: the SQL re-check reviews it);
* private.unique_subset_trace = the Python twin (the answer, the bound and the item it trips at);
* a generated file's sweep re-checked at its first download under the remit lock: a bank charge
  booked by the funds pass while the download waits makes it refuse `sweep_exceeds_share`; the
  download and the file's regeneration or its run's cancellation, either holding its locks first:
  the other waits for its commit (a serial shape — it shows the wait and each outcome, not the
  lock order: review M2c-6b-2a CS-1, ADR-0014);
* review M2c-6b-2a (M1): a debit held as a suspected duplicate keeps a return waiting until ops
  decide it is a duplicate; the decision queues the job, which books the return.
"""

from __future__ import annotations

import hashlib
import json
import random
import threading
import time
import uuid
from datetime import date
from pathlib import Path
from typing import Any

import psycopg
import pytest
from debit_helpers import api
from integration_helpers import DB, as_user, storage
from remittance_helpers import drain as drain_remittances
from remittance_helpers import paris_today, run_row
from statement_helpers import bank_tenant, upload
from statement_helpers import drain as drain_payments
from test_debit_bookings_integration import (
    _bank,
    _bookings,
    _downloaded,
    _import_only,
    _last_closing,
    _payouts,
    _reviews,
    _session,
    _transfer,
    _waits,
)
from test_transfer_files_integration import _bytes, _file_row, _generate, _two_runs

from collectoo_worker.jobs.debits import (
    apply_bookings,
    debit_dates,
    funds_lines,
    run_process_debits,
)
from collectoo_worker.payments.debits import decide_bookings, unique_subset_trace
from collectoo_worker.remittance import pain001
from collectoo_worker.synth.camt053 import (
    FEE_CODE,
    TRANSFER_DEBIT_CODE,
    Entry,
    Tx,
    debits_of,
    make_doc,
    render_camt053,
)

pytestmark = pytest.mark.integration


def _lines(statement_id: str) -> list[dict[str, Any]]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            """select kind, direction, amount_minor, unsplit_ours, unsplit_details,
                      unsplit_detail_count, unsplit_batch_count, charges_minor
               from public.bank_transaction where statement_id = %s order by line_no""",
            (statement_id,),
        )
        assert cur.description is not None
        names = [d.name for d in cur.description]
        return [dict(zip(names, r, strict=True)) for r in cur.fetchall()]


def _statement(tenant: dict[str, Any], entries: list[Entry], *, version: str = "08") -> str:
    """A camt.053 of these entries (opened with the last closing), imported; the queue drained."""
    opening, _last = _last_closing(tenant)
    days = [e.booking_date for e in entries]
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        entries,
        iban=tenant["iban"],
        from_date=min(days),
        to_date=max(days),
        opening_minor=opening,
        stmt_id=stmt,
    )
    target = upload(tenant, storage(), render_camt053(doc, version), name=f"{stmt}.xml")
    drain_payments(storage())
    return str(target["statement_id"])


def _day(tenant: dict[str, Any]) -> date:
    return max(paris_today(), _last_closing(tenant)[1])


# -- the statement's own details, stored at import ----------------------------------------------


def test_the_statement_s_own_details_are_stored_at_import(tmp_path: Path) -> None:
    tenant, _other, _r1, _r2 = _two_runs()
    _f, data = _downloaded(tenant, tmp_path)
    (a, na), (b, nb) = _payouts(data)
    day = _day(tenant)
    ref = f"U{uuid.uuid4().hex[:6].upper()}"
    netted = debits_of(
        pain001.read(data),
        booking_date=day,
        mode="batch",
        unsplit_details="ours-netted",
        ref_prefix=ref,
    )
    sid = _statement(tenant, netted)
    (line,) = _lines(sid)
    assert (
        line["kind"],
        line["amount_minor"],
        line["unsplit_ours"],
        line["unsplit_detail_count"],
        line["unsplit_batch_count"],
        line["charges_minor"],
    ) == ("batch_unsplit", na + nb - na, 3, 3, 3, None)
    assert line["unsplit_details"] == [
        {"id": a, "direction": "debit", "amount_minor": str(na)},
        {"id": b, "direction": "debit", "amount_minor": str(nb)},
        {"id": a, "direction": "credit", "amount_minor": str(na)},
    ]
    assert _bookings(sid) == [] and _reviews(sid) == ["batch_partial"]  # never booked by the job
    # the same entries again, on another statement: known, skipped, untouched
    sid2 = _statement(tenant, netted)
    assert _lines(sid2) == []
    assert _lines(sid) == [line]
    # ML-6: the ISO shape of a charged debit (detail at N, entry N + charge, Chrgs/Rcrd) keeps its
    # charge (review M2c-6b-2a M3: a v02 file's Chrgs is never read, so v08 here)
    charged = debits_of(
        pain001.read(data),
        booking_date=day,
        debit_charge_minor=120,
        ref_prefix=f"C{uuid.uuid4().hex[:6].upper()}",
    )
    sid3 = _statement(tenant, charged, version="08")
    got = _lines(sid3)
    assert [
        (x["kind"], x["amount_minor"], x["unsplit_ours"], x["unsplit_details"], x["charges_minor"])
        for x in got
    ] == [
        (
            "batch_unsplit",
            na + 120,
            1,
            [{"id": a, "direction": "debit", "amount_minor": str(na)}],
            120,
        ),
        (
            "batch_unsplit",
            nb + 120,
            1,
            [{"id": b, "direction": "debit", "amount_minor": str(nb)}],
            120,
        ),
    ]


def test_a_csv_line_keeps_no_details() -> None:
    """A CSV export has no entry details nor charges: its lines stage them as null (the COPY of the
    new columns) and keep none."""
    tenant = bank_tenant(feed="csv")
    tag = uuid.uuid4().hex[:6].upper()
    rmt = "RMT" + uuid.uuid4().hex[:12].upper()
    csv = (
        "Date;Libellé;Débit;Crédit;Référence de bout en bout\n"
        f"10/11/2026;VIR SEPA EMIS /DE MARTIN SAS {tag};1640,00;;{rmt}\n"
        f"10/11/2026;FRAIS BANCAIRES {tag};1,20;;\n"
    ).encode()
    target = upload(tenant, storage(), csv, name=f"releve-{tag}.csv")
    drain_payments(storage())
    got = _lines(str(target["statement_id"]))
    assert len(got) == 2
    assert {
        (
            x["unsplit_ours"],
            x["unsplit_details"],
            x["unsplit_detail_count"],
            x["unsplit_batch_count"],
            x["charges_minor"],
        )
        for x in got
    } == {(None, None, None, None, None)}


# -- the job's return rule ----------------------------------------------------------------------


def _seed_unplanned(conn: psycopg.Connection[Any], line: str, transfer: str, client: str) -> str:
    """What 6b-2b posts for an unplanned payout of `transfer` on `line` (S03, P = 0), as pgTAP 036
    B's helper: the remittance, its booking, the -A pending row, the double_payout advance."""
    row = conn.execute(
        """select organization_id, bank_account_id, amount_minor, currency, booking_date
           from public.bank_transaction where id = %s""",
        (line,),
    ).fetchone()
    assert row is not None
    org, bank, amount, currency, day = row
    adv = str(uuid.uuid4())
    conn.execute("select private.ledger_post_set_begin()")
    conn.execute(
        """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date,
             idempotency_key, client_organization_id, source_type, source_id, reason)
           values (1, %s, 'remittance', %s, %s, %s, 'bank_transfer', %s,
                   'Virement exécuté hors reversement (test)'),
                  (2, %s, 'client_advance', %s, %s, %s, 'client_advance', %s,
                   'Virement hors reversement : avance du cabinet')""",
        (
            org,
            day,
            f"remit:line:{line}:1",
            client,
            transfer,
            org,
            day,
            f"adv:line:{line}:1",
            client,
            adv,
        ),
    )
    conn.execute(
        """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency,
             bank_account_id)
           values (1, 1, 'client_payable', %(a)s, %(c)s, null),
                  (1, 2, 'client_money_cash', -%(a)s, %(c)s, %(b)s),
                  (2, 1, 'due_to_servicer', %(a)s, %(c)s, null),
                  (2, 2, 'client_payable', -%(a)s, %(c)s, null),
                  (2, 3, 'client_advance_receivable', %(a)s, %(c)s, null),
                  (2, 4, 'due_from_client_funds', -%(a)s, %(c)s, null)""",
        {"a": amount, "c": currency, "b": bank},
    )
    conn.execute("select private.ledger_post_set()")
    entries = dict(
        conn.execute(
            """select idempotency_key, id from public.ledger_entry
           where organization_id = %s and idempotency_key = any(%s)""",
            (org, [f"remit:line:{line}:1", f"adv:line:{line}:1"]),
        ).fetchall()
    )
    remit, advance = entries[f"remit:line:{line}:1"], entries[f"adv:line:{line}:1"]
    conn.execute(
        """insert into private.remittance_pending (ledger_entry_id, organization_id,
             client_organization_id, currency, kind, amount_minor, posted_at)
           select id, organization_id, %s, %s, 'unplanned_payout', -%s, posted_at
           from public.ledger_entry where id = %s""",
        (client, currency, amount, remit),
    )
    conn.execute(
        """insert into public.bank_line_booking (bank_transaction_id, seq, organization_id,
             bank_account_id, kind, transfer_id, entry_id, amount_minor, method, reason, decided_by)
           select %s, 1, %s, %s, 'unplanned_payout', %s, %s, %s, 'ops', 'motif de test',
                  (select user_id from public.membership where organization_id = %s limit 1)""",
        (line, org, bank, transfer, remit, amount, org),
    )
    conn.execute(
        """insert into public.client_advance (id, organization_id, client_organization_id,
             currency, amount_minor, cause, cause_entry_id, entry_id, bank_transaction_id,
             transfer_id)
           values (%s, %s, %s, %s, %s, 'double_payout', %s, %s, %s, %s)""",
        (adv, org, client, currency, amount, remit, advance, line, transfer),
    )
    conn.execute("select private.ledger_check_now()")
    return str(remit)


def _second_debit(tenant: dict[str, Any], e2e: str, amount: int) -> tuple[str, str]:
    """A second debit of our transfer, on a statement imported and run by the job (reviewed
    transfer_debited_twice): (statement, line)."""
    day = _day(tenant)
    ref = f"D{uuid.uuid4().hex[:6].upper()}"
    entry = Entry(
        amount,
        False,
        day,
        day,
        ref=f"{ref}1",
        code=TRANSFER_DEBIT_CODE,
        txs=(Tx(amount, end_to_end_id=e2e),),
    )
    sid = _statement(tenant, [entry])
    assert _reviews(sid) == ["transfer_debited_twice"]
    return sid, _line_of(sid)


def _line_of(statement_id: str) -> str:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select id::text from public.bank_transaction where statement_id = %s", (statement_id,)
        ).fetchone()
    assert row is not None
    return str(row[0])


def _return_entries(data: bytes, e2e: str, day: date) -> list[Entry]:
    return [
        e
        for e in debits_of(
            pain001.read(data),
            returns=[e2e],
            return_date=day,
            ref_prefix=f"R{uuid.uuid4().hex[:6].upper()}",
        )
        if e.credit
    ]


def _booked(tenant: dict[str, Any], tmp_path: Path) -> tuple[bytes, list[tuple[str, int]]]:
    _f, data = _downloaded(tenant, tmp_path)
    _bank(tenant, data)
    paid = _payouts(data)
    assert all(_transfer(e)["status"] == "booked" for e, _ in paid)
    return data, paid


def test_the_job_reviews_a_return_of_a_transfer_with_an_open_unplanned_booking(
    tmp_path: Path,
) -> None:
    tenant, _other, _r1, _r2 = _two_runs()
    data, paid = _booked(tenant, tmp_path)
    (e2e, n), _ = paid
    x = _transfer(e2e)
    _sid, d2 = _second_debit(tenant, e2e, n)
    with psycopg.connect(DB) as conn:
        _seed_unplanned(conn, d2, str(x["id"]), str(x["client_organization_id"]))
    sid = _returned(tenant, data, e2e)
    # the job's own decision (its fact read by the candidates), before the SQL re-check
    out = _funds_pass_stale(str(tenant["servicer"]), lambda _conn: None)
    assert _decided(out, sid) == [(None, "unplanned_payout_return")]
    assert _bookings(sid) == []
    assert _reviews(sid) == ["unplanned_payout_return"]
    assert _transfer(e2e)["status"] == "booked"


def _returned(tenant: dict[str, Any], data: bytes, e2e: str) -> str:
    """The return of our transfer on a statement imported, the job not run: the statement."""
    opening, _last = _last_closing(tenant)
    day = _day(tenant)
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        _return_entries(data, e2e, day),
        iban=tenant["iban"],
        from_date=day,
        to_date=day,
        opening_minor=opening,
        stmt_id=stmt,
    )
    _import_only(render_camt053(doc, "08"), tenant, f"{stmt}.xml")
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select statement_id::text from public.bank_transaction where kind = 'return' "
            "and original_end_to_end_id = %s order by created_at desc limit 1",
            (e2e,),
        ).fetchone()
    assert row is not None
    return str(row[0])


def _decided(out: dict[str, Any], statement_id: str) -> list[tuple[str | None, str | None]]:
    """The job's decisions (kind, review reason) for the lines of this statement."""
    with psycopg.connect(DB) as conn:
        ids = {
            str(r[0])
            for r in conn.execute(
                "select id from public.bank_transaction where statement_id = %s", (statement_id,)
            )
        }
    return [(b.kind, b.review_reason) for b in out["bookings"] if b.line_id in ids]


def _insert_debit(
    conn: psycopg.Connection[Any], tenant: dict[str, Any], e2e: str, amount: int, day: date
) -> str:
    """A second debit of our transfer landing on the account (its line inserted as an import would,
    in the caller's transaction): its id."""
    s = str(uuid.uuid4())
    conn.execute(
        """insert into public.bank_statement (id, organization_id, bank_account_id, currency,
             format, file_name, file_sha256, size_bytes, storage_path)
           values (%s, %s, %s, 'EUR', 'camt053', 'd2.xml', %s, 1, 'test/' || %s)""",
        (s, tenant["servicer"], tenant["bank"], hashlib.sha256(s.encode()).hexdigest(), s),
    )
    conn.execute(
        "update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = %s",
        (s,),
    )
    row = conn.execute(
        """insert into public.bank_transaction (organization_id, bank_account_id, statement_id,
             line_no, dedup_key, direction, amount_minor, currency, booking_date, kind,
             end_to_end_id)
           values (%s, %s, %s, 1, 't:' || %s, 'debit', %s, 'EUR', %s, 'transfer_out', %s)
           returning id::text""",
        (tenant["servicer"], tenant["bank"], s, s, amount, day, e2e),
    ).fetchone()
    assert row is not None
    return str(row[0])


def _funds_pass_stale(org: str, between: Any) -> dict[str, Any]:
    """The funds pass, with `between(conn)` run after its candidates are read and decided, before
    private.apply_bank_bookings (one transaction, as the job's)."""
    from psycopg.rows import dict_row  # noqa: PLC0415

    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("select pg_advisory_xact_lock(hashtext('debits:' || %s))", (org,))
        with conn.cursor(row_factory=dict_row) as cur:
            rows = cur.execute(
                "select * from private.bank_booking_candidates(%s, null, null, 2000)", (org,)
            ).fetchall()
        debit_dates(conn, rows)
        bookings = decide_bookings(funds_lines(rows))
        between(conn)
        return {"bookings": bookings, "summary": apply_bookings(conn, org, bookings)}


def test_a_stale_fact_is_reviewed_by_the_sql_re_check(tmp_path: Path) -> None:
    """The unplanned booking lands after the job decided the return was the payout's: the re-check
    under the locks reviews it unplanned_payout_return, nothing booked."""
    tenant, _other, _r1, _r2 = _two_runs()
    data, paid = _booked(tenant, tmp_path)
    (e2e, n), _ = paid
    x = _transfer(e2e)
    opening, _last = _last_closing(tenant)
    day = _day(tenant)
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        _return_entries(data, e2e, day),
        iban=tenant["iban"],
        from_date=day,
        to_date=day,
        opening_minor=opening,
        stmt_id=stmt,
    )
    _import_only(render_camt053(doc, "08"), tenant, f"{stmt}.xml")

    def second_debit_booked_by_ops(conn: psycopg.Connection[Any]) -> None:
        d2 = _insert_debit(conn, tenant, e2e, n, day)
        _seed_unplanned(conn, d2, str(x["id"]), str(x["client_organization_id"]))

    out = _funds_pass_stale(str(tenant["servicer"]), second_debit_booked_by_ops)
    assert [b.kind for b in out["bookings"] if b.booked] == ["payout_returned"]  # stale
    with psycopg.connect(DB) as conn:
        sid = conn.execute(
            "select id::text from public.bank_statement where file_name = %s", (f"{stmt}.xml",)
        ).fetchone()
    assert sid is not None
    assert _bookings(sid[0]) == [] and _reviews(sid[0]) == ["unplanned_payout_return"]
    assert _transfer(e2e)["status"] == "booked"


def test_the_job_reviews_a_return_while_a_second_debit_is_pending(tmp_path: Path) -> None:
    """ML-3: the second debit on a statement, not booked; then a return: return_debit_pending,
    nothing booked, nothing queued again, the payout account active."""
    tenant, _other, _r1, _r2 = _two_runs()
    data, paid = _booked(tenant, tmp_path)
    (e2e, n), _ = paid
    _second_debit(tenant, e2e, n)
    sid = _returned(tenant, data, e2e)
    out = _funds_pass_stale(str(tenant["servicer"]), lambda _conn: None)
    assert _decided(out, sid) == [(None, "return_debit_pending")]  # the job's own decision
    assert _bookings(sid) == [] and _reviews(sid) == ["return_debit_pending"]
    x = _transfer(e2e)
    assert x["status"] == "booked"
    with psycopg.connect(DB) as conn:
        queued = conn.execute(
            """select count(*) from private.remittance_pending
               where client_organization_id = %s and kind = 'payout_returned'""",
            (x["client_organization_id"],),
        ).fetchone()
        account = conn.execute(
            """select a.status from public.remittance_run r
               join public.client_payout_account a on a.id = r.payout_account_id where r.id = %s""",
            (x["run_id"],),
        ).fetchone()
    assert queued == (0,) and account == ("active",)


def _csv_export(tenant: dict[str, Any], rows: list[tuple[date, str, int, str]]) -> str:
    """A CSV export of the account (`(day, label, signed minor, end-to-end id)`), imported; the
    queue drained: its statement."""
    lines = ["Date;Libellé;Débit;Crédit;Référence de bout en bout"]
    for day, label, signed, e2e in rows:
        euros = f"{abs(signed) // 100},{abs(signed) % 100:02d}"
        debit, credit = (euros, "") if signed < 0 else ("", euros)
        lines.append(f"{day:%d/%m/%Y};{label};{debit};{credit};{e2e}")
    target = upload(
        tenant,
        storage(),
        ("\n".join(lines) + "\n").encode(),
        name=f"releve-{uuid.uuid4().hex[:8]}.csv",
    )
    drain_payments(storage())
    return str(target["statement_id"])


def test_a_return_waits_while_its_debit_is_held_as_a_duplicate_then_is_booked(
    tmp_path: Path,
) -> None:
    """Review M2c-6b-2a (M1): an export overlapping the booked debit of our payout holds that
    debit again as a suspected duplicate (the CSV safety net: same day, amount and direction, a
    similar label, another fingerprint). While it is held it may be a second debit: the return of
    the payout waits (return_debit_pending). Once ops decide it is a duplicate it is no movement:
    the decision queues the debit job, which books the return (payout_returned) as before 6b-2a.
    The account's statements are CSV exports from the overlap on (its feed set as postgres: no
    command changes a feed), so the overlap meets the camt.053 lines the payouts were booked
    from."""
    tenant, _other, _r1, _r2 = _two_runs()
    _data, paid = _booked(tenant, tmp_path)
    (e2e, n), _ = paid
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select booking_date, coalesce(counterparty_name, '') || ' ' ||
                      coalesce(remittance_text, '')
               from public.bank_transaction where end_to_end_id = %s and direction = 'debit'""",
            (e2e,),
        ).fetchone()
        assert row is not None
        day, label = row
        conn.execute("update public.bank_account set feed = 'csv' where id = %s", (tenant["bank"],))
    overlap = _csv_export(tenant, [(day, f"VIR SEPA EMIS {label}".strip(), -n, e2e)])
    with psycopg.connect(DB) as conn:
        held = conn.execute(
            "select id::text, kind from public.bank_transaction where statement_id = %s",
            (overlap,),
        ).fetchall()
    assert [k for _id, k in held] == ["suspected_duplicate"]
    back = _csv_export(tenant, [(day, f"RETOUR VIR SEPA {label}".strip(), n, e2e)])
    assert _bookings(back) == [] and _reviews(back) == ["return_debit_pending"]
    out = api(
        tenant,
        "select public.resolve_duplicate(%s, %s, true, 'même débit que le relevé camt')",
        str(uuid.uuid4()),
        held[0][0],
    )
    assert out["decision"] == "duplicate"
    # the decision queued the job: the return is the payout's, booked
    drain_payments(storage())
    assert _bookings(back) == [("payout_returned", e2e, n)]
    assert _transfer(e2e)["status"] == "returned"


def test_a_pending_debit_landing_after_the_decision_is_seen_by_the_re_check(tmp_path: Path) -> None:
    tenant, _other, _r1, _r2 = _two_runs()
    data, paid = _booked(tenant, tmp_path)
    (e2e, n), _ = paid
    opening, _last = _last_closing(tenant)
    day = _day(tenant)
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    doc = make_doc(
        _return_entries(data, e2e, day),
        iban=tenant["iban"],
        from_date=day,
        to_date=day,
        opening_minor=opening,
        stmt_id=stmt,
    )
    _import_only(render_camt053(doc, "08"), tenant, f"{stmt}.xml")

    def second_debit(conn: psycopg.Connection[Any]) -> None:
        _insert_debit(conn, tenant, e2e, n, day)

    out = _funds_pass_stale(str(tenant["servicer"]), second_debit)
    assert [b.kind for b in out["bookings"] if b.booked] == ["payout_returned"]  # stale
    with psycopg.connect(DB) as conn:
        sid = conn.execute(
            "select id::text from public.bank_statement where file_name = %s", (f"{stmt}.xml",)
        ).fetchone()
    assert sid is not None
    assert _bookings(sid[0]) == [] and _reviews(sid[0]) == ["return_debit_pending"]


# -- unique_subset: the SQL twin ----------------------------------------------------------------


def _sql_trace(
    conn: psycopg.Connection[Any],
    amounts: list[int],
    target: int,
    bounds: tuple[int, int, int] = (10_000, 200_000, 1_000_000),
) -> tuple[Any, ...]:
    row = conn.execute(
        "select indexes, tripped_at, bound from private.unique_subset_trace(%s, %s, %s, %s, %s)",
        (amounts, target, *bounds),
    ).fetchone()
    assert row is not None
    return (None if row[0] is None else tuple(row[0]), row[1], row[2])


def test_unique_subset_sql_is_the_python_twin() -> None:
    """200 examples of every shape (small lots, near the partial-sum bound, saturating, equal
    amounts, lowered bounds): the same answer, the same bound, tripped at the same item."""
    rng = random.Random(62)
    cases: list[tuple[list[int], int, tuple[int, int, int]]] = []
    for k in range(200):
        n = rng.choice([0, 1, 3, 8, 12, 15, 20, 40, 120])
        lo, hi = rng.choice([(1, 40), (500, 9000), (100_000, 900_000), (100, 100)])
        amounts = [rng.randint(lo, hi) for _ in range(n)]
        target = rng.randint(-1, sum(amounts) + 1) if k % 3 else sum(rng.sample(amounts, n // 2))
        bounds = rng.choice([(10_000, 200_000, 1_000_000), (500, 2_000, 20_000), (50, 100, 300)])
        cases.append((amounts, target, bounds))
    cases.append(
        ([500 + (g * 7919) % 8501 for g in range(1, 501)], 8000, (10_000, 200_000, 1_000_000))
    )
    cases.append(([2**g for g in range(14)] + [1_000_000], 12_345, (10_000, 200_000, 1_000_000)))
    with psycopg.connect(DB) as conn:
        for amounts, target, (sums, paths, work) in cases:
            py = unique_subset_trace(
                amounts, target, sums_bound=sums, paths_bound=paths, work_bound=work
            )
            assert _sql_trace(conn, amounts, target, (sums, paths, work)) == (
                py.indexes,
                py.tripped_at,
                py.bound,
            ), (amounts, target)


# -- the sweep at the first download ------------------------------------------------------------


def _started(pids: dict[str, int], name: str, timeout_s: float = 15.0) -> None:
    end = time.monotonic() + timeout_s
    while name not in pids and time.monotonic() < end:
        time.sleep(0.01)
    assert name in pids


def _with_sweep(tmp_path: Path) -> tuple[dict[str, Any], dict[str, Any], bytes]:
    """Two runs filed and booked (their commission settled at the debits: the servicer's share),
    then the next file generated and written, sweeping exactly that share: (tenant, file, bytes)."""
    tenant, _other, _r1, _r2 = _two_runs()
    _booked(tenant, tmp_path)
    res = _generate(tenant)
    drain_remittances()
    f = _file_row(res["file_id"])
    assert f["status"] == "generated"
    data = _bytes(f["storage_path"], tmp_path)
    (swept,) = _payouts(data)
    assert swept[0].startswith("SWP")
    return tenant, f, data


def _download(
    conn: psycopg.Connection[Any], tenant: dict[str, Any], f: dict[str, Any], data: bytes
) -> Any:
    as_user(conn, tenant["admin"], "aal2")
    row = conn.execute(
        "select public.transfer_file_download(%s, %s)", (f["id"], hashlib.sha256(data).hexdigest())
    ).fetchone()
    return row[0] if row else None


def test_a_charge_booked_while_the_download_waits_is_seen_by_its_re_check(tmp_path: Path) -> None:
    """The funds pass books a bank charge (+4679) holding the remit lock; the first download waits
    for it (the share is read under that lock), then refuses: the sweep exceeds the share now."""
    tenant, f, data = _with_sweep(tmp_path)
    day = _day(tenant)
    opening, _last = _last_closing(tenant)
    stmt = f"S-{uuid.uuid4().hex[:10]}"
    fee = Entry(700, False, day, day, ref=f"F{uuid.uuid4().hex[:8]}", code=FEE_CODE, info="FRAIS")
    # a credit on the same statement keeps the cash covering the file: the sweep is the one held
    cash = Entry(100_000, True, day, day, ref=f"C{uuid.uuid4().hex[:8]}", info="VIREMENT DIVERS")
    doc = make_doc(
        [fee, cash],
        iban=tenant["iban"],
        from_date=day,
        to_date=day,
        opening_minor=opening,
        stmt_id=stmt,
    )
    _import_only(render_camt053(doc, "08"), tenant, f"{stmt}.xml")
    org = str(tenant["servicer"])
    result: dict[str, Any] = {}
    errors: list[BaseException] = []
    pid: dict[str, int] = {}

    def download() -> None:
        try:
            with _session() as conn, conn.transaction():
                pid["download"] = conn.info.backend_pid
                result["v"] = _download(conn, tenant, f, data)
        except BaseException as exc:  # asserted below
            errors.append(exc)

    with _session() as job, job.transaction():
        run_process_debits(
            job, {"type": "process_debits", "organization_id": org, "funds_after": None}
        )  # the fee booked, the remit lock held
        t = threading.Thread(target=download)
        t.start()
        _started(pid, "download")
        assert _waits(pid["download"])  # on the remit lock (an advisory lock)
    t.join(30)
    assert not errors, errors
    v = result["v"]
    assert v["refused"] == "file_blocked"
    assert [b["reason"] for b in v["blocked"]] == ["sweep_exceeds_share"]
    assert int(v["blocked"][0]["sweep_minor"]) - int(v["blocked"][0]["share_minor"]) == 700
    assert _file_row(f["id"])["status"] == "superseded"


@pytest.mark.parametrize("other", ["generate", "cancel"])
@pytest.mark.parametrize("first", ["download", "other"])
def test_the_download_and_a_regeneration_or_a_cancellation_one_waits_for_the_other(
    tmp_path: Path, other: str, first: str
) -> None:
    """The first download (its re-check under the generation's locks) beside the file's
    regeneration and its run's cancellation, either holding its locks first: the other waits for
    its commit, raises no deadlock, and gets the outcome its turn gives. The first command runs to
    its end before the second starts, so this shows the wait, not the lock order: an inversion
    between them would pass it too (review M2c-6b-2a CS-1; ADR-0014 records the interleaved test
    as left to 6b-2b, whose command adds locks to this order)."""
    tenant, _client, r1, _r2 = _two_runs()
    res = _generate(tenant)
    drain_remittances()
    f = _file_row(res["file_id"])
    data = _bytes(f["storage_path"], tmp_path)
    version = run_row(r1)["version"]
    outcome: dict[str, Any] = {}
    errors: list[BaseException] = []
    pids: dict[str, int] = {}

    def command(conn: psycopg.Connection[Any]) -> Any:
        as_user(conn, tenant["admin"], "aal2")
        if other == "generate":
            row = conn.execute(
                "select public.generate_transfer_file(%s, %s, null)",
                (str(uuid.uuid4()), tenant["bank"]),
            ).fetchone()
        else:
            row = conn.execute(
                "select public.cancel_remittance_run(%s, %s, %s, %s)",
                (str(uuid.uuid4()), r1, version, "test"),
            ).fetchone()
        return row[0] if row else None

    def second(name: str) -> None:
        try:
            with _session() as conn, conn.transaction():
                pids[name] = conn.info.backend_pid
                outcome[name] = (
                    _download(conn, tenant, f, data) if name == "download" else command(conn)
                )
        except psycopg.Error as exc:
            outcome[name] = (exc.sqlstate, exc.diag.message_primary)
            if exc.sqlstate == "40P01":
                errors.append(exc)
        except BaseException as exc:  # asserted below
            errors.append(exc)

    later = "other" if first == "download" else "download"
    with _session() as conn, conn.transaction():
        outcome[first] = _download(conn, tenant, f, data) if first == "download" else command(conn)
        t = threading.Thread(target=second, args=(later,))
        t.start()
        _started(pids, later)
        assert _waits(pids[later], None)
    t.join(30)
    assert not errors, errors
    if first == "download":
        assert outcome["download"]["status"] == "downloaded"
        assert outcome["other"] == (
            ("23514", "transfer file refused: nothing_to_file")
            if other == "generate"
            # the download moved the run to sent (its version bumped): the cancellation read before
            # it is refused on the version, under the same locks
            else ("23514", "remittance run refused: version_changed")
        )
    else:
        assert outcome["download"] == ("23514", "transfer file refused: not_downloadable")
    want = "sent" if first == "download" else "cancelled" if other == "cancel" else "approved"
    assert run_row(r1)["status"] == want, json.dumps(outcome, default=str)
