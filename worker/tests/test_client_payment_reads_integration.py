"""M2c-7c-1 (needs `make up`; ADR-0014 « M2c-7c-1 »): the slice's reads by a parameter or a
correlated key stay keyed whatever the statistics — the plan class that broke main after 7a (a probe
of a key the last analyse saw with two values, priced at half the table, read as a sequential scan,
a hash of the whole table or another index read whole) and 7b round 2's (a servicer's index priced
at one row while it holds every advance).

In each test's rolled-back transaction every table 7c-1's statements read by such a key is planted:
PLANTED rows each, over two values of each key and, where a statement also filters on the servicer,
of the tenant's own servicer for other clients (no trigger, no foreign key: they name nothing of
ours), each analysed with those columns' n_distinct pinned (2; the servicer's -1, as 7b round 2's
client space); every plan generic (plan_cache_mode). Then, on a client owing one invoice, each read
and command of the slice as its caller runs it — « Ce que le client doit au cabinet » and the
preview, « Règlement du client » (a surplus: a credit owed back), the client space's credits and
the client's page with that credit (review round 3: each credit's receipt date, its payment's entry
read by its primary key — ledger_entry planted with the servicer's own entries), the credit's
refund, a credit line of the dedicated account read and booked, the night's advance checks — and
the rows it read from the planted tables (sequential reads and index entries returned), a few per
document, never the planted rows."""

from __future__ import annotations

import json
import uuid
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import one
from remittance_helpers import own_account, remittance_tenant
from test_client_payments_integration import (
    NO_NETTING,
    REASON,
    _client_credit_line,
    _evidence,
    _invoice_due,
)

pytestmark = pytest.mark.integration
PLANTED = 10_000
PER_DOCUMENT = 12
SLACK = 60
WATCHED = (
    "public.commission_settlement",
    "public.commission_invoice",
    "public.client_advance",
    "public.client_credit",
    "public.advance_write_off_recovery",
    "public.client_payout_account",
    "public.client_status_event",
    "public.ledger_entry",
)
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"


def _plants(org: str) -> tuple[tuple[str, str, tuple[str, ...], dict[str, int]], ...]:
    """Each planted table: its rows, the triggers that fire always (off while planting), the keys'
    n_distinct."""
    return (
        (
            f"""insert into public.commission_settlement (organization_id, client_organization_id,
                 document_kind, document_id, kind, amount_minor, settled_on)
               select k.org[1 + g % 2], k.client[1 + g % 2], 'invoice', k.doc[1 + g % 2],
                      'compensation', 1, private.paris_today()
               from (select {TWO} org, {TWO} client, {TWO} doc) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.commission_settlement",
            ("commission_settlement_advance_guard",),
            {"document_id": 2, "client_organization_id": 2},
        ),
        (
            f"""insert into public.commission_invoice (id, organization_id, client_organization_id,
                 mandate_id, kind, series, year, seq, number, issue_date, currency, ht_minor,
                 vat_rate, vat_minor, ttc_minor, vat_book, settlement, due_date, reason, payload,
                 payload_sha256, ledger_entry_id)
               select gen_random_uuid(), '{org}', k.client[1 + g % 2], gen_random_uuid(), 'invoice',
                      'ZZ', 2026, g, 'ZZ-2026-' || lpad(g::text, 6, '0'), date '2026-01-01', 'EUR',
                      100, 0.2, 20, 120, 'vat_pending', 'due', date '2026-02-01', 'commission',
                      '{{}}',
                      repeat('0', 64), gen_random_uuid()
               from (select {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.commission_invoice",
            ("commission_invoice_guard",),
            {"client_organization_id": 2, "organization_id": -1},
        ),
        (
            f"""insert into public.client_advance (organization_id, client_organization_id,
                 currency,
                 amount_minor, cause, cause_entry_id, entry_id)
               select '{org}', k.client[1 + g % 2], 'EUR', 100, 'double_payout', gen_random_uuid(),
                      gen_random_uuid()
               from (select {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.client_advance",
            ("client_advance_guard",),
            {"client_organization_id": 2, "organization_id": -1},
        ),
        (
            f"""insert into public.client_credit (organization_id, client_organization_id, currency,
                 cause, amount_minor, entry_id)
               select '{org}', k.client[1 + g % 2], 'EUR', 'overpayment', 100, gen_random_uuid()
               from (select {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.client_credit",
            ("client_credit_guard",),
            {"client_organization_id": 2, "organization_id": -1},
        ),
        (
            f"""insert into public.advance_write_off_recovery (advance_id, entry_id,
                 organization_id,
                 client_organization_id, currency, amount_minor)
               select k.adv[1 + g % 2], gen_random_uuid(), '{org}', k.client[1 + g % 2], 'EUR', 1
               from (select {TWO} adv, {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.advance_write_off_recovery",
            ("advance_write_off_recovery_guard",),
            {"advance_id": 2, "organization_id": -1},
        ),
        (
            f"""insert into public.client_payout_account (organization_id, client_organization_id,
                 currency, iban, holder_name, evidence_document_id, proposed_by, status,
                 confirmed_by, confirmed_at, confirmed_via, closed_by, closed_at, closed_reason)
               select '{org}', k.client[1 + g % 2], 'EUR',
                      (array['FR7630006000011234567890189',
                      'FR7688685684899121950048661'])[1 + g % 2],
                      'PLANTED', gen_random_uuid(), gen_random_uuid(), 'retired', gen_random_uuid(),
                      now(), 'second_admin', gen_random_uuid(), now(), 'Planted'
               from (select {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.client_payout_account",
            ("client_payout_account_guard",),
            {"iban": 2, "organization_id": -1},
        ),
        (
            f"""insert into public.client_status_event (organization_id, client_organization_id,
                 kind,
                 effective_date, evidence_document_id, note, recorded_by)
               select k.org[1 + g % 2], k.client[1 + g % 2],
                      case when g % 4 < 2 then 'proceeding_opened' else 'liquidation' end,
                      date '2000-01-01' + g, gen_random_uuid(), 'Planted', gen_random_uuid()
               from (select {TWO} org, {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.client_status_event",
            ("client_status_event_guard",),
            {"client_organization_id": 2},
        ),
        # (review round 3) a credit's date is its payment's entry's (received_on): the servicer's
        # own entries for two other clients, so that a read of a credit's entry by anything but
        # its primary key reads them
        (
            f"""insert into public.ledger_entry (organization_id, client_organization_id,
                 entry_type, effective_date, line_count, idempotency_key, request_hash,
                 source_type, source_id)
               select '{org}', k.client[1 + g % 2], 'client_payment_own',
                      date '2000-01-01' + g, 2, 'planted-045-' || g, repeat('0', 64), 'document',
                      gen_random_uuid()::text
               from (select {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.ledger_entry",
            (
                "ledger_entry_append_only",
                "ledger_entry_guard",
                "ledger_entry_balanced",
                "ledger_entry_receipts",
                "ledger_entry_remitted_cover",
            ),
            {"client_organization_id": 2, "organization_id": -1},
        ),
    )


def _plant(conn: psycopg.Connection[Any], org: str) -> None:
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


def _as(conn: psycopg.Connection[Any], user: str) -> None:
    claims = json.dumps({"sub": user, "role": "authenticated", "aal": "aal2"})
    conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
    conn.execute("set local role authenticated")
    conn.execute("set local statement_timeout = '8s'")


@pytest.fixture(scope="module")
def owing() -> dict[str, Any]:
    """A client owing one invoice (36 000 TTC), the own account, the evidence, and a credit of the
    client on the dedicated account waiting in « Débits et retours »."""
    tenant = remittance_tenant(terms=NO_NETTING)
    invoice = _invoice_due(tenant)
    own_account(tenant)
    return {
        "tenant": tenant,
        "invoice": invoice,
        "evidence": _evidence(tenant, "client_payment_evidence"),
        "refund_evidence": _evidence(tenant, "client_refund_evidence"),
        "line": _client_credit_line(tenant, 1_000, "Virement"),
    }


def test_the_client_payment_reads_stay_keyed_whatever_the_statistics(owing: dict[str, Any]) -> None:
    tenant = owing["tenant"]
    org, client, ops = str(tenant["servicer"]), str(tenant["client"]), str(tenant["staff"])
    measured: dict[str, dict[str, int]] = {}
    bounds: dict[str, int] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn, org)
        conn.execute("set local plan_cache_mode = force_generic_plan")

        def call(name: str, documents: int, user: str | None, sql: str, *params: Any) -> Any:
            before = _rows(conn)
            if user is None:
                conn.execute("set role postgres")
            else:
                _as(conn, user)
            value = one(conn, sql, params)
            conn.execute("reset role")
            after = _rows(conn)
            measured[name] = {k: after[k] - before[k] for k in after if after[k] - before[k]}
            bounds[name] = PER_DOCUMENT * documents + SLACK
            return value

        docs = call(
            "client_open_documents",
            1,
            ops,
            "select public.client_open_documents(%s, 'EUR')",
            client,
        )
        assert [d["id"] for d in docs["invoices"]] == [owing["invoice"]], docs
        call(
            "client_payment_preview",
            1,
            ops,
            "select public.client_payment_preview(%s, 'EUR', '365,00', null, null)",
            client,
        )
        paid = call(
            "record_client_payment",
            1,
            ops,
            """select public.record_client_payment(%s, %s, 'EUR', '365,00', private.paris_today(),
                                                   %s, null, null, null, '36000', %s)""",
            str(uuid.uuid4()),
            client,
            owing["evidence"],
            REASON,
        )
        assert paid["credit_minor"] == "500", paid
        credit = one(
            conn, "select id from public.client_credit where entry_id = %s", (paid["entry_id"],)
        )
        paid_on = str(one(conn, "select private.paris_today()::text", ()))
        # (review round 3) the credit as both pages read it: its payment's entry by its primary key
        # (received_on)
        space = call("client_space_credits", 1, ops, "select public.client_space_credits(%s)",
                     client)  # fmt: skip
        assert [r["received_on"] for r in space["rows"]] == [paid_on], space
        owes = call("client_open_documents (a credit)", 1, ops,
                    "select public.client_open_documents(%s, 'EUR')", client)  # fmt: skip
        assert [c["received_on"] for c in owes["credits"]] == [paid_on], owes
        call(
            "record_client_refund",
            1,
            ops,
            """select public.record_client_refund(%s, %s, '5,00', private.paris_today(), %s, '500',
                                                  %s)""",
            str(uuid.uuid4()),
            credit,
            owing["refund_evidence"],
            REASON,
        )
        line = call(
            "client_payment_line",
            1,
            ops,
            "select public.client_payment_line(%s, null, null)",
            owing["line"],
        )
        assert (line["client_id"], line["refusal"]) == (str(client), None), line
        call(
            "book_client_payment_line",
            1,
            ops,
            "select public.book_client_payment_line(%s, %s, null, null, null, '0', %s)",
            str(uuid.uuid4()),
            owing["line"],
            REASON,
        )
        # the night (earlier slices' checks read the servicer's planted invoices and advances by
        # design: printed, not bounded), then its advance checks' full pass: 7c-1's identities read
        # each of the servicer's credits and recoveries once (the planted ones are its own), never
        # once per row, and their per-row probes by key
        night = call(
            "run_payment_checks (the night)", 3, None, "select private.run_payment_checks(%s)", org
        )
        assert night["run_id"]
        check = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (org,),
        )
        call(
            "run_advance_checks (full)",
            3,
            None,
            "select private.run_advance_checks(%s, %s, null, true)",
            check,
            org,
        )
    # the servicer's own rows each statement of the full pass reads once, never once per row: its
    # credits by client_credit_owed and client_credit_ledger, its recoveries by
    # written_off_recovery_ledger, its advances by 7b's advance_ledger and advance_open — two
    # statements at most per table
    once = {"client_credit", "advance_write_off_recovery", "client_advance"}

    def over(name: str, rows: dict[str, int]) -> bool:
        if name.startswith("run_payment_checks"):
            return False
        if name.startswith("run_advance_checks"):
            return any(
                v > (2 * PLANTED + SLACK if k in once else bounds[name]) for k, v in rows.items()
            )
        return sum(rows.values()) > bounds[name]

    lines = [f"{n}: {r} (bound {bounds[n]})" for n, r in measured.items()]
    print(
        f"\n{PLANTED} rows planted per table (two values of each key, the servicer's own rows for"
        " other clients), generic plans — rows read from the planted tables:\n  "
        + "\n  ".join(lines)
    )
    assert {n: r for n, r in measured.items() if over(n, r)} == {}
