"""M2c-7c-2 (needs `make up`; ADR-0014 « M2c-7c-2 »): the slice's reads by a parameter or a
correlated key stay keyed whatever the statistics — the plan class that broke main after 7a (a key
the last analyse saw with two values, priced at half the table: a sequential scan, a hash of the
whole table, another index read whole) and 7b round 2's (a servicer's index priced at one row while
it holds every row).

In the test's rolled-back transaction the request tables are planted (PLANTED rows each, over two
values of each key; the requests the servicer's own, for other clients, their letters drawn; no
trigger, no foreign key), with 7c-1's planted tables (test_client_payment_reads_integration:
settlements, invoices, advances, credits, recoveries, payout accounts, status events, entries), each
analysed with its keys' n_distinct pinned (2; the servicer's -1); every plan generic. Then, on
design §7.2's Martin with the claw-back clause (A1 open, RV-3's draft taking it back): the
approval's re-check of that draft (the advance requested? one keyed probe per planned advance),
the sheet's preview, the request, « Avances » and the client's requests (staff), the prepare's read
of the requested advances, the withdrawal, the letter's job rows, the night's advance checks
(advance_open's requested_on per alert, repayment_request_document_missing) — and the rows each
read from the planted tables: a few per advance, never the planted rows. (Review round 1, CC-3)
The queue of other drafts planted too: the approval's re-check counts its run's items by the run's
key, never the whole queue; and a dedicated-account line whose label names the request's number
(read and booked: the requests by their number, never the servicer's planted ones)."""

from __future__ import annotations

import json
import uuid
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import one
from remittance_helpers import TERMS, request_run, run_row
from test_client_payment_reads_integration import _as
from test_client_payment_reads_integration import _plant as _plant_7c1
from test_client_payments_integration import _client_credit_line
from test_repayment_requests_integration import _worked_example

pytestmark = pytest.mark.integration
PLANTED = 10_000
PER_ADVANCE = 12
SLACK = 60
WATCHED = (
    "public.advance_repayment_request",
    "public.advance_repayment_request_item",
    "public.client_advance",
    "public.commission_settlement",
    "public.ledger_entry",
    "private.remittance_pending",
)
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"


def _plants(org: str) -> tuple[tuple[str, str, tuple[str, ...], dict[str, int]], ...]:
    return (
        (
            f"""insert into public.advance_repayment_request (organization_id,
                 client_organization_id, currency, number, issue_date, total_minor, payload,
                 payload_sha256, template_version, renderer_version, document_id, pdf_sha256,
                 issued_by)
               select '{org}', k.client[1 + g % 2], 'EUR', 'DRA-2000-' || lpad(g::text, 6, '0'),
                      date '2000-01-01' + g % 300, 100, '{{}}', repeat('0', 64),
                      'demande-remboursement-avance-fr-1', 'planted', gen_random_uuid(),
                      repeat('0', 64), gen_random_uuid()
               from (select {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.advance_repayment_request",
            ("advance_repayment_request_guard",),
            {"client_organization_id": 2, "organization_id": -1},
        ),
        (
            f"""insert into public.advance_repayment_request_item (request_id, advance_id,
                 organization_id, client_organization_id, open_minor)
               select k.req[1 + g % 2], gen_random_uuid(), '{org}', k.client[1 + g % 2], 100
               from (select {TWO} req, {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.advance_repayment_request_item",
            ("advance_repayment_request_item_append_only",),
            {"request_id": 2, "organization_id": -1},
        ),
        (
            f"""insert into public.advance_repayment_request_item (request_id, advance_id,
                 organization_id, client_organization_id, open_minor)
               select gen_random_uuid(), k.adv[1 + g % 2], '{org}', k.client[1 + g % 2], 100
               from (select {TWO} adv, {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.advance_repayment_request_item",
            ("advance_repayment_request_item_append_only",),
            {"advance_id": 2},
        ),
        # (review round 1, CC-3) the queue of other drafts: the approval's re-check counts its run's
        # items by the run's key (remittance_pending_run_idx), never the whole queue
        (
            f"""insert into private.remittance_pending (ledger_entry_id, organization_id,
                 client_organization_id, currency, kind, amount_minor, posted_at, draft_run_id)
               select gen_random_uuid(), '{org}', k.client[1 + g % 2], 'EUR', 'allocation', 1,
                      now(), k.run[1 + g % 2]
               from (select {TWO} client, {TWO} run) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "private.remittance_pending",
            (),
            {"draft_run_id": 2},
        ),
    )


def _plant(conn: psycopg.Connection[Any], org: str) -> None:
    _plant_7c1(conn, org)
    conn.execute("set local session_replication_role = replica")
    for sql, table, triggers, _keys in _plants(org):
        for t in triggers:
            conn.execute(f"alter table {table} disable trigger {t}")
        conn.execute(sql)
        for t in triggers:
            conn.execute(f"alter table {table} enable always trigger {t}")
    conn.execute("set local session_replication_role = origin")
    for _sql, table, _triggers, keys in _plants(org):
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


@pytest.fixture(scope="module")
def martin() -> dict[str, Any]:
    """§7.2's Martin with the claw-back clause: A1 open (200 000), RV-3's draft taking it back;
    (review round 1, MONEY-2) Martin's credit of 200 000 on the dedicated account, waiting in
    « Débits et retours » (its label set to the request's number in the test's transaction)."""
    tenant, a1 = _worked_example({**TERMS, "clawback": {"clause_ref": "art. 7.4"}})
    rv3 = request_run(tenant)
    assert run_row(rv3)["advance_recovered_minor"] == 200_000
    line = _client_credit_line(tenant, 200_000, "Remboursement")
    return {"tenant": tenant, "a1": a1, "rv3": rv3, "line": line}


def test_the_repayment_request_reads_stay_keyed_whatever_the_statistics(  # noqa: PLR0915
    martin: dict[str, Any],
) -> None:
    tenant = martin["tenant"]
    org, client, ops = str(tenant["servicer"]), str(tenant["client"]), str(tenant["staff"])
    a1, rv3 = martin["a1"], martin["rv3"]
    measured: dict[str, dict[str, int]] = {}
    bounds: dict[str, int] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn, org)
        conn.execute("set local plan_cache_mode = force_generic_plan")

        def call(name: str, advances: int, user: str | None, sql: str, *params: Any) -> Any:
            before = _rows(conn)
            if user is None:
                conn.execute("set role postgres")
            else:
                _as(conn, user)
            value = one(conn, sql, params)
            conn.execute("reset role")
            after = _rows(conn)
            measured[name] = {k: after[k] - before[k] for k in after if after[k] - before[k]}
            bounds[name] = PER_ADVANCE * advances + SLACK
            return value

        preview = call(
            "advance_repayment_preview",
            1,
            ops,
            "select public.advance_repayment_preview(%s, 'EUR', array[%s]::uuid[])",
            client,
            a1,
        )
        # in flight? no: RV-3 is a draft — but a request now would make the draft's plan stale
        assert preview["total_minor"] == "200000", preview
        # the clause applies: a request is refused clawback_applies (the per-advance checks read)
        refused = call(
            "advance_repayment_preview (clawback_applies)",
            1,
            ops,
            """select public.advance_repayment_preview(%s, 'EUR', array[%s]::uuid[])""",
            client,
            a1,
        )
        assert refused["rows"][0]["refusal"] == "clawback_applies", refused
        # without the clause (the terms of today): requested
        conn.execute("alter table public.mandate_terms disable trigger mandate_terms_guard")
        conn.execute(
            """update public.mandate_terms
                  set remittance_terms = jsonb_set(remittance_terms, '{clawback}', 'null')
               where mandate_id = %s""",
            (tenant["mandate"],),
        )
        conn.execute("alter table public.mandate_terms enable always trigger mandate_terms_guard")
        made = call(
            "request_advance_repayment",
            1,
            ops,
            "select public.request_advance_repayment(%s, %s, 'EUR', array[%s]::uuid[], '200000')",
            str(uuid.uuid4()),
            client,
            a1,
        )
        request = str(made["request_id"])
        rows = call(
            "client_advances",
            1,
            ops,
            "select public.client_advances(%s, %s)",
            org,
            client,
        )
        assert [r["request"]["number"] for r in rows["rows"]] == [made["number"]], rows
        listed = call(
            "client_repayment_requests",
            1,
            ops,
            "select public.client_repayment_requests(%s)",
            client,
        )
        assert [r["number"] for r in listed["rows"]] == [made["number"]], listed
        prepared = call(
            "client_requested_advances (the prepare)",
            1,
            None,
            """select coalesce(jsonb_agg(x.advance_id), '[]')
               from private.client_requested_advances(%s, 'EUR') x""",
            client,
        )
        assert prepared == [a1], prepared
        # the approval of RV-3's draft (it plans A1's settle, A1 requested since): « Valider »
        # then the approval job — its re-check refuses documents_changed; its other reads are
        # earlier slices' (bounded on 7c-2's tables only, below)
        draft = one(
            conn, "select row_to_json(r) from public.remittance_run r where r.id = %s", (rv3,)
        )
        queued = call(
            "approve_remittance_runs",
            1,
            ops,
            "select public.approve_remittance_runs(%s, %s::jsonb)",
            str(uuid.uuid4()),
            json.dumps(
                [
                    {
                        "run_id": rv3,
                        "inputs_hash": draft["inputs_hash"],
                        "net_text": str(draft["net_minor"]),
                    }
                ]
            ),
        )
        assert [x["status"] for x in queued["results"]] == ["queued"], queued
        token = one(conn, "select job_token from public.remittance_run where id = %s", (rv3,))
        call(
            "approve_remittance_run (the re-check)",
            1,
            None,
            "select private.approve_remittance_run(%s, %s)",
            rv3,
            token,
        )
        failure = one(
            conn, "select last_failure ->> 'code' from public.remittance_run where id = %s", (rv3,)
        )
        assert failure == "documents_changed", failure
        job = call(
            "repayment_request_job",
            1,
            None,
            "select private.repayment_request_job(%s)",
            request,
        )
        assert job["number"] == made["number"], job
        night = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (org,),
        )
        call(
            "run_advance_checks (full, d + 31)",
            1,
            None,
            "select private.run_advance_checks(%s, %s, private.paris_today() + 31, true)",
            night,
            org,
        )
        requested_on = one(
            conn,
            """select details ->> 'requested_on' from public.payment_check_result
               where run_id = %s and code = 'advance_open' and subject_id = %s""",
            (night, a1),
        )
        assert requested_on is not None
        call(
            "withdraw_advance_repayment_request",
            1,
            ops,
            "select public.withdraw_advance_repayment_request(%s, %s, %s)",
            str(uuid.uuid4()),
            request,
            "Le client conteste la somme (test)",
        )
        # (review round 1, MONEY-2) Martin's dedicated-account line labelled with the request's
        # number designates A1: the requests by their number, their items and advances by key
        conn.execute(
            "alter table public.bank_transaction disable trigger bank_transaction_append_only"
        )
        conn.execute(
            "update public.bank_transaction set remittance_text = %s where id = %s",
            (f"REMBOURSEMENT {made['number']}", martin["line"]),
        )
        conn.execute(
            "alter table public.bank_transaction enable always trigger bank_transaction_append_only"
        )
        shown = call(
            "client_payment_line (its label names the DRA)",
            1,
            ops,
            "select public.client_payment_line(%s, %s::uuid[], null)",
            martin["line"],
            [a1],
        )
        assert shown["named_documents"] == [a1], shown
        booked = call(
            "book_client_payment_line (its label names the DRA)",
            1,
            ops,
            """select public.book_client_payment_line(%s, %s, %s::uuid[], null, null, %s,
                                                     'Règlement de la demande (test)')""",
            str(uuid.uuid4()),
            martin["line"],
            [a1],
            shown["preview"]["open_minor"],
        )
        assert [(x["document_kind"], x["amount_minor"]) for x in booked["settled"]] == [
            ("advance", "200000")
        ], booked
    # 7c-2's own tables: a few rows per advance in every call. The calls of 7c-2's new functions:
    # every planted table so, and « Avances » too (public.client_advances: since 7f-1's H16 its
    # totals are the 4112[c] balances — 7f-1 review round 1, TEST-H16-CLIENT-ADVANCES; before, the
    # servicer's advances one by one, ADR-0014 7b « Left open »). The others — the approval (its
    # earlier slices' reads), the night (its statements read each of the servicer's advances once by
    # design: 7b's advance_ledger, advance_open with its per-advance birth, 7a's full pass — four
    # reads at d + 31, where every planted advance is more than 30 days old) — are bounded on
    # 7c-2's tables, the night's advances at one read per statement
    seven_c_two = {"advance_repayment_request", "advance_repayment_request_item"}
    earlier = ("approve_remittance_run", "run_advance_checks")

    def over(name: str, rows: dict[str, int]) -> bool:
        if sum(v for k, v in rows.items() if k in seven_c_two) > bounds[name]:
            return True
        # (review round 1, CC-3) the approval's re-check reads its run's items, not the queue
        if name.startswith("approve_remittance_run") and (
            rows.get("private.remittance_pending", 0) > bounds[name]
        ):
            return True
        if name.startswith("run_advance_checks"):
            return rows.get("client_advance", 0) > 4 * PLANTED + SLACK
        if name.startswith(earlier):
            return False
        return sum(rows.values()) > bounds[name]

    lines = [f"{n}: {r} (bound {bounds[n]})" for n, r in measured.items()]
    print(
        f"\n{PLANTED} rows planted per table (two values of each key, the servicer's own rows for"
        " other clients), generic plans — rows read from the planted tables:\n  "
        + "\n  ".join(lines)
    )
    assert {n: r for n, r in measured.items() if over(n, r)} == {}
