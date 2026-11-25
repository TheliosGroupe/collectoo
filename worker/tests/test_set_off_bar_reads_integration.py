"""M2c-7d-2 (needs `make up`; ADR-0014 « M2c-7d-2 »): the slice's reads by a parameter or a
correlated key stay keyed whatever the statistics — the plan class that broke main after 7a (a key
the last analyse saw with two values, priced at half the table: a sequential scan, a hash of the
whole table, a partial index whose predicate a parameter's filter must imply).

In the test's rolled-back transaction the tables are planted — 7d-1's planted tables (and 7c-1's:
events, settlements, invoices, advances, the servicer's entries …), and PLANTED rows each of: the
lines of two other invoices (remittance_line, its invoice_id at two values), the queue items of
two other servicers, half of them withheld settlements reserved by two drafts (remittance_pending),
(review round 1, CC-2, CC-5) the draft lines and repricings of two other drafts
(remittance_draft_line, remittance_draft_repricing) — each analysed with its keys' n_distinct
pinned (2); every plan generic. Then, on a client whose invoice (born before its redressement) a
run's plan sets off: the bars and the births (client_set_off_barred, client_set_off_bars,
client_opening_date, document_born_on, document_nettable, what the prepare reads:
private.prepare_set_off_facts), the approval's re-check (private.remittance_approval_refusal,
before the event, and — review round 1, TUI-7 — after it: the redressement's path, the draft's own
lines and repricings read, then a standing seizure, read whatever N), the hold before download
(private.transfer_hold_reason), the debit's settlements with the withholding
(private.post_run_settlements), the prepare's held items with the withheld item reserved (its own
branch of HELD_TO_SQL), the run page's withheld set-off (public.remittance_run_withheld, CC-1), the
schedule's candidates with the client a candidate (its run booked: pending_item_deadlines' withheld
branch read, CC-5) and the nightly's set_off_after_bar (private.set_off_after_bar_rows) — and the
rows each read from the planted tables: a few per call, never the planted rows."""

from __future__ import annotations

import json
import uuid
from datetime import date, timedelta
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import DB, one
from remittance_helpers import (
    paid_file,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
)
from test_client_event_reads_integration import _plant as _plant_7d1
from test_client_payment_reads_integration import _as
from test_client_payments_integration import _evidence
from test_set_off_bars_integration import NO_NETTING, _due_invoice, _netting_from_now

from collectoo_worker.jobs.remittances import HELD_TO_SQL

pytestmark = pytest.mark.integration
PLANTED = 10_000
PER_CALL = 60
WATCHED = (
    "public.client_status_event",
    "public.commission_invoice",
    "public.commission_settlement",
    "public.remittance_line",
    "public.remittance_line_repricing",
    "public.client_advance",
    "private.remittance_pending",
    "public.ledger_entry",
    "private.remittance_draft_line",
    "private.remittance_draft_repricing",
)
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"


def _plants() -> tuple[tuple[str, str, dict[str, int]], ...]:
    return (
        (
            # the lines of two other invoices (their runs, entries and clients made up: no foreign
            # key checked while planting)
            f"""insert into public.remittance_line (run_id, line_no, organization_id,
                 client_organization_id, currency, ledger_entry_id, kind, effective_date, posted_at,
                 encaissement_date, amount_minor, commission_state, invoice_id)
               select k.run[1 + g % 2], g, k.org[1 + g % 2], k.client[1 + g % 2], 'EUR',
                      gen_random_uuid(), 'allocation', date '2000-01-01' + g % 300, now(),
                      date '2000-01-01' + g % 300, 100, 'charged', k.inv[1 + g % 2]
               from (select {TWO} run, {TWO} org, {TWO} client, {TWO} inv) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.remittance_line",
            {"invoice_id": 2, "run_id": 2, "client_organization_id": 2},
        ),
        (
            # the queue of two other servicers: half withheld settlements, reserved by two drafts
            f"""insert into private.remittance_pending (ledger_entry_id, organization_id,
                 client_organization_id, currency, kind, amount_minor, posted_at, draft_run_id)
               select gen_random_uuid(), k.org[1 + g % 2], k.client[1 + g % 2], 'EUR',
                      case when g % 2 = 0 then 'settlement_withheld' else 'allocation' end,
                      100, now(), k.run[1 + g % 2]
               from (select {TWO} org, {TWO} client, {TWO} run) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "private.remittance_pending",
            {"draft_run_id": 2, "organization_id": 2, "client_organization_id": 2},
        ),
        (
            # (review round 1, CC-2) the draft lines of two other drafts, invoiced
            f"""insert into private.remittance_draft_line (run_id, line_no, ledger_entry_id, kind,
                 mandate_id, encaissement_date, effective_date, posted_at, amount_minor,
                 commission_state, invoiced)
               select k.run[1 + g % 2], g, gen_random_uuid(), 'allocation', k.mandate[1 + g % 2],
                      date '2000-01-01' + g % 300, date '2000-01-01' + g % 300, now(), 100,
                      'charged', true
               from (select {TWO} run, {TWO} mandate) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "private.remittance_draft_line",
            {"run_id": 2, "mandate_id": 2},
        ),
        (
            # (review round 1, MLAW-1, CC-2) the repricings of two other drafts, invoiced
            f"""insert into private.remittance_draft_repricing (run_id, line_run_id, line_no,
                 ledger_entry_id, commission_minor, commission_state, invoiced)
               select k.run[1 + g % 2], k.line_run[1 + g % 2], g, gen_random_uuid(), 15, 'charged',
                      true
               from (select {TWO} run, {TWO} line_run) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "private.remittance_draft_repricing",
            {"run_id": 2, "line_run_id": 2},
        ),
    )


def _plant(conn: psycopg.Connection[Any], org: str) -> None:
    _plant_7d1(conn, org)
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


def _raw(conn: psycopg.Connection[Any], table: str, sql: str, params: tuple[Any, ...]) -> None:
    """(test only) a row of the run's state moved by hand, its guards set aside, rolled back with
    the test: what a later job (the next draft's reservation, the debit's booking) would leave."""
    conn.execute("set local session_replication_role = replica")
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
    conn.execute(sql, params)
    for t in always:
        conn.execute(f"alter table {table} enable always trigger {t}")
    conn.execute("set local session_replication_role = origin")


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


@pytest.fixture(scope="module")
def barred() -> dict[str, Any]:
    """A client owing FC-1 (born d - 8); the netting clause on; a run prepared that sets FC-1 off;
    the evidence of an event to record."""
    tenant = remittance_tenant(terms=NO_NETTING)
    d1 = recent_business_day(8)
    fc1 = _due_invoice(tenant, d1)
    _netting_from_now(tenant)
    paid_file(tenant, 400_000, day=recent_business_day(1))
    run = request_run(tenant)
    assert any(s["ref"] == fc1 for s in _plan(run)["settles"]), _plan(run)
    return {
        "tenant": tenant,
        "fc1": fc1,
        "run": run,
        "opening": d1 + timedelta(days=1),
        "evidence": _evidence(tenant, "client_status_evidence"),
    }


def _plan(run: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        return dict(
            one(conn, "select plan from private.remittance_draft where run_id = %s", (run,))
        )


def test_the_set_off_bar_reads_stay_keyed_whatever_the_statistics(  # noqa: PLR0915
    barred: dict[str, Any],
) -> None:
    tenant = barred["tenant"]
    org, client, ops = str(tenant["servicer"]), str(tenant["client"]), str(tenant["staff"])
    run, fc1 = barred["run"], barred["fc1"]
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

        refusal = """select private.remittance_approval_refusal(r, d, private.paris_today())
                     from public.remittance_run r join private.remittance_draft d on d.run_id = r.id
                     where r.id = %s"""
        # approved (the command, which sets the requested execution date, then the job's
        # transaction; its re-check measured alone first)
        draft = run_row(run)
        queued = call(
            "approve_remittance_runs",
            ops,
            "select public.approve_remittance_runs(%s, %s::jsonb)",
            str(uuid.uuid4()),
            json.dumps(
                [
                    {
                        "run_id": run,
                        "inputs_hash": draft["inputs_hash"],
                        "net_text": str(draft["net_minor"]),
                    }
                ]
            ),
        )
        assert [x["status"] for x in queued["results"]] == ["queued"], queued
        assert call("remittance_approval_refusal (no event)", None, refusal, run) is None
        # (review round 1, TUI-7) the same re-check after an event, in a savepoint (the run is
        # approved below with no event): the redressement — the opening and the bars differ from the
        # draft's, the plan's set-offs read (the draft's own lines and repricings by its key) — then
        # a standing seizure, read whatever N
        with conn.transaction(force_rollback=True):
            today0 = one(conn, "select private.paris_today()")
            for kind, day in (("proceeding_opened", barred["opening"]), ("seizure", today0)):
                conn.execute(
                    """insert into public.client_status_event (organization_id,
                         client_organization_id, kind, effective_date, evidence_document_id,
                         recorded_by)
                       values (%s, %s, %s, %s, %s, %s)""",
                    (org, client, kind, day, barred["evidence"], tenant["admin"]),
                )
                expected = (
                    "client_status_changed"
                    if kind == "proceeding_opened"
                    else "payout_blocked:client_status:seizure"
                )
                name = f"remittance_approval_refusal ({kind})"
                assert call(name, None, refusal, run) == expected
        token = one(conn, "select job_token from public.remittance_run where id = %s", (run,))
        call(
            "approve_remittance_run",
            None,
            "select private.approve_remittance_run(%s, %s)",
            run,
            token,
        )
        assert (
            one(conn, "select status from public.remittance_run where id = %s", (run,))
            == "approved"
        )
        # the redressement recorded after the approval
        conn.execute(
            """insert into public.client_status_event (organization_id, client_organization_id,
                 kind, effective_date, evidence_document_id, recorded_by)
               values (%s, %s, 'proceeding_opened', %s, %s, %s)""",
            (org, client, barred["opening"], barred["evidence"], tenant["admin"]),
        )
        today = one(conn, "select private.paris_today()")
        assert (
            call(
                "client_set_off_barred",
                None,
                "select private.client_set_off_barred(%s, %s, 'advance')",
                client,
                today,
            )
            == "proceeding"
        )
        assert (
            call(
                "client_set_off_bars",
                None,
                "select private.client_set_off_bars(%s, %s)",
                client,
                today,
            )
            == "-/proceeding"
        )
        assert (
            call(
                "client_opening_date",
                None,
                "select private.client_opening_date(%s, %s)",
                client,
                today,
            )
            == barred["opening"]
        )
        born = call("document_born_on", None, "select private.document_born_on(%s)", fc1)
        assert isinstance(born, date) and born < barred["opening"]
        assert (
            call("document_nettable", None, "select private.document_nettable(%s, %s)", fc1, today)
            is False
        )
        facts = call(
            "prepare_set_off_facts",
            None,
            "select row_to_json(f) from private.prepare_set_off_facts(%s, %s) f",
            client,
            today,
        )
        assert facts["opening_on"] == barred["opening"].isoformat(), facts
        # the prepare's held items (jobs/remittances.py HELD_TO_SQL, its third branch the withheld
        # settlements'): a server-side prepared statement, generic, on the planted queue
        before = _rows(conn)
        conn.execute("set role postgres")
        conn.execute(HELD_TO_SQL, (run,), prepare=True).fetchall()
        conn.execute("reset role")
        after = _rows(conn)
        measured["HELD_TO_SQL (the prepare's held items)"] = {
            k: after[k] - before[k] for k in after if after[k] - before[k]
        }
        transfer = one(conn, "select transfer_id from public.remittance_run where id = %s", (run,))
        assert (
            call(
                "transfer_hold_reason",
                None,
                "select private.transfer_hold_reason(%s, %s, %s, null)",
                transfer,
                today,
                today,
            )
            == "client_status_changed"
        )
        call(
            "post_run_settlements (the withholding)",
            None,
            """select count(*)
               from private.post_run_settlements(array[%s]::uuid[], array[%s]::date[])""",
            run,
            today,
        )
        assert (
            one(
                conn,
                "select count(*) from public.ledger_entry where idempotency_key in (%s, %s)",
                (f"settle:{run}:barred", f"return:barred:{run}"),
            )
            == 2
        )
        # the commit checks now (the barred settlement's reversal by ledger_entry_reversed_once_uq)
        call("ledger_check_now (the commit check)", None, "select private.ledger_check_now()")
        # (review round 1, CC-1) the run page's withheld set-off, as ops read it
        shown = call(
            "remittance_run_withheld",
            ops,
            "select public.remittance_run_withheld(%s)",
            run,
        )
        assert shown is not None and shown["withheld_minor"] != "0", shown
        # (review round 1, CC-5) the withheld item reserved by a draft: HELD_TO_SQL's own branch
        withheld = one(
            conn,
            "select id from public.ledger_entry where idempotency_key = %s",
            (f"return:barred:{run}",),
        )
        _raw(
            conn,
            "private.remittance_pending",
            "update private.remittance_pending set draft_run_id = %s where ledger_entry_id = %s",
            (run, withheld),
        )
        before = _rows(conn)
        conn.execute("set role postgres")
        held = conn.execute(HELD_TO_SQL, (run,), prepare=True).fetchall()
        conn.execute("reset role")
        after = _rows(conn)
        measured["HELD_TO_SQL (the withheld item reserved)"] = {
            k: after[k] - before[k] for k in after if after[k] - before[k]
        }
        assert [str(r[0]) for r in held] == [str(withheld)], held
        _raw(
            conn,
            "private.remittance_pending",
            "update private.remittance_pending set draft_run_id = null where ledger_entry_id = %s",
            (withheld,),
        )
        # (CC-5) the client's run booked: the client a candidate, its withheld item's deadline read
        # (pending_item_deadlines' settlement_withheld branch, the withheld run's lines by its key)
        _raw(
            conn,
            "public.remittance_run",
            """update public.remittance_run set status = 'booked', booked_on = private.paris_today()
               where id = %s""",
            (run,),
        )
        assert (
            call(
                "remittance_schedule_candidates",
                None,
                """select count(*) from private.remittance_schedule_candidates(%s, %s) x
                       where x.settlement_withheld and x.client_organization_id = %s""",
                org,
                today,
                client,
            )
            == 1
        )
        call(
            "set_off_after_bar_rows",
            None,
            "select count(*) from private.set_off_after_bar_rows(%s, %s)",
            org,
            today,
        )

    over = {
        name: {t: n for t, n in rows.items() if n > PER_CALL} for name, rows in measured.items()
    }
    print(json.dumps(measured, indent=1, sort_keys=True))
    assert {k: v for k, v in over.items() if v} == {}, measured
