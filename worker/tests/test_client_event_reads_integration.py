"""M2c-7d-1 (needs `make up`; ADR-0014 « M2c-7d-1 »): the slice's reads by a parameter or a
correlated key stay keyed whatever the statistics — the plan class that broke main after 7a (a key
the last analyse saw with two values, priced at half the table: a sequential scan, a hash of the
whole table, another index read whole) and 7b round 2's (a servicer's index priced at one row while
it holds every row).

In the test's rolled-back transaction the event tables are planted — 7c-1's planted tables
(test_client_payment_reads_integration: events, payout accounts, …), and PLANTED rows each of: the
other servicers' standing seizures and old « Tutelle ou curatelle » rows (qualified_at null), their
releases, representatives over two events, qualifications, declared items over two events (no
trigger, no foreign key), each analysed with its keys' n_distinct pinned (2); every plan generic.
Then, on a client whose death is recorded with its notary and whose notary's account was confirmed
by a second admin (a run prepared, a payment received after the death held for ops): the blockers
as the approval and the file's generation read them (private.remittance_payout_blockers, the
approval job's re-check, private.transfer_hold_reason), the gate (a regate of the held payment's
file: private.gate_assignments; the allocation job's own, `load_files`), « Reverser au client »,
the night's advance checks (protection_event_to_qualify, seizure_standing), the event commands (a
seizure, its release, a representative, a qualification), the payee commands (a proposal, its
confirmation), who receives the letters (private.client_addressee) and the client's events page —
and the rows each read from the planted tables: a few per call, never the planted rows. (The
seizures of a client read whole the servicer's partial index until
client_status_event_client_seizure_idx: 5,008 planted rows per blocker check.)

(Review round 1) The servicer's repayment requests planted too (their letters drawn, addressed to
a notary): the remittance documents' rule on a letter (private.can_read_remittance_document, as
the client's member and as staff: the request by its document's key), the client's requests (as
its member: the letters addressed to the person who acts for it withheld) and the portfolio
confirmation gate (private.portfolio_confirmation_blockers: the client's events, each one's
qualification by its key)."""

from __future__ import annotations

import json
import uuid
from datetime import timedelta
from typing import Any

import psycopg
import pytest
from allocation_helpers import state
from explain_helpers import ADMIN
from integration_helpers import DB, one
from remittance_helpers import (
    add_admin,
    paid_file,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
)
from test_client_events_integration import NOTARY, _event
from test_client_payment_reads_integration import _as
from test_client_payment_reads_integration import _plant as _plant_7c1
from test_client_payments_integration import _evidence

from collectoo_worker.jobs.allocation import load_files

pytestmark = pytest.mark.integration
PLANTED = 10_000
PER_CALL = 60
WATCHED = (
    "public.client_status_event",
    "public.client_status_event_representative",
    "public.client_status_event_qualification",
    "public.claims_declared_item",
    "public.client_payout_account",
    "public.advance_repayment_request",
)
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"
ESTATE_IBAN = "FR4330004853190879732321668"
OTHER_IBAN = "FR4830004123377888003327207"


def _plants() -> tuple[tuple[str, str, tuple[str, ...], dict[str, int]], ...]:
    return (
        (
            # the other servicers' standing seizures and old rows still to qualify, by halves
            f"""insert into public.client_status_event (organization_id, client_organization_id,
                 kind, effective_date, evidence_document_id, note, recorded_by, qualified_at)
               select k.org[1 + g % 2], k.client[1 + g % 2],
                      case when g % 2 = 0 then 'seizure' else 'guardianship' end,
                      date '2000-01-01' + g % 300, gen_random_uuid(), 'Planted', gen_random_uuid(),
                      case when g % 2 = 0 then now() end
               from (select {TWO} org, {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.client_status_event",
            ("client_status_event_guard",),
            {"client_organization_id": 2, "organization_id": 2, "kind": 2},
        ),
        (
            # their releases, each naming another seizure (one release per seizure)
            f"""insert into public.client_status_event (organization_id, client_organization_id,
                 kind, effective_date, evidence_document_id, note, recorded_by, refers_to_event_id)
               select k.org[1 + g % 2], k.client[1 + g % 2], 'seizure_released',
                      date '2000-01-01' + g % 300, gen_random_uuid(), 'Planted', gen_random_uuid(),
                      gen_random_uuid()
               from (select {TWO} org, {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.client_status_event",
            ("client_status_event_guard",),
            {},
        ),
        (
            f"""insert into public.client_status_event_representative (organization_id,
                 client_organization_id, event_id, representative, evidence_document_id,
                 recorded_by)
               select k.org[1 + g % 2], k.client[1 + g % 2], k.ev[1 + g % 2],
                      '{{"role": "notary", "name": "Planted", "address_lines": ["x"]}}',
                      gen_random_uuid(), gen_random_uuid()
               from (select {TWO} org, {TWO} client, {TWO} ev) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.client_status_event_representative",
            (
                "client_status_event_representative_append_only",
                "client_status_event_representative_guard",
            ),
            {"event_id": 2, "organization_id": 2},
        ),
        (
            f"""insert into public.client_status_event_qualification (event_id, organization_id,
                 client_organization_id, kind, evidence_document_id, recorded_by)
               select gen_random_uuid(), k.org[1 + g % 2], k.client[1 + g % 2], 'guardianship',
                      gen_random_uuid(), gen_random_uuid()
               from (select {TWO} org, {TWO} client) k, generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.client_status_event_qualification",
            (
                "client_status_event_qualification_append_only",
                "client_status_event_qualification_guard",
            ),
            {"organization_id": 2},
        ),
        (
            f"""insert into public.claims_declared_item (event_id, organization_id,
                 client_organization_id, document_kind, document_id, amount_minor)
               select k.ev[1 + g % 2], k.org[1 + g % 2], k.client[1 + g % 2], 'invoice',
                      gen_random_uuid(), 100
               from (select {TWO} ev, {TWO} org, {TWO} client) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.claims_declared_item",
            ("claims_declared_item_append_only", "claims_declared_item_guard"),
            {"event_id": 2},
        ),
        (
            # (review round 1) the repayment requests of two other clients, their letters drawn and
            # addressed to a notary (the documents' rule reads a request by its letter's key)
            f"""insert into public.advance_repayment_request (organization_id,
                 client_organization_id, currency, number, issue_date, total_minor, payload,
                 payload_sha256, template_version, renderer_version, document_id, pdf_sha256,
                 issued_by)
               select k.org[1 + g % 2], k.client[1 + g % 2], 'EUR',
                      'DRA-2001-' || lpad(g::text, 6, '0'), date '2000-01-01' + g % 300, 100,
                      '{{"recipient": {{"role": "notary", "name": "Planted"}}}}', repeat('0', 64),
                      'demande-remboursement-avance-fr-1', 'planted', k.doc[1 + g % 2],
                      repeat('0', 64), gen_random_uuid()
               from (select {TWO} org, {TWO} client, {TWO} doc) k,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.advance_repayment_request",
            ("advance_repayment_request_guard",),
            {"client_organization_id": 2, "organization_id": 2, "document_id": 2},
        ),
    )


def _plant(conn: psycopg.Connection[Any], org: str) -> None:
    _plant_7c1(conn, org)
    conn.execute("set local session_replication_role = replica")
    for sql, table, triggers, _keys in _plants():
        for t in triggers:
            conn.execute(f"alter table {table} disable trigger {t}")
        conn.execute(sql)
        for t in triggers:
            conn.execute(f"alter table {table} enable always trigger {t}")
    conn.execute("set local session_replication_role = origin")
    for _sql, table, _triggers, keys in _plants():
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
def estate() -> dict[str, Any]:
    """A client whose death is recorded with its notary; the notary's account confirmed by a second
    admin; a run prepared (not blocked); a payment received after the death, held for ops."""
    tenant = remittance_tenant()
    tenant["admin2"] = add_admin(tenant)
    paid_file(tenant, 100_000)
    day = recent_business_day()
    _event(tenant, "death", day - timedelta(days=1), NOTARY)
    from remittance_helpers import staff  # noqa: PLC0415

    proposed = staff(
        tenant,
        """select public.propose_payout_account(%s, %s, 'EUR', %s, 'SCP LENOIR NOTAIRES', null, %s,
                                                'estate', %s, null)""",
        str(uuid.uuid4()),
        tenant["client"],
        ESTATE_IBAN,
        _evidence(tenant, "payout_rib"),
        _evidence(tenant, "payout_authority_evidence"),
    )
    staff(
        tenant,
        "select public.confirm_payout_account(%s, %s, %s)",
        str(uuid.uuid4()),
        proposed["payout_account_id"],
        ESTATE_IBAN,
        user=tenant["admin2"],
    )
    file, held = paid_file(tenant, 40_000, day)
    assert state(held) == ("matched", "client_mandate_ended")
    run = request_run(tenant)
    assert run_row(run)["blockers"] == [], run_row(run)
    with psycopg.connect(DB) as conn:
        evidence = _evidence(tenant, "client_status_evidence")
        account = one(conn, "select account_id from public.payment where id = %s", (held,))
    return {
        "tenant": tenant,
        "run": run,
        "held": held,
        "account": str(account),
        "evidence": evidence,
        "file": file,
    }


def test_the_client_event_reads_stay_keyed_whatever_the_statistics(  # noqa: PLR0915
    estate: dict[str, Any],
) -> None:
    tenant = estate["tenant"]
    org, client, ops = str(tenant["servicer"]), str(tenant["client"]), str(tenant["staff"])
    admin, admin2 = str(tenant["admin"]), str(tenant["admin2"])
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

        blockers = call(
            "remittance_payout_blockers",
            None,
            "select private.remittance_payout_blockers(%s, 'EUR', private.paris_today())",
            client,
        )
        assert blockers == [], blockers
        draft = one(
            conn,
            "select row_to_json(r) from public.remittance_run r where r.id = %s",
            (estate["run"],),
        )
        queued = call(
            "approve_remittance_runs",
            ops,
            "select public.approve_remittance_runs(%s, %s::jsonb)",
            str(uuid.uuid4()),
            json.dumps(
                [
                    {
                        "run_id": estate["run"],
                        "inputs_hash": draft["inputs_hash"],
                        "net_text": str(draft["net_minor"]),
                    }
                ]
            ),
        )
        assert [x["status"] for x in queued["results"]] == ["queued"], queued
        token = one(
            conn, "select job_token from public.remittance_run where id = %s", (estate["run"],)
        )
        call("approve_remittance_run (the re-check)", None,
             "select private.approve_remittance_run(%s, %s)", estate["run"], token)  # fmt: skip
        assert one(
            conn, "select status from public.remittance_run where id = %s", (estate["run"],)
        ) == ("approved")
        transfer = one(
            conn, "select transfer_id from public.remittance_run where id = %s", (estate["run"],)
        )
        hold = call(
            "transfer_hold_reason (the file's generation and download)",
            None,
            """select private.transfer_hold_reason(%s, private.paris_today(),
                                                    private.paris_today(), null)""",
            transfer,
        )
        assert hold is None, hold
        # the gate: the held payment's file regated (its review reason read again)
        conn.execute(
            "update public.payment set review_reason = null where id = %s", (estate["held"],)
        )
        call("regate_account (gate_assignments)", None, "select private.regate_account(%s)",
             estate["account"])  # fmt: skip
        assert state_in(conn, estate["held"]) == "client_mandate_ended"
        # the allocation job's own gate: the file's facts with its client's mandate end
        before = _rows(conn)
        conn.execute("set role postgres")
        files = load_files(conn, org, [estate["account"]])
        conn.execute("reset role")
        after = _rows(conn)
        measured["load_files (the allocation job's gate)"] = {
            k: after[k] - before[k] for k in after if after[k] - before[k]
        }
        assert files[estate["account"]].ended_on is not None
        left = one(
            conn,
            "select x.unallocated_minor::text from private.payment_positions(array[%s]::uuid[]) x",
            (estate["held"],),
        )
        call(
            "forward_payment",
            ops,
            "select public.forward_payment(%s, %s, null, %s, null, 'Reçu après la fin du mandat')",
            str(uuid.uuid4()),
            estate["held"],
            left,
        )
        addressees = call(
            "client_addressee",
            None,
            "select jsonb_agg(x.role) from private.client_addressee(%s, private.paris_today()) x",
            client,
        )
        assert addressees == ["notary"], addressees
        view = call("client_events_view", ops, "select public.client_events_view(%s)", client)
        assert [e["kind"] for e in view["events"]] == ["death"], view
        seizure = call(
            "record_client_status_event (a seizure)",
            admin,
            """select public.record_client_status_event(%s, %s, 'seizure',
                 private.paris_today() - 1, %s,
                 null, null, null, null, null, null)""",
            str(uuid.uuid4()),
            client,
            estate["evidence"],
        )
        call(
            "record_client_status_event (its release)",
            admin,
            """select public.record_client_status_event(%s, %s, 'seizure_released',
                 private.paris_today(),
                 %s, null, null, null, null, %s, null)""",
            str(uuid.uuid4()),
            client,
            estate["evidence"],
            seizure["client_status_event_id"],
        )
        death = view["events"][0]["id"]
        call(
            "set_client_representative",
            admin,
            "select public.set_client_representative(%s, %s, %s::jsonb, %s)",
            str(uuid.uuid4()),
            death,
            json.dumps(NOTARY | {"name": "Me Paul Lenoir, notaire"}),
            estate["evidence"],
        )
        # an old « Tutelle ou curatelle » row of the client (qualified_at null: the guard set aside)
        conn.execute(
            "alter table public.client_status_event disable trigger client_status_event_guard"
        )
        old = one(
            conn,
            """insert into public.client_status_event (organization_id,
                 client_organization_id, kind,
                 effective_date, evidence_document_id, recorded_by, qualified_at)
               values (%s, %s, 'guardianship', private.paris_today() - 30, %s, %s, null)
               returning id""",
            (org, client, estate["evidence"], admin),
        )
        conn.execute(
            "alter table public.client_status_event enable always trigger client_status_event_guard"
        )
        call(
            "qualify_protection_event",
            admin,
            "select public.qualify_protection_event(%s, %s, 'curatorship', %s)",
            str(uuid.uuid4()),
            old,
            estate["evidence"],
        )
        proposed = call(
            "propose_payout_account (estate)",
            ops,
            """select public.propose_payout_account(%s, %s, 'EUR', %s, 'SCP LENOIR NOTAIRES',
                                                    null, %s,
                                                    'estate', %s, null)""",
            str(uuid.uuid4()),
            client,
            OTHER_IBAN,
            *one(
                conn,
                """select array[evidence_document_id, authority_document_id]
                   from public.client_payout_account
                   where client_organization_id = %s and status = 'active'""",
                (client,),
            ),
        )
        call(
            "confirm_payout_account (payout_court_appointed)",
            admin2,
            "select public.confirm_payout_account(%s, %s, %s)",
            str(uuid.uuid4()),
            proposed["payout_account_id"],
            OTHER_IBAN,
        )
        night = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (org,),
        )
        call(
            "run_advance_checks (full)",
            None,
            "select private.run_advance_checks(%s, %s, private.paris_today(), true)",
            night,
            org,
        )
        alerts = one(
            conn,
            """select jsonb_agg(code order by code) from public.payment_check_result
               where run_id = %s and code in ('protection_event_to_qualify', 'seizure_standing')""",
            (night,),
        )
        assert alerts is None, alerts  # the client's own row is qualified, its seizure released
        # (review round 1, TUI-2) the confirmation gate: the client's events, what each counts as
        gate = call(
            "portfolio_confirmation_blockers",
            None,
            "select private.portfolio_confirmation_blockers(%s, private.paris_today())",
            str(tenant["portfolio"]),
        )
        assert any(b.startswith("client_deceased:") for b in gate), gate
        # (review round 1, MONEY-LAW-2, TUI-3) a letter of the client addressed to its notary (the
        # worker's job emulated: the document, the request naming it)
        conn.execute("set local session_replication_role = replica")
        letter = one(
            conn,
            """insert into public.document (organization_id, client_organization_id, kind,
                 storage_bucket, storage_path, sha256, mime_type, file_name)
               values (%s, %s, 'advance_repayment_request_pdf', 'documents',
                       'repayment-requests/' || %s || '/' || gen_random_uuid() || '.pdf',
                       repeat('c', 64), 'application/pdf', 'DRA.pdf') returning id""",
            (org, client, org),
        )
        conn.execute(
            """insert into public.advance_repayment_request (organization_id,
                 client_organization_id, currency, number, issue_date, total_minor, payload,
                 payload_sha256, template_version, renderer_version, document_id, pdf_sha256,
                 issued_by)
               values (%s, %s, 'EUR', 'DRA-2026-999999', private.paris_today(), 100, %s::jsonb,
                       repeat('0', 64), 'demande-remboursement-avance-fr-1', 'test', %s,
                       repeat('0', 64), %s)""",
            (org, client, json.dumps({"recipient": NOTARY}), letter, admin),
        )
        conn.execute("set local session_replication_role = origin")
        read = "select count(*) from public.document where id = %s"
        assert call("document (a letter to the notary, as the client's member)", tenant["user"],
                    read, letter) == 0  # fmt: skip
        assert call("document (the same letter, as staff)", ops, read, letter) == 1
        listed = call(
            "client_repayment_requests (as the client's member)",
            tenant["user"],
            "select public.client_repayment_requests(%s)",
            client,
        )
        assert [(r["document_id"], r["to_representative"]) for r in listed["rows"]] == [
            (None, True)
        ], listed

    lines = [f"{n}: {r} (bound {PER_CALL})" for n, r in measured.items()]
    print(
        f"\n{PLANTED} rows planted per table (two values of each key, other servicers' events),"
        " generic"
        " plans — rows read from the planted tables:\n  " + "\n  ".join(lines)
    )
    assert {n: r for n, r in measured.items() if sum(r.values()) > PER_CALL} == {}


def state_in(conn: psycopg.Connection[Any], payment: str) -> str | None:
    return one(conn, "select review_reason from public.payment where id = %s", (payment,))  # type: ignore[no-any-return]
