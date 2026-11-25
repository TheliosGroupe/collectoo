"""M2c-7d-3 (needs `make up`; ADR-0014 « M2c-7d-3 »): the slice's reads by a parameter or a
correlated key stay keyed whatever the statistics — the plan class that broke main after 7a (a key
the last analyse saw with two values, priced at half the table: a sequential scan, a hash of the
whole table, a partial index whose predicate a parameter's filter implies).

In the test's rolled-back transaction the tables are planted — 7d-2's planted tables (and 7d-1's,
7c-1's) and PLANTED rows each of: the bookings of two other transfers (bank_line_booking, its
transfer at two values), the dispositions of other payouts (liquidation_payout_disposition), the
outcomes of other settlements (set_off_outcome) and the booked runs of two other servicers
(remittance_run, each with a transfer), each analysed with its keys' n_distinct pinned (2);
every plan generic. Then, on a client whose run set off its invoices at its payout's debit, a
liquidation recorded afterwards (effective before the debit): the client's procedure facts, its
claims to declare, its unpaid post-opening invoices, its payouts after the liquidation, the
nightly's advance checks whole (private.run_advance_checks: claims_to_declare, post_opening_unpaid,
payout_after_liquidation, set_off_after_bar with the outcomes read), the remittance runs' checks
whole (invoice_overdue's new exclusions), « Enregistrer la suite »
(public.record_liquidation_payout_disposition), « Compensation maintenue »
(public.record_set_off_outcome), the statement build with fr-4's parts (the end of the mandate and
the addressees as of K: a death recorded in a savepoint, the withheld rows), and the run page's
withheld read (public.remittance_run_withheld) — and the rows each read from the planted tables: a
few per call, never the planted rows.

The nightly's two functions read the servicer's own rows whole by design (its invoices, its
advances: earlier slices' plants are the servicer's); for them the bound is the 7d-2 bodies' own
reads, measured in the same transaction (their latest definitions, read from the migration files):
7d-3's redefinitions add a few rows at most (PER_CALL) to any watched table's, and read none of
7d-3's planted rows. (Review round 1, CC-1) invoice_overdue asks private.invoice_to_declare only for
the invoices of a client in a proceeding or a liquidation: its calls (pg_stat_xact_user_functions)
stay within PER_CALL whatever the servicer's other overdue invoices (7c-1's 10,000).

(Review round 1, CC-2) a second client, through the real jobs: a redressement recorded after its
run's file was downloaded, the debit withholds the set-off; the next run gives it back, its payout
is returned (a camt.053 return) and paid again by a later run (the payout account confirmed
again). Under the same plants: the withheld run's read (public.remittance_run_withheld, following
the returned payout to the run that repaid it: private.withheld_given_back) and the giving run's
statement build (its withheld row) — a few rows per call, never the planted bookings.

(Review round 2) two more clients through the real jobs, each run setting its own invoice off in
full, the file downloaded, then a liquidation (the first) or a death (the second) recorded: the
debit withholds the set-off and the invoice has no due date of its own. Under the same plants:
the day it was withheld (private.invoice_withheld_on), the client in liquidation's unpaid
post-opening invoices, the nightly's two functions whole for each servicer (post_opening_unpaid
lists the first, invoice_overdue the second) — a few rows per call beyond the 7d-2 bodies'.

(Review round 3) two more clients through the real jobs, each run setting its own invoice off in
full, approved, its payout ordered in no file, then a liquidation (the first) or a death and a
seizure (the second) recorded. Under the same plants: the day each bar was recorded
(private.client_set_off_bar_recorded_on), the client in liquidation's unpaid post-opening invoices
(its own invoice listed from the next day), the nightly's advance checks whole, and the statement
build with two ends known on different days (`earlier`) — a few rows per call beyond the 7d-2
body's."""

from __future__ import annotations

import json
import uuid
from datetime import timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import DB, one, storage
from remittance_helpers import (
    approve,
    book_payout,
    confirm_payout,
    drain,
    paid_file,
    paris_today,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from test_client_payment_reads_integration import _as
from test_client_payments_integration import _evidence
from test_set_off_bar_reads_integration import WATCHED as WATCHED_7D2
from test_set_off_bar_reads_integration import _plant as _plant_7d2
from test_set_off_bars_integration import (
    NO_NETTING,
    _download,
    _due_invoice,
    _event,
    _netting_from_now,
)

pytestmark = pytest.mark.integration
PLANTED = 10_000
PER_CALL = 60
WATCHED = (
    *WATCHED_7D2,
    "public.bank_line_booking",
    "public.bank_transfer",
    "public.remittance_run",
    "public.claims_declared_item",
    "public.liquidation_payout_disposition",
    "public.set_off_outcome",
    "public.client_payout_account",
)
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"
MIGRATIONS = Path(__file__).resolve().parents[2] / "supabase/migrations"
# the nightly's functions as 7d-3 found them: (file, the first line of their latest definition)
BEFORE_7D3 = (
    (
        "20261127090000_set_off_bars.sql",
        "create or replace function private.run_advance_checks(",
    ),
    (
        "20261121120000_switch_on_prerequisites_5.sql",
        "create or replace function private.run_remittance_runs_checks(",
    ),
)
# 7d-3's planted tables: never read by the nightly's whole calls beyond PER_CALL
NEW_PLANTS = ("bank_line_booking", "liquidation_payout_disposition", "set_off_outcome")


def _nightly_before_7d3(
    conn: psycopg.Connection[Any], org: str, nightly: tuple[tuple[str, str, str, Any], ...]
) -> dict[str, dict[str, int]]:
    """The nightly's two functions with their 7d-2 bodies, on the same books (a savepoint): the
    rows each read."""
    before: dict[str, dict[str, int]] = {}
    with conn.transaction(force_rollback=True):
        for file, head in BEFORE_7D3:
            conn.execute(_body_before_7d3(file, head))
        for name, _fn, sql, day in nightly:
            check = one(
                conn,
                "insert into public.payment_check_run (organization_id) values (%s) returning id",
                (org,),
            )
            b0 = _rows(conn)
            conn.execute(sql, (check, org, day))
            b1 = _rows(conn)
            before[name] = {k: b1[k] - b0[k] for k in b1 if b1[k] - b0[k]}
    return before


def _body_before_7d3(file: str, head: str) -> str:
    """The function's definition in that migration, from its head to the end of its body."""
    text = (MIGRATIONS / file).read_text()
    start = text.index(head)
    end = text.index("\n$$;", start) + len("\n$$;")
    return text[start:end]


def _plants() -> tuple[tuple[str, str, dict[str, int]], ...]:
    return (
        (
            # the unplanned bookings of two other transfers (lines, entries and transfers made up:
            # no foreign key checked while planting)
            f"""insert into public.bank_line_booking (bank_transaction_id, seq, organization_id,
                 bank_account_id, kind, transfer_id, entry_id, amount_minor, method)
               select gen_random_uuid(), 1, k.org[1 + g % 2], k.acct[1 + g % 2], 'unplanned_payout',
                      k.tr[1 + g % 2], gen_random_uuid(), 100, 'auto'
               from (select {TWO} org, {TWO} acct, {TWO} tr) k, generate_series(1, {PLANTED}) g""",  # noqa: S608
            "public.bank_line_booking",
            {"transfer_id": 2, "organization_id": 2},
        ),
        (
            # the dispositions of other payouts
            f"""insert into public.liquidation_payout_disposition (organization_id,
                 client_organization_id, transfer_id, kind, evidence_document_id, recorded_by)
               select k.org[1 + g % 2], k.client[1 + g % 2], gen_random_uuid(), 'ratified',
                      k.doc[1 + g % 2], k.usr[1 + g % 2]
               from (select {TWO} org, {TWO} client, {TWO} doc, {TWO} usr) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.liquidation_payout_disposition",
            {"organization_id": 2, "client_organization_id": 2},
        ),
        (
            # the outcomes of other settlements
            f"""insert into public.set_off_outcome (entry_id, organization_id,
                 client_organization_id, kind, evidence_document_id, recorded_by)
               select gen_random_uuid(), k.org[1 + g % 2], k.client[1 + g % 2], 'kept',
                      k.doc[1 + g % 2], k.usr[1 + g % 2]
               from (select {TWO} org, {TWO} client, {TWO} doc, {TWO} usr) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.set_off_outcome",
            {"organization_id": 2, "client_organization_id": 2},
        ),
        (
            # the booked runs of two other servicers' two clients, each with its transfer (copies of
            # the latest booked run: the statement's earlier payouts, the run chains of the payouts
            # after a liquidation, the withheld set-offs' runs, all read by key)
            f"""insert into public.remittance_run
               select (jsonb_populate_record(null::public.remittance_run, to_jsonb(r)
                        || jsonb_build_object('id', gen_random_uuid(),
                             'organization_id', k.org[1 + g % 2],
                             'client_organization_id', k.client[1 + g % 2],
                             'number', 'RV-2099-' || lpad(g::text, 6, '0'),
                             'transfer_id', gen_random_uuid(), 'schedule_key', null,
                             'status', 'booked'))).*
               from (select {TWO} org, {TWO} client) k,
                    (select q.* from public.remittance_run q
                     where q.status = 'booked' order by q.created_at desc limit 1) r,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.remittance_run",
            {"organization_id": 2, "client_organization_id": 2},
        ),
    )


def _plant(conn: psycopg.Connection[Any], org: str) -> None:
    _plant_7d2(conn, org)
    conn.execute("set local session_replication_role = replica")
    for sql, table, _keys in _plants():
        always = [
            r[0]
            for r in conn.execute(
                """select t.tgname from pg_trigger t where t.tgrelid = %s::regclass
                     and not t.tgisinternal and t.tgenabled = 'A'""",
                (table,),
            ).fetchall()
        ]
        for t in always:
            conn.execute(f"alter table {table} disable trigger {t}")
        conn.execute(sql)
        for t in always:
            conn.execute(f"alter table {table} enable always trigger {t}")
    conn.execute("set local session_replication_role = origin")
    for _sql, table, keys in _plants():
        for key, n in keys.items():
            conn.execute(f"alter table {table} alter column {key} set (n_distinct = {n})")
        conn.execute(f"analyze {table}")


def _rows(conn: psycopg.Connection[Any]) -> dict[str, int]:
    rows = conn.execute(
        """select t.relid::regclass::text,
                  coalesce(pg_stat_get_xact_tuples_returned(t.relid), 0)
                  + coalesce((select sum(pg_stat_get_xact_tuples_returned(i.indexrelid))
                              from pg_index i where i.indrelid = t.relid), 0)
           from (select unnest(%s::regclass[]) relid) t""",
        (list(WATCHED),),
    ).fetchall()
    return {str(r[0]).replace("public.", ""): int(r[1]) for r in rows}


def _calls(conn: psycopg.Connection[Any], name: str) -> int:
    """The calls of private.<name> in this transaction (track_functions 'all')."""
    row = conn.execute(
        """select coalesce(sum(f.calls), 0) from pg_stat_xact_user_functions f
           where f.schemaname = 'private' and f.funcname = %s""",
        (name,),
    ).fetchone()
    return int(row[0]) if row else 0


@pytest.fixture(scope="module")
def paid() -> dict[str, Any]:
    """A client owing FC-1 (born d - 8); the netting clause on; its next run sets FC-1 and its own
    invoice off, approved and its payout debited (no event yet); the evidence of an event to
    record."""
    tenant = remittance_tenant(terms=NO_NETTING)
    d1 = recent_business_day(8)
    fc1 = _due_invoice(tenant, d1)
    _netting_from_now(tenant)
    paid_file(tenant, 400_000, day=recent_business_day(1))
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
    book_payout(run)
    return {
        "tenant": tenant,
        "fc1": fc1,
        "run": run,
        "judgment": d1 + timedelta(days=1),
        "evidence": _evidence(tenant, "client_status_evidence"),
    }


def test_the_declaration_and_liquidation_reads_stay_keyed_whatever_the_statistics(  # noqa: PLR0915
    paid: dict[str, Any],
) -> None:
    tenant = paid["tenant"]
    org, client, admin = str(tenant["servicer"]), str(tenant["client"]), str(tenant["admin"])
    run = paid["run"]
    measured: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn, org)
        conn.execute("set local plan_cache_mode = force_generic_plan")
        # (review round 1, CC-1) the per-invoice test's calls counted (SQL functions: 'all')
        conn.execute("set local track_functions = 'all'")

        def call(name: str, user: str | None, sql: str, *params: Any) -> Any:
            before = _rows(conn)
            if user is None:
                conn.execute("set role postgres")
            else:
                _as(conn, user)
            value = one(conn, sql, params)
            conn.execute("reset role")
            after = _rows(conn)
            measured[name] = {k: after[k] - before[k] for k in after if after[k] - before[k]}
            return value

        today = paris_today()
        # the statement build before any event: fr-3's payload, fr-4's reads made (the end, the
        # addressees)
        built = call(
            "remittance_statement_build (no event)",
            None,
            "select private.remittance_statement_build(%s)",
            run,
        )
        assert built["schema"] == 1, built.get("schema")
        # the liquidation, recorded after the debit, effective before it
        conn.execute(
            """insert into public.client_status_event (organization_id, client_organization_id,
                 kind, effective_date, evidence_document_id, recorded_by)
               values (%s, %s, 'liquidation', %s, %s, %s)""",
            (org, client, paid["judgment"], paid["evidence"], admin),
        )
        facts = call(
            "client_procedure_facts",
            None,
            "select row_to_json(f) from private.client_procedure_facts(%s, %s) f",
            client,
            today,
        )
        assert facts["liquidation_on"] == paid["judgment"].isoformat(), facts
        call(
            "client_claims_to_declare",
            None,
            "select count(*) from private.client_claims_to_declare(%s, %s)",
            client,
            today,
        )
        call(
            "client_post_opening_unpaid",
            None,
            "select count(*) from private.client_post_opening_unpaid(%s, %s)",
            client,
            today + timedelta(days=90),
        )
        after = call(
            "client_payouts_after_liquidation",
            None,
            "select count(*) from private.client_payouts_after_liquidation(%s, %s)",
            client,
            today,
        )
        assert after == 1, after
        check = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (org,),
        )
        nightly = (
            (
                "run_advance_checks (the nightly's advance checks, whole)",
                "run_advance_checks",
                "select private.run_advance_checks(%s, %s, %s, true)",
                today,
            ),
            (
                "run_remittance_runs_checks (invoice_overdue, whole)",
                "run_remittance_runs_checks",
                "select private.run_remittance_runs_checks(%s, %s, %s)",
                today + timedelta(days=90),
            ),
        )
        call(nightly[0][0], None, nightly[0][2], check, org, nightly[0][3])
        codes = {
            r[0]
            for r in conn.execute(
                "select code from public.payment_check_result where run_id = %s", (check,)
            ).fetchall()
        }
        assert {"payout_after_liquidation", "set_off_after_bar"} <= codes, codes
        check2 = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (org,),
        )
        to_declare, opened = _calls(conn, "invoice_to_declare"), _calls(conn, "document_open")
        call(nightly[1][0], None, nightly[1][2], check2, org, nightly[1][3])
        # (review round 1, CC-1) asked only for the client in liquidation's invoices, never for the
        # servicer's 10,000 others overdue (7c-1's plant: each one's open part read, the count live)
        to_declare = _calls(conn, "invoice_to_declare") - to_declare
        opened = _calls(conn, "document_open") - opened
        overdue = one(
            conn,
            "select count(*) from public.payment_check_result where run_id = %s"
            " and code = 'invoice_overdue'",
            (check2,),
        )
        assert overdue >= PLANTED and opened >= PLANTED, (overdue, opened)
        assert to_declare <= PER_CALL, to_declare
        transfer = one(conn, "select transfer_id from public.remittance_run where id = %s", (run,))
        done = call(
            "record_liquidation_payout_disposition",
            admin,
            "select public.record_liquidation_payout_disposition(%s, %s, 'ratified', %s, null)",
            str(uuid.uuid4()),
            transfer,
            paid["evidence"],
        )
        assert done["kind"] == "ratified", done
        settle = one(
            conn,
            "select id from public.ledger_entry where idempotency_key = %s",
            (f"settle:{run}",),
        )
        kept = call(
            "record_set_off_outcome",
            admin,
            "select public.record_set_off_outcome(%s, %s, 'kept', %s, null)",
            str(uuid.uuid4()),
            settle,
            paid["evidence"],
        )
        assert kept["kind"] == "kept", kept
        # a death recorded (in a savepoint): the statement's end of the mandate and its addressees
        # as of K
        with conn.transaction(force_rollback=True):
            conn.execute(
                """insert into public.client_status_event (organization_id,
                     client_organization_id, kind, effective_date, evidence_document_id,
                     recorded_by, recorded_at)
                   values (%s, %s, 'death', %s, %s, %s, now() - interval '30 days')""",
                (org, client, paid["judgment"], paid["evidence"], admin),
            )
            call(
                "remittance_statement_build (fr-4 parts)",
                None,
                "select private.remittance_statement_build(%s)",
                run,
            )
        shown = call(
            "remittance_run_withheld",
            str(tenant["staff"]),
            "select public.remittance_run_withheld(%s)",
            run,
        )
        assert shown is None, shown

        before = _nightly_before_7d3(conn, org, nightly)

    def over(name: str, rows: dict[str, int]) -> dict[str, int]:
        if name in before:
            return {
                t: n
                for t, n in rows.items()
                if n > before[name].get(t, 0) + PER_CALL or (t in NEW_PLANTS and n > PER_CALL)
            }
        return {t: n for t, n in rows.items() if n > PER_CALL}

    print(json.dumps({"7d-3": measured, "7d-2 bodies": before}, indent=1, sort_keys=True))
    overs = {name: over(name, rows) for name, rows in measured.items()}
    assert {k: v for k, v in overs.items() if v} == {}, (measured, before)


# -- (review round 1, CC-2) the withheld set-off given back, the giving payout returned, repaid ---


def _return_payout(run: str) -> None:
    """The run's payout returned by the bank (a one-day camt.053 of its return: a credit undoing the
    debit, by its end-to-end id, chained to the account's last closing balance), imported and the
    payments queue drained — the transfer `returned`, its payout_returned item queued."""
    from statement_helpers import drain as drain_payments  # noqa: PLC0415
    from statement_helpers import upload  # noqa: PLC0415

    from collectoo_worker.synth.camt053 import (  # noqa: PLC0415
        TRANSFER_RETURN_CODE,
        Entry,
        Tx,
        make_doc,
        render_camt053,
    )

    r = run_row(run)
    with psycopg.connect(DB) as conn:
        t = conn.execute(
            """select t.amount_minor, t.end_to_end_id, t.payee_name, t.payee_iban,
                      t.debtor_bank_account_id, a.iban,
                      (select m.user_id from public.membership m
                       where m.organization_id = t.organization_id and m.role = 'ops_manager'
                       order by m.user_id limit 1)
               from public.bank_transfer t
               join public.bank_account a on a.id = t.debtor_bank_account_id
               where t.run_id = %s and t.kind = 'payout' and t.status <> 'cancelled'""",
            (run,),
        ).fetchone()
        assert t is not None
        last = conn.execute(
            """select closing_booked_minor, to_date from public.bank_statement
               where bank_account_id = %s order by to_date desc, created_at desc limit 1""",
            (t[4],),
        ).fetchone()
    assert last is not None
    tenant = {"servicer": str(r["organization_id"]), "staff": str(t[6]), "bank": str(t[4])}
    day = last[1]
    ref = f"RT{uuid.uuid4().hex[:10].upper()}"
    back = Entry(int(t[0]), True, day, day, ref=ref, code=TRANSFER_RETURN_CODE,
                 txs=(Tx(int(t[0]), end_to_end_id=t[1], name=t[2], iban=t[3],
                         return_reason="AC04"),))  # fmt: skip
    doc = make_doc([back], iban=t[5], from_date=day, to_date=day,
                   opening_minor=int(last[0]), stmt_id=f"S-{ref}")  # fmt: skip
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{ref}.xml")
    drain_payments(storage())


@pytest.fixture(scope="module")
def repaid() -> dict[str, Any]:
    """A client owing FC-1 (born d - 8), the netting clause on; its run sets FC-1 off, approved, its
    file downloaded; a redressement recorded then (effective the day after FC-1's birth, published
    the next): the debit withholds the set-off. The next run gives it back, its payout debited then
    returned; the payout account confirmed again; a later run pays it again, debited."""
    tenant = remittance_tenant(terms=NO_NETTING)
    d1 = recent_business_day(8)
    _due_invoice(tenant, d1)
    _netting_from_now(tenant)
    paid_file(tenant, 400_000, day=recent_business_day(1))
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
    _download(tenant)
    opening = d1 + timedelta(days=1)
    staff(
        tenant,
        """select public.record_client_status_event(%s, %s, 'proceeding_opened', %s, %s,
             'Événement (test)', null, %s, null, null, null)""",
        str(uuid.uuid4()),
        tenant["client"],
        opening,
        _evidence(tenant, "client_status_evidence"),
        opening + timedelta(days=1),
        user=tenant["admin"],
    )
    book_payout(run)
    with psycopg.connect(DB) as conn:
        withheld = one(
            conn,
            "select count(*) from public.ledger_entry where idempotency_key = %s",
            (f"settle:{run}:barred",),
        )
    assert withheld == 1, "the debit did not withhold the set-off"
    giving = request_run(tenant)
    approve(tenant, giving)
    drain()
    assert run_row(giving)["status"] == "approved", run_row(giving)["last_failure"]
    book_payout(giving)
    _return_payout(giving)
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            """update public.client_payout_account set status = 'retired', closed_by = %s,
                 closed_at = now(), closed_reason = 'Remplacé après le retour du virement'
               where client_organization_id = %s and currency = 'EUR' and status = 'returned'""",
            (tenant["staff"], tenant["client"]),
        )
        confirm_payout(conn, tenant, tenant["client"])
    again = request_run(tenant)
    approve(tenant, again)
    drain()
    assert run_row(again)["status"] == "approved", run_row(again)["last_failure"]
    book_payout(again)
    return {"tenant": tenant, "run": run, "giving": giving, "again": again}


def test_the_withheld_set_off_s_reads_stay_keyed_through_a_returned_payout(
    repaid: dict[str, Any],
) -> None:
    tenant = repaid["tenant"]
    org = str(tenant["servicer"])
    measured: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn, org)
        conn.execute("set local plan_cache_mode = force_generic_plan")

        def call(name: str, user: str | None, sql: str, *params: Any) -> Any:
            before = _rows(conn)
            if user is None:
                conn.execute("set role postgres")
            else:
                _as(conn, user)
            value = one(conn, sql, params)
            conn.execute("reset role")
            after = _rows(conn)
            measured[name] = {k: after[k] - before[k] for k in after if after[k] - before[k]}
            return value

        shown = call(
            "remittance_run_withheld (returned, repaid)",
            str(tenant["staff"]),
            "select public.remittance_run_withheld(%s)",
            repaid["run"],
        )
        assert shown is not None
        assert (shown.get("given_back_by"), shown.get("returned_by")) == (
            run_row(repaid["again"])["number"],
            run_row(repaid["giving"])["number"],
        ), shown
        built = call(
            "remittance_statement_build (the withheld given back)",
            None,
            "select private.remittance_statement_build(%s)",
            repaid["giving"],
        )
        assert built["schema"] == 2, built.get("schema")
        assert [w["run_number"] for w in built["withheld_given_back"]] == [
            run_row(repaid["run"])["number"]
        ]
    print(json.dumps(measured, indent=1, sort_keys=True))
    overs = {n: {t: k for t, k in rows.items() if k > PER_CALL} for n, rows in measured.items()}
    assert {k: v for k, v in overs.items() if v} == {}, measured


# -- (review round 2) a run's own invoice netted in full whose set-off the debit withheld ----------


@pytest.fixture(scope="module")
def withheld_own() -> dict[str, Any]:
    """Two clients (each its own servicer) whose run sets its own invoice off in full (the netting
    clause), approved, the file downloaded; then a liquidation recorded for the first, a death for
    the second (each effective the day before its collection): each debit withholds the set-off —
    each run's own invoice open in full, with no due date of its own."""
    out: dict[str, Any] = {}
    for kind in ("liquidation", "death"):
        tenant = remittance_tenant()
        d1 = recent_business_day(1)
        paid_file(tenant, 400_000, day=d1)
        run = request_run(tenant)
        approve(tenant, run)
        drain()
        assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
        _download(tenant)
        _event(tenant, kind, d1 - timedelta(days=1))
        book_payout(run)
        with psycopg.connect(DB) as conn:
            invoice = one(
                conn,
                """select id from public.commission_invoice
                   where run_id = %s and kind = 'invoice' and settlement = 'netted'
                     and due_date is null""",
                (run,),
            )
            withheld = one(
                conn,
                "select count(*) from public.ledger_entry where idempotency_key = %s",
                (f"settle:{run}:barred",),
            )
            still = one(conn, "select private.document_open(%s)", (invoice,))
        assert withheld == 1, "the debit did not withhold the set-off"
        assert still > 0, still
        out[kind] = {"tenant": tenant, "run": run, "invoice": str(invoice)}
    return out


def test_a_withheld_own_invoice_s_reads_stay_keyed_whatever_the_statistics(
    withheld_own: dict[str, Any],
) -> None:
    """Under the plants (the first servicer's), the withheld invoice's day
    (private.invoice_withheld_on), the client in liquidation's unpaid post-opening invoices and the
    nightly's two functions whole for each servicer: post_opening_unpaid lists the first client's
    invoice, invoice_overdue the deceased client's; a few rows per call beyond the 7d-2 bodies'
    own, never the planted rows."""
    liq, dead = withheld_own["liquidation"], withheld_own["death"]
    measured: dict[str, dict[str, int]] = {}
    befores: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn, str(liq["tenant"]["servicer"]))
        conn.execute("set local plan_cache_mode = force_generic_plan")

        def call(name: str, sql: str, *params: Any) -> Any:
            before = _rows(conn)
            conn.execute("set role postgres")
            value = one(conn, sql, params)
            conn.execute("reset role")
            after = _rows(conn)
            measured[name] = {k: after[k] - before[k] for k in after if after[k] - before[k]}
            return value

        today = paris_today()
        on = call("invoice_withheld_on", "select private.invoice_withheld_on(%s)", liq["invoice"])
        assert on is not None and on < today, on
        unpaid = call(
            "client_post_opening_unpaid (a withheld own invoice)",
            "select array_agg(document_id::text) from private.client_post_opening_unpaid(%s, %s)",
            str(liq["tenant"]["client"]),
            today,
        )
        assert unpaid == [liq["invoice"]], unpaid
        for label, case, code in (
            (":liquidation", liq, "post_opening_unpaid"),
            (":death", dead, "invoice_overdue"),
        ):
            org = str(case["tenant"]["servicer"])
            nightly = (
                (
                    "run_advance_checks (whole)" + label,
                    "run_advance_checks",
                    "select private.run_advance_checks(%s, %s, %s, true)",
                    today,
                ),
                (
                    "run_remittance_runs_checks (whole)" + label,
                    "run_remittance_runs_checks",
                    "select private.run_remittance_runs_checks(%s, %s, %s)",
                    today,
                ),
            )
            listed: set[str] = set()
            for name, _fn, sql, day in nightly:
                check = one(
                    conn,
                    "insert into public.payment_check_run (organization_id) values (%s)"
                    " returning id",
                    (org,),
                )
                call(name, sql, check, org, day)
                listed |= {
                    str(r[0])
                    for r in conn.execute(
                        """select code from public.payment_check_result
                           where run_id = %s and subject_id = %s""",
                        (check, case["invoice"]),
                    ).fetchall()
                }
            # each invoice in its one alert: to declare after the liquidation (never dunned),
            # dunned after the death (no opening)
            assert listed == {code}, (label, listed)
            befores.update(_nightly_before_7d3(conn, org, nightly))

    def over(name: str, rows: dict[str, int]) -> dict[str, int]:
        if name in befores:
            return {
                t: n
                for t, n in rows.items()
                if n > befores[name].get(t, 0) + PER_CALL or (t in NEW_PLANTS and n > PER_CALL)
            }
        return {t: n for t, n in rows.items() if n > PER_CALL}

    print(json.dumps({"7d-3": measured, "7d-2 bodies": befores}, indent=1, sort_keys=True))
    overs = {name: over(name, rows) for name, rows in measured.items()}
    assert {k: v for k, v in overs.items() if v} == {}, (measured, befores)


# -- (review round 3) a run's own invoice netted in full whose payout is not debited, then a bar ---


@pytest.fixture(scope="module")
def barred_own() -> dict[str, Any]:
    """Two clients (each its own servicer) whose run sets its own invoice off in full (the netting
    clause), approved, its payout ordered in no file; then a liquidation recorded for the first, a
    death and a seizure for the second (each effective the day before its collection): the
    invoice open in full, with no due date of its own, its payout not debited."""
    out: dict[str, Any] = {}
    for kinds in (("liquidation",), ("death", "seizure")):
        tenant = remittance_tenant()
        d1 = recent_business_day(1)
        paid_file(tenant, 400_000, day=d1)
        run = request_run(tenant)
        approve(tenant, run)
        drain()
        assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
        for kind in kinds:
            _event(tenant, kind, d1 - timedelta(days=1))
        with psycopg.connect(DB) as conn:
            invoice = one(
                conn,
                """select id from public.commission_invoice
                   where run_id = %s and kind = 'invoice' and settlement = 'netted'
                     and due_date is null""",
                (run,),
            )
            status = one(
                conn,
                """select t.status from public.remittance_run r
                   join public.bank_transfer t on t.id = r.transfer_id where r.id = %s""",
                (run,),
            )
            still = one(conn, "select private.document_open(%s)", (invoice,))
        assert status == "ordered", status
        assert still > 0, still
        out[kinds[0]] = {"tenant": tenant, "run": run, "invoice": str(invoice)}
    return out


def test_a_barred_own_invoice_s_reads_stay_keyed_whatever_the_statistics(
    barred_own: dict[str, Any],
) -> None:
    """Under the plants (the first servicer's): the day each bar was recorded
    (private.client_set_off_bar_recorded_on, its three branches), the client in liquidation's
    unpaid post-opening invoices the next day (its own invoice listed), the nightly's advance
    checks whole for its servicer (post_opening_unpaid lists it; a few rows beyond the 7d-2 body's
    own) and the statement build with two ends known on different days (an old « Tutelle ou
    curatelle » row qualified after a death: `earlier`) — never the planted rows."""
    liq, dead = barred_own["liquidation"], barred_own["death"]
    org = str(liq["tenant"]["servicer"])
    measured: dict[str, dict[str, int]] = {}
    befores: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn, org)
        conn.execute("set local plan_cache_mode = force_generic_plan")

        def call(name: str, sql: str, *params: Any) -> Any:
            before = _rows(conn)
            conn.execute("set role postgres")
            value = one(conn, sql, params)
            conn.execute("reset role")
            after = _rows(conn)
            measured[name] = {k: after[k] - before[k] for k in after if after[k] - before[k]}
            return value

        today = paris_today()
        for code, case in (("liquidation", liq), ("mandate_ended", dead), ("seizure", dead)):
            on = call(
                "client_set_off_bar_recorded_on:" + code,
                "select private.client_set_off_bar_recorded_on(%s, %s, %s)",
                str(case["tenant"]["client"]),
                today,
                code,
            )
            assert on == today, (code, on)
        unpaid = call(
            "client_post_opening_unpaid (a barred own invoice)",
            "select array_agg(document_id::text) from private.client_post_opening_unpaid(%s, %s)",
            str(liq["tenant"]["client"]),
            today + timedelta(days=1),
        )
        assert unpaid == [liq["invoice"]], unpaid
        nightly = (
            (
                "run_advance_checks (whole):barred",
                "run_advance_checks",
                "select private.run_advance_checks(%s, %s, %s, true)",
                today + timedelta(days=1),
            ),
        )
        for name, _fn, sql, day in nightly:
            check = one(
                conn,
                "insert into public.payment_check_run (organization_id) values (%s) returning id",
                (org,),
            )
            call(name, sql, check, org, day)
            listed = {
                str(r[0])
                for r in conn.execute(
                    """select code from public.payment_check_result
                       where run_id = %s and subject_id = %s""",
                    (check, liq["invoice"]),
                ).fetchall()
            }
            assert listed == {"post_opening_unpaid"}, listed
        befores.update(_nightly_before_7d3(conn, org, nightly))
        # the statement: an old « Tutelle ou curatelle » row (recorded 40 days ago) and a death (30
        # days ago), the row qualified a tutelle 20 days ago, all before K — the end at K, and the
        # death's before it (a savepoint; the old row and the qualification written as before 7d-1
        # and as the command does, their guards set aside)
        with conn.transaction(force_rollback=True):
            client, admin = str(liq["tenant"]["client"]), str(liq["tenant"]["admin"])
            evidence = _evidence(liq["tenant"], "client_status_evidence")
            guards = (
                ("public.client_status_event", "client_status_event_guard"),
                (
                    "public.client_status_event_qualification",
                    "client_status_event_qualification_guard",
                ),
            )
            for table, guard in guards:
                conn.execute(f"alter table {table} disable trigger {guard}")
            old = one(
                conn,
                """insert into public.client_status_event (organization_id,
                     client_organization_id, kind, effective_date, evidence_document_id,
                     recorded_by, recorded_at, qualified_at)
                   values (%s, %s, 'guardianship', %s, %s, %s, now() - interval '40 days', null)
                   returning id""",
                (org, client, today - timedelta(days=45), evidence, admin),
            )
            conn.execute(
                """insert into public.client_status_event (organization_id,
                     client_organization_id, kind, effective_date, evidence_document_id,
                     recorded_by, recorded_at)
                   values (%s, %s, 'death', %s, %s, %s, now() - interval '30 days')""",
                (org, client, today - timedelta(days=35), evidence, admin),
            )
            conn.execute(
                """insert into public.client_status_event_qualification (event_id,
                     organization_id, client_organization_id, kind, evidence_document_id,
                     recorded_by, recorded_at)
                   values (%s, %s, %s, 'guardianship', %s, %s, now() - interval '20 days')""",
                (old, org, client, evidence, admin),
            )
            for table, guard in guards:
                conn.execute(f"alter table {table} enable always trigger {guard}")
            built = call(
                "remittance_statement_build (two ends)",
                "select private.remittance_statement_build(%s)",
                liq["run"],
            )
            end = built["mandate_end"]
            assert built["schema"] == 2 and end["kind"] == "guardianship", end
            assert [e["kind"] for e in end["earlier"]] == ["death"], end

    def over(name: str, rows: dict[str, int]) -> dict[str, int]:
        if name in befores:
            return {
                t: n
                for t, n in rows.items()
                if n > befores[name].get(t, 0) + PER_CALL or (t in NEW_PLANTS and n > PER_CALL)
            }
        return {t: n for t, n in rows.items() if n > PER_CALL}

    print(json.dumps({"7d-3": measured, "7d-2 bodies": befores}, indent=1, sort_keys=True))
    overs = {name: over(name, rows) for name, rows in measured.items()}
    assert {k: v for k, v in overs.items() if v} == {}, (measured, befores)
