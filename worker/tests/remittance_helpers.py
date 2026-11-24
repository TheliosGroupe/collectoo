"""Helpers for the remittance run integration tests (need `make up`): a servicer with its dedicated
account and clients ready for runs (billing identities, a mandate with complete terms, a confirmed
payout IBAN), files paid through the payments queue, the remittances queue drained, and the runs
read back."""

from __future__ import annotations

import json
import random
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import date, timedelta
from typing import Any

import psycopg
from allocation_helpers import File, Item, create_file, credit, statement
from integration_helpers import DB, SCHEDULE, TERMS, as_user, one, ready_mandate, storage
from statement_helpers import bank_tenant

from collectoo_worker.jobs.remittances import make_handler, record_dead_job
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.synth.ids import iban_fr

USER_SQL = (
    "insert into auth.users (id, email, aud, role)"
    " values (%s, %s, 'authenticated', 'authenticated')"
)


def paris_today() -> date:
    with psycopg.connect(DB) as conn:
        return one(conn, "select private.paris_today()")  # type: ignore[no-any-return]


def recent_business_day(back: int = 3) -> date:
    """A business day a few days ago: collections recent enough that no deadline is near."""
    with psycopg.connect(DB) as conn:
        return one(  # type: ignore[no-any-return]
            conn,
            """select max(c.day) from public.business_calendar c
               where c.day <= private.paris_today() - %s and not c.closed""",
            (back,),
        )


def confirm_payout(conn: psycopg.Connection[Any], tenant: dict[str, Any], client: str) -> str:
    iban = iban_fr(random.Random(f"payout-{client}"))
    doc = one(
        conn,
        """insert into public.document (organization_id, client_organization_id, kind, storage_path,
             sha256, mime_type) values (%s, %s, 'payout_rib', %s, %s, 'application/pdf')
           returning id""",
        (tenant["servicer"], client, f"client/test/{uuid.uuid4()}.pdf", "b" * 64),
    )
    account = one(
        conn,
        """insert into public.client_payout_account (organization_id, client_organization_id,
             currency, iban, holder_name, evidence_document_id, proposed_by)
           values (%s, %s, 'EUR', %s, 'Client SAS', %s, %s) returning id""",
        (tenant["servicer"], client, iban, doc, tenant["staff"]),
    )
    user = uuid.uuid4()
    conn.execute(
        USER_SQL,
        (user, f"{user}@c.test"),
    )
    conn.execute(
        """update public.client_payout_account set status = 'active', confirmed_by = %s,
             confirmed_at = now(), confirmed_via = 'client_portal' where id = %s""",
        (user, account),
    )
    return str(account)


def remittance_tenant(
    schedule: dict[str, Any] | None = None, terms: dict[str, Any] | None = None
) -> dict[str, Any]:
    """A servicer with its dedicated account (EUR) and one client ready for runs; the tenant's
    portfolio is the client's, under a mandate with complete terms (15 % flat, netting by
    default)."""
    tenant = bank_tenant()
    with psycopg.connect(DB) as conn, conn.transaction():
        tenant["mandate"] = ready_mandate(conn, tenant, f"MAND-{uuid.uuid4().hex[:6]}")
        if schedule is not None or terms is not None:
            # the version is in force from its signature (immutable then): set before any use
            conn.execute("alter table public.mandate_terms disable trigger mandate_terms_guard")
            conn.execute(
                """update public.mandate_terms
                   set commission_schedule = coalesce(%s, commission_schedule),
                     remittance_terms = coalesce(%s, remittance_terms) where mandate_id = %s""",
                (
                    None if schedule is None else json.dumps(schedule),
                    None if terms is None else json.dumps(terms),
                    tenant["mandate"],
                ),
            )
            conn.execute("alter table public.mandate_terms enable trigger mandate_terms_guard")
        tenant["payout"] = confirm_payout(conn, tenant, tenant["client"])
        admin = uuid.uuid4()
        conn.execute(
            USER_SQL,
            (admin, f"{admin}@s.test"),
        )
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'admin')",
            (admin, tenant["servicer"]),
        )
        tenant["admin"] = str(admin)
    return tenant


def add_admin(tenant: dict[str, Any]) -> str:
    """An admin of the tenant's servicer (cancellations are an admin's)."""
    admin = uuid.uuid4()
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(USER_SQL, (admin, f"{admin}@s.test"))
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'admin')",
            (admin, tenant["servicer"]),
        )
    return str(admin)


def add_client(tenant: dict[str, Any], name: str = "C2") -> dict[str, Any]:
    """Another client of the same servicer, ready for runs (its portfolio, mandate and IBAN)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        client = one(
            conn,
            """insert into public.organization (kind, servicer_organization_id, legal_name, siren)
               values ('creditor_client', %s, %s, '552100554') returning id""",
            (tenant["servicer"], name),
        )
        portfolio = one(
            conn,
            """insert into public.portfolio (organization_id, client_organization_id, name)
               values (%s, %s, 'P') returning id""",
            (tenant["servicer"], client),
        )
        other = {**tenant, "client": client, "portfolio": portfolio}
        other["mandate"] = ready_mandate(conn, other, f"MAND-{uuid.uuid4().hex[:6]}")
        other["payout"] = confirm_payout(conn, other, str(client))
    return other


def paid_file(
    tenant: dict[str, Any], amount: int, day: date | None = None, prefix: str | None = None
) -> tuple[File, str]:
    """A B2B file with one invoice of `amount`, paid in full by RF on `day`: imported, matched and
    allocated through the payments queue. Returns the file and the payment."""
    day = day or recent_business_day()
    f = create_file(
        tenant,
        File(
            f"F-{uuid.uuid4().hex[:8]}",
            "b2b",
            "Débiteur SARL",
            [Item("INV-1", {"principal": amount}, date(2026, 9, 1))],
        ),
    )
    p = prefix or f"R{uuid.uuid4().hex[:6].upper()}"
    ids = statement(tenant, storage(), [credit(amount, rf=f.rf)], p, day)
    return f, next(iter(ids.values()))


def _drain_queue() -> None:
    consumer = QueueConsumer(DB, "remittances", make_handler(storage()), on_dead=record_dead_job)
    while consumer.poll_once():
        pass


def drain() -> None:
    """The remittances queue drained — then (M2c-7c-1, carried low 4) the runs approve() queued with
    their default execution date that a change of the Paris date alone sent back to draft are
    validated again, as ops would the next morning (revalidate_after_date_change), and drained."""
    _drain_queue()
    while _VALIDATED:
        groups: dict[tuple[str, date], tuple[dict[str, Any], list[str]]] = {}
        for run, (tenant, since) in _VALIDATED.items():
            groups.setdefault((str(tenant["servicer"]), since), (tenant, []))[1].append(run)
        _VALIDATED.clear()
        today = paris_today()
        again = False
        for (_servicer, since), (tenant, runs) in groups.items():
            if since == today:
                continue  # no date change: every refusal is the caller's to see
            for run in revalidate_after_date_change(tenant, runs, since):
                _VALIDATED[run] = (tenant, today)
                again = True
        if not again:
            break
        _drain_queue()


def staff(tenant: dict[str, Any], sql: str, *params: Any, user: str | None = None) -> Any:
    """A command as the ops manager (or `user`) at aal2, within the API's 8 s."""
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, user or tenant["staff"], "aal2")
        conn.execute("set local statement_timeout = '8s'")
        row = conn.execute(sql, params).fetchone()
    return row[0] if row else None


def request_run(tenant: dict[str, Any]) -> str:
    result = staff(
        tenant,
        "select public.request_remittance_run(%s, %s, 'EUR')",
        str(uuid.uuid4()),
        tenant["client"],
    )
    drain()
    return str(result["run_id"])


def run_row(run: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute("select * from public.remittance_run where id = %s", (run,))
        row = cur.fetchone()
        assert row is not None and cur.description is not None
        return {d.name: v for d, v in zip(cur.description, row, strict=True)}


# (M2c-7c-1, carried low 4) the runs approve() queued with their default execution date, each with
# its tenant and the Paris day « Valider » was issued: drain() validates again those a date change
# alone sent back to draft. A run approved for an explicit day is the test's: never re-validated.
_VALIDATED: dict[str, tuple[dict[str, Any], date]] = {}


def approve(
    tenant: dict[str, Any], *runs: str, day: date | None = None, late_reason: str | None = None
) -> dict[str, Any]:
    since = paris_today()
    items = []
    for r in runs:
        row = run_row(r)
        items.append(
            {"run_id": r, "inputs_hash": row["inputs_hash"], "net_text": str(row["net_minor"])}
        )
    result = staff(
        tenant,
        "select public.approve_remittance_runs(%s, %s, %s, %s)",
        str(uuid.uuid4()),
        json.dumps(items),
        day,
        late_reason,
    )
    if day is None:
        for x in result["results"]:
            if x["status"] == "queued":
                _VALIDATED[str(x["run_id"])] = (tenant, since)
    return dict(result)


# (M2c-7c-1, ADR-0014 « M2c-7c-1 », carried low 4) The approval job's refusals a change of the Paris
# date alone causes: « Valider » shortly before midnight (Paris) asks for the next business day by
# default, and a job run after midnight finds that day is today with no cut-off recorded
# (execution_date_after_cutoff), or already passed (execution_date_passed).
DATE_CHANGE_REFUSALS = ("execution_date_after_cutoff", "execution_date_passed")


def date_change_refusals(runs: list[str], since: date) -> list[tuple[str, str, str]]:
    """The runs of `runs` a Paris date change sent back to draft: refused by the approval job with
    one of DATE_CHANGE_REFUSALS, on a Paris day after `since` (the day « Valider » was issued),
    while today is no longer `since`. Their (id, inputs_hash, net) as « Valider » sends them. Any
    other refusal is never returned: the caller's own assertions see it."""
    with psycopg.connect(DB) as conn:
        if one(conn, "select private.paris_today()") == since:
            return []
        rows = conn.execute(
            """select r.id::text, r.inputs_hash, r.net_minor::text from public.remittance_run r
               where r.id = any(%s::uuid[]) and r.status = 'draft' and r.job is null
                 and r.last_failure ->> 'step' = 'approve'
                 and r.last_failure ->> 'code' = any(%s::text[])
                 and ((r.last_failure ->> 'at')::timestamptz at time zone 'Europe/Paris')::date > %s
               order by r.id""",
            (runs, list(DATE_CHANGE_REFUSALS), since),
        ).fetchall()
    return [(str(r[0]), str(r[1]), str(r[2])) for r in rows]


def revalidate_after_date_change(tenant: dict[str, Any], runs: list[str], since: date) -> list[str]:
    """What ops do the next morning: each run a date change sent back to draft
    (date_change_refusals) validated again with a fresh « Valider » (its default execution date,
    200 runs a command). The runs re-validated; the caller drains the approval jobs again."""
    rows = date_change_refusals(runs, since)
    for k in range(0, len(rows), 200):
        items = [{"run_id": r, "inputs_hash": h, "net_text": t} for r, h, t in rows[k : k + 200]]
        out = staff(
            tenant,
            "select public.approve_remittance_runs(%s, %s)",
            str(uuid.uuid4()),
            json.dumps(items),
        )
        assert {x["status"] for x in out["results"]} == {"queued"}, out
    return [r for r, _h, _t in rows]


def documents(run: str) -> list[dict[str, Any]]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            """select kind, number, seq, issue_date, ht_minor, vat_minor, ttc_minor, settlement,
                      reason
               from public.commission_invoice where run_id = %s order by seq""",
            (run,),
        )
        assert cur.description is not None
        names = [d.name for d in cur.description]
        return [dict(zip(names, r, strict=True)) for r in cur.fetchall()]


def entry_books(entry: str) -> dict[str, int]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select la.book, sum(p.amount_minor) from public.ledger_posting p
               join public.ledger_account la on la.id = p.ledger_account_id
               where p.entry_id = %s group by la.book""",
            (entry,),
        ).fetchall()
    return {r[0]: int(r[1]) for r in rows}


def next_business_day() -> date:
    with psycopg.connect(DB) as conn:
        return one(conn, "select private.next_business_day(private.paris_today())")  # type: ignore[no-any-return]


def book_payout(run: str) -> None:
    """The payout's debit through the real path (M2c-6b-1, plan docs/design/m2c-6b-plan.md §2):
    the run's transfer filed if it is not yet (a file generated, written by the job), the file
    downloaded, then a one-day statement of its debit (by its RMT id, chained to the account's last
    closing balance) imported and the payments queue drained — the M2b pass, then the funds pass
    books the remittance, the run's settlement, the transfer and the run (`bank_line_booking`)."""
    import hashlib  # noqa: PLC0415 - only this helper
    import tempfile  # noqa: PLC0415
    from pathlib import Path  # noqa: PLC0415

    from statement_helpers import drain as drain_payments  # noqa: PLC0415
    from statement_helpers import upload  # noqa: PLC0415

    from collectoo_worker.synth.camt053 import Entry, Tx, make_doc, render_camt053  # noqa: PLC0415

    r = run_row(run)
    with psycopg.connect(DB) as conn:
        t = conn.execute(
            """select t.id, t.status, t.transfer_file_id, t.debtor_bank_account_id, t.amount_minor,
                      t.end_to_end_id, t.payee_name, t.payee_iban, a.iban,
                      (select m.user_id from public.membership m
                       where m.organization_id = t.organization_id and m.role = 'ops_manager'
                       order by m.user_id limit 1)
               from public.bank_transfer t
               join public.bank_account a on a.id = t.debtor_bank_account_id
               where t.run_id = %s and t.kind = 'payout' and t.status <> 'cancelled'""",
            (run,),
        ).fetchone()
    assert t is not None
    tenant = {"servicer": str(r["organization_id"]), "staff": str(t[9]), "bank": str(t[3]),
              "iban": t[8]}  # fmt: skip
    file_id = t[2]
    if t[1] == "ordered":
        _bank_catch_up(tenant)
        file_id = staff(tenant, "select public.generate_transfer_file(%s, %s, null)",
                        str(uuid.uuid4()), tenant["bank"])["file_id"]  # fmt: skip
        drain()
    with psycopg.connect(DB) as conn:
        f = conn.execute(
            "select id, status, storage_path from public.transfer_file where id = %s", (file_id,)
        ).fetchone()
        last = conn.execute(
            """select closing_booked_minor, to_date from public.bank_statement
               where bank_account_id = %s order by to_date desc, created_at desc limit 1""",
            (tenant["bank"],),
        ).fetchone()
    assert f is not None and last is not None
    if f[1] == "generated":
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "f.xml"
            storage().download("transfer-files", f[2], dest)
            digest = hashlib.sha256(dest.read_bytes()).hexdigest()
        staff(tenant, "select public.transfer_file_download(%s, %s)", f[0], digest)
    # dated as the account's last statement: the tests' later statements (each from a zero opening)
    # stay the last ones the cash check of the next file reads
    day = last[1]
    ref = f"BP{uuid.uuid4().hex[:10].upper()}"
    debit = Entry(int(t[4]), False, day, day, ref=ref, code="PMNT/ICDT/ESCT",
                  txs=(Tx(int(t[4]), end_to_end_id=t[5], name=t[6], iban=t[7]),))  # fmt: skip
    doc = make_doc([debit], iban=tenant["iban"], from_date=day, to_date=day,
                   opening_minor=int(last[0]), stmt_id=f"S-{ref}")  # fmt: skip
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{ref}.xml")
    drain_payments(storage())
    status = run_row(run)["status"]
    assert status == "booked", f"the run's debit was not booked: {status}"


def own_account(tenant: dict[str, Any]) -> tuple[str, str]:
    """The servicer's own account (sweeps go to it, top-ups come from it), in its billing
    settings: (its id, its IBAN)."""
    iban = iban_fr(random.Random(f"own-{tenant['servicer']}"))
    with psycopg.connect(DB) as conn, conn.transaction():
        own = one(
            conn,
            """insert into public.bank_account (organization_id, purpose, iban, currency, label,
                 opened_on) values (%s, 'own', %s, 'EUR', 'Compte propre', '2026-01-01')
               returning id""",
            (tenant["servicer"], iban),
        )
        conn.execute(
            """insert into public.servicer_billing_settings (organization_id, own_bank_account_id)
               values (%s, %s) on conflict (organization_id)
               do update set own_bank_account_id = excluded.own_bank_account_id""",
            (tenant["servicer"], own),
        )
    return str(own), iban


def _last_statement(tenant: dict[str, Any]) -> tuple[int, date]:
    with psycopg.connect(DB) as conn:
        last = conn.execute(
            """select closing_booked_minor, to_date from public.bank_statement
               where bank_account_id = %s order by to_date desc, created_at desc limit 1""",
            (tenant["bank"],),
        ).fetchone()
    assert last is not None
    return int(last[0]), last[1]


def book_sweep(tenant: dict[str, Any]) -> int:
    """The servicer's share swept (M2c-6): the next file generated (it carries the sweep), written
    by the job and downloaded, then a one-day statement of the sweep's debit (by its SWP id,
    chained to the account's last closing balance) imported and the payments queue drained — the
    funds pass books it (servicer_sweep). Its amount."""
    import hashlib  # noqa: PLC0415 - only this helper
    import tempfile  # noqa: PLC0415
    from pathlib import Path  # noqa: PLC0415

    from statement_helpers import upload  # noqa: PLC0415

    from collectoo_worker.synth.camt053 import Entry, Tx, make_doc, render_camt053  # noqa: PLC0415

    _bank_catch_up(tenant)
    file_id = staff(tenant, "select public.generate_transfer_file(%s, %s, null)",
                    str(uuid.uuid4()), tenant["bank"])["file_id"]  # fmt: skip
    drain()
    with psycopg.connect(DB) as conn:
        f = conn.execute(
            "select id, storage_path from public.transfer_file where id = %s", (file_id,)
        ).fetchone()
        s = conn.execute(
            """select t.id, t.amount_minor, t.end_to_end_id, t.payee_name, t.payee_iban
               from public.bank_transfer t
               where t.transfer_file_id = %s and t.kind = 'sweep'""",
            (file_id,),
        ).fetchone()
    assert f is not None and s is not None
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "f.xml"
        storage().download("transfer-files", f[1], dest)
        digest = hashlib.sha256(dest.read_bytes()).hexdigest()
    staff(tenant, "select public.transfer_file_download(%s, %s)", f[0], digest)
    opening, day = _last_statement(tenant)
    ref = f"SW{uuid.uuid4().hex[:10].upper()}"
    debit = Entry(int(s[1]), False, day, day, ref=ref, code="PMNT/ICDT/ESCT",
                  txs=(Tx(int(s[1]), end_to_end_id=s[2], name=s[3], iban=s[4]),))  # fmt: skip
    doc = make_doc([debit], iban=tenant["iban"], from_date=day, to_date=day,
                   opening_minor=opening, stmt_id=f"S-{ref}")  # fmt: skip
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{ref}.xml")
    drain_payments_queue()
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.bank_transfer where id = %s", (s[0],))
    assert status == "booked", f"the sweep's debit was not booked: {status}"
    return int(s[1])


def top_up(tenant: dict[str, Any], own: str, own_iban: str, amount: int) -> None:
    """A top-up of the dedicated account from the own account (design §13; ordered by hand until
    7e): ordered by ops, its credit (its TOP id, from the own IBAN) on a statement of the day,
    booked by the debit job (servicer_top_up)."""
    from statement_helpers import upload  # noqa: PLC0415

    from collectoo_worker.synth.camt053 import Entry, Tx, make_doc, render_camt053  # noqa: PLC0415

    top = staff(
        tenant,
        "select public.request_top_up(%s, %s, %s, %s, 'couvrir l''avance du cabinet')",
        str(uuid.uuid4()),
        own,
        tenant["bank"],
        str(amount),
    )
    opening, day = _last_statement(tenant)
    ref = f"TU{uuid.uuid4().hex[:10].upper()}"
    tx = Tx(amount, ref=f"L{ref}", end_to_end_id=top["end_to_end_id"], iban=own_iban)
    credit = Entry(amount, True, day, day, ref=ref, txs=(tx,))
    doc = make_doc([credit], iban=tenant["iban"], from_date=day, to_date=day,
                   opening_minor=opening, stmt_id=f"S-{ref}")  # fmt: skip
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{ref}.xml")
    drain_payments_queue()
    with psycopg.connect(DB) as conn:
        status = one(
            conn, "select status from public.bank_transfer where id = %s", (top["transfer_id"],)
        )
    assert status == "booked", f"the top-up's credit was not booked: {status}"


def _bank_catch_up(tenant: dict[str, Any]) -> None:
    """The tests' statements each open at zero; the cash check of a file reads the last closing
    balance. A statement without lines that opens and closes at the account's booked cash (5120)
    makes the bank say what the ledger holds, as a real chained statement would."""
    from statement_helpers import upload  # noqa: PLC0415

    from collectoo_worker.synth.camt053 import make_doc, render_camt053  # noqa: PLC0415

    with psycopg.connect(DB) as conn:
        cash = one(
            conn,
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_account a
               join public.ledger_posting p on p.ledger_account_id = a.id
               where a.book = 'client_money_cash' and a.bank_account_id = %s""",
            (tenant["bank"],),
        )
        last = conn.execute(
            """select closing_booked_minor, to_date from public.bank_statement
               where bank_account_id = %s order by to_date desc, created_at desc limit 1""",
            (tenant["bank"],),
        ).fetchone()
    assert last is not None
    if int(last[0]) == int(cash):
        return
    ref = f"BC{uuid.uuid4().hex[:10].upper()}"
    doc = make_doc([], iban=tenant["iban"], from_date=last[1], to_date=last[1],
                   opening_minor=int(cash), stmt_id=f"S-{ref}")  # fmt: skip
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{ref}.xml")
    drain_payments_queue()


def drain_payments_queue() -> None:
    from statement_helpers import drain as drain_payments  # noqa: PLC0415

    drain_payments(storage())


@contextmanager
def vat_rate_from_today(rate: str) -> Iterator[None]:
    """Another standard rate from today (a change of the reference data), restored afterwards."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("alter table public.vat_rate disable trigger vat_rate_guard")
        conn.execute(
            "update public.vat_rate set valid_to = private.paris_today()"
            " where valid_from = '2014-01-01'"
        )
        conn.execute(
            """insert into public.vat_rate (code, territory, rate, valid_from, valid_to, legal_ref,
                 legal_url) values ('standard', 'FR-metro', %s, private.paris_today(), '2027-01-01',
                 'test', 'https://librejustice.fr/norm/fr/code-general-des-impots/278')""",
            (rate,),
        )
        conn.execute("alter table public.vat_rate enable always trigger vat_rate_guard")
    try:
        yield
    finally:
        with psycopg.connect(DB) as conn, conn.transaction():
            conn.execute("alter table public.vat_rate disable trigger vat_rate_guard")
            conn.execute("delete from public.vat_rate where legal_ref = 'test'")
            conn.execute(
                "update public.vat_rate set valid_to = '2027-01-01' where valid_from = '2014-01-01'"
            )
            conn.execute("alter table public.vat_rate enable always trigger vat_rate_guard")


__all__ = ["SCHEDULE", "TERMS", "timedelta"]
