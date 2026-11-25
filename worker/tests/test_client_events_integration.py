"""M2c-7d-1 through the real commands and jobs (needs `make up`; plan
docs/design/m2c-7-plan.md §6.2,
§6.6 « Worker »; ADR-0014 « M2c-7d-1 »).

* a death recorded, with the notary as the person who acts for the client, while a run's approval
  is queued: the approval job refuses it (client_status:death); prepared again the run is blocked
  and « Valider » refuses it; the notary's account proposed with the attestation and confirmed by
  a second admin; the run prepared again and approved, its payout to the notary's account
  (founder Q8, C. civ. 1309);
* a payment received after the mandate's end: imported, matched by the import's rules, held
  client_mandate_ended (never allocated); « Reverser au client » forwards it with the reason
  mandate_ended; the next prepare prices it at nothing although the schedule prices the other
  forwards (founder Q10);
* a payment matched and ready, the mandate's end recorded before the allocation job runs: the
  job's own gate (the twin of private.gate_assignments) holds it client_mandate_ended, nothing
  allocated;
* a curatelle: the repayment request's letter, drawn by the real job, is addressed to the client
  with a copy to its curator ([check 1] gap 7; C. civ. 440 al. 1, 467 al. 3 by analogy, OQ-94);
* two sessions releasing one seizure at once: one release, the other refused
  release_without_seizure ([check 2] gap 6);
* (review round 1, CC-2) an event waiting on a confirmation's payout_accounts: lock is stamped
  after it; (CC-4) the allocation job's end read runs as the service role.
"""

from __future__ import annotations

import json
import threading
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from allocation_helpers import File, Item, allocations, create_file, credit, state
from integration_helpers import DB, SCHEDULE, TERMS, as_user, one, storage
from reconciliation_helpers import pay
from remittance_helpers import (
    add_admin,
    approve,
    drain,
    paid_file,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from test_client_payments_integration import _evidence
from test_repayment_requests_integration import _request, _request_row, _worked_example

from collectoo_worker.jobs.allocation import load_files, run_allocate
from collectoo_worker.remittance.repayment_request import RepaymentRequestDocument, request_text
from collectoo_worker.remittance.repayment_request_pdf import pdf_sha256, render_request_pdf

pytestmark = pytest.mark.integration
NOTARY = {"role": "notary", "name": "Me Claire Lenoir, notaire",
          "address_lines": ["3 place du Palais", "69002 Lyon"]}  # fmt: skip
CURATOR = {"role": "curator", "name": "Association Tutélaire de Lyon",
           "address_lines": ["3 place du Palais", "69002 Lyon"]}  # fmt: skip
ESTATE_IBAN = "FR6430004424452125091990850"


def _value(sql: str, *params: Any) -> Any:
    with psycopg.connect(DB) as conn:
        return one(conn, sql, params)


def _event(  # noqa: PLR0913 - the command's arguments
    tenant: dict[str, Any],
    kind: str,
    on: Any,
    representative: dict[str, Any] | None = None,
    *,
    refers_to: str | None = None,
    user: str | None = None,
) -> Any:
    """« Enregistrer un événement » as an admin at aal2."""
    return staff(
        tenant,
        """select public.record_client_status_event(%s, %s, %s, %s, %s, 'Événement (test)', null,
                                                    null, %s::jsonb, %s, null)""",
        str(uuid.uuid4()),
        tenant["client"],
        kind,
        on,
        _evidence(tenant, "client_status_evidence"),
        None if representative is None else json.dumps(representative),
        refers_to,
        user=user or tenant["admin"],
    )


def test_a_death_then_the_notary_s_account_confirmed_and_the_run_approved() -> None:
    tenant = remittance_tenant()
    second = add_admin(tenant)
    paid_file(tenant, 100_000)
    run = request_run(tenant)
    assert run_row(run)["blockers"] == [], run_row(run)
    approve(tenant, run)  # queued; the death recorded meanwhile: the approval job refuses it
    death = _event(tenant, "death", recent_business_day() - timedelta(days=1), NOTARY)
    assert death["client_status_event_id"]
    drain()
    # (M2c-7d-2, house rule R3, ADR-0014 « M2c-7d-2 ») the plan set off the run's own invoice
    # under the netting clause; after the death nothing is set off (founder Q9 a): the plan no
    # longer holds, so the approval sends it back client_status_changed (was
    # payout_blocked:client_status:death, the blocker it shows once prepared again, below)
    assert (run_row(run)["status"], run_row(run)["last_failure"]["code"]) == (
        "draft",
        "client_status_changed",
    )
    # prepared again: blocked, « Valider » refuses it up front
    staff(
        tenant,
        "select public.refresh_remittance_run(%s, %s, %s)",
        str(uuid.uuid4()),
        run,
        run_row(run)["version"],
    )
    drain()
    assert "client_status:death" in (run_row(run)["blockers"]), run_row(run)
    refused = approve(tenant, run)
    assert [(x["status"], x["reason"]) for x in refused["results"]] == [
        ("refused", "payout_blocked")
    ]
    # the notary's account (the office's name: no holder rule for an estate), its attestation
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
    confirmed = staff(
        tenant,
        "select public.confirm_payout_account(%s, %s, %s)",
        str(uuid.uuid4()),
        proposed["payout_account_id"],
        ESTATE_IBAN,
        user=second,
    )
    assert confirmed["confirmed_via"] == "second_admin"
    staff(
        tenant,
        "select public.refresh_remittance_run(%s, %s, %s)",
        str(uuid.uuid4()),
        run,
        run_row(run)["version"],
    )
    drain()
    assert run_row(run)["blockers"] == [], run_row(run)
    approve(tenant, run)
    drain()
    assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
    assert (
        _value(
            "select payee_iban from public.bank_transfer where id = %s", run_row(run)["transfer_id"]
        )
        == ESTATE_IBAN
    )


def test_a_payment_after_the_mandate_s_end_is_held_then_forwarded_without_commission() -> None:
    # the schedule prices every other forward: a payment after the end earns nothing all the same
    every_forward: dict[str, Any] = json.loads(json.dumps(SCHEDULE))
    every_forward["basis"]["forwards"] = {
        "file_recalled": True,
        "before_servicing_start": True,
        "client_ratification": True,
    }
    tenant = remittance_tenant(schedule=every_forward)
    day = recent_business_day()
    _event(tenant, "mandate_ended", day - timedelta(days=1))
    _f, payment = paid_file(tenant, 50_000, day)
    assert state(payment) == ("matched", "client_mandate_ended")
    assert allocations(payment) == []
    left = _value(
        "select x.unallocated_minor::text from private.payment_positions(array[%s]::uuid[]) x",
        payment,
    )
    forwarded = staff(
        tenant,
        "select public.forward_payment(%s, %s, null, %s, null, 'Reçu après la fin du mandat')",
        str(uuid.uuid4()),
        payment,
        left,
    )
    assert (
        _value(
            """select reason from public.client_notification
           where payment_id = %s and kind = 'payment_forwarded'""",
            payment,
        )
        == "mandate_ended"
    )
    run = request_run(tenant)
    line = _value(
        """select jsonb_build_array(l.kind, l.amount_minor, l.commission_minor)
           from private.remittance_draft_line l where l.run_id = %s and l.ledger_entry_id = %s""",
        run,
        forwarded["entry_id"],
    )
    assert line == ["forward", 50_000, 0]


def test_an_end_recorded_after_the_payment_was_assigned_still_keeps_it_from_allocation() -> None:
    tenant = remittance_tenant()
    day = recent_business_day()
    f = create_file(
        tenant,
        File(f"E-{uuid.uuid4().hex[:8]}", "b2b", "Débiteur SARL",
             [Item("E-1", {"principal": 30_000}, date(2026, 9, 1))]),
    )  # fmt: skip
    prefix = f"E{uuid.uuid4().hex[:6].upper()}"
    sid = pay(tenant, storage(), [credit(30_000, rf=f.rf)], prefix=prefix, start=day, days=1,
              allocate=False)  # fmt: skip
    payment = str(
        _value(
            """select p.id from public.payment p
               join public.bank_transaction t on t.id = p.bank_transaction_id
               where t.statement_id = %s""",
            sid,
        )
    )
    assert state(payment) == ("matched", None)  # gated ready, the allocation job not run yet
    _event(tenant, "death", day - timedelta(days=1), NOTARY)
    with psycopg.connect(DB) as conn, conn.transaction():
        run_allocate(conn, {"organization_id": str(tenant["servicer"])})
    assert state(payment) == ("matched", "client_mandate_ended")
    assert allocations(payment) == []


def test_a_curatelle_s_letter_goes_to_the_client_with_a_copy_to_its_curator(tmp_path: Path) -> None:
    tenant, a1 = _worked_example(TERMS)
    admin = add_admin(tenant)
    tenant["admin"] = admin
    _event(tenant, "curatorship", _value("select private.paris_today()"), CURATOR)
    made = _request(tenant, [a1], "200000")
    drain()  # the letter's job
    row = _request_row(str(made["request_id"]))
    assert row["payload"]["copies"] == [CURATOR]
    doc = RepaymentRequestDocument(
        row["number"], row["issue_date"], row["payload"], row["template_version"]
    )
    assert "Copie : Association Tutélaire de Lyon, curateur, 3 place du Palais, 69002 Lyon" in (
        request_text(doc).split("\n")
    )
    path = _value("select storage_path from public.document where id = %s", row["document_id"])
    stored = storage().download("documents", path, tmp_path / "letter.pdf").read_bytes()
    assert pdf_sha256(stored) == row["pdf_sha256"] == pdf_sha256(render_request_pdf(doc))


def test_two_sessions_releasing_one_seizure_record_one_release() -> None:
    tenant = remittance_tenant()
    admins = [add_admin(tenant), add_admin(tenant)]
    today = _value("select private.paris_today()")
    seizure = _event(tenant, "seizure", today - timedelta(days=2))["client_status_event_id"]
    evidence = _evidence(tenant, "client_status_evidence")
    outcomes: dict[int, str] = {}
    first = psycopg.connect(DB)
    try:
        with first.transaction():
            as_user(first, admins[0], "aal2")
            first.execute(
                """select public.record_client_status_event(%s, %s, 'seizure_released',
                     %s, %s, null,
                                                            null, null, null, %s, null)""",
                (str(uuid.uuid4()), tenant["client"], today, evidence, seizure),
            )

            def second() -> None:
                with psycopg.connect(DB) as conn, conn.transaction():
                    as_user(conn, admins[1], "aal2")
                    try:
                        conn.execute(
                            """select public.record_client_status_event(%s, %s, 'seizure_released',
                                 %s, %s, null, null, null, null, %s, null)""",
                            (str(uuid.uuid4()), tenant["client"], today, evidence, seizure),
                        )
                        outcomes[1] = "ok"
                    except psycopg.Error as e:
                        outcomes[1] = str(e).splitlines()[0]

            t = threading.Thread(target=second)
            t.start()
            t.join(1.0)
            assert t.is_alive()  # waits for the first release (the payout_accounts: lock)
        t.join(10.0)
    finally:
        first.close()
    assert outcomes[1] == "client event refused: release_without_seizure"
    assert (
        _value(
            """select count(*) from public.client_status_event
           where refers_to_event_id = %s and kind = 'seizure_released'""",
            seizure,
        )
        == 1
    )


def test_an_event_waiting_on_a_confirmation_s_lock_is_stamped_after_it() -> None:
    """(Review round 1, CC-2) « Enregistrer un événement » started first, a second admin's
    confirmation took the payout_accounts: lock before it: the event waits, then is stamped once
    it holds the lock (clock_timestamp), after the confirmation — so the account confirmed
    meanwhile, which never saw the mandate end, does not count as confirmed after it."""
    tenant = remittance_tenant()
    second = add_admin(tenant)
    today = _value("select private.paris_today()")
    iban = "FR4330004853190879732321668"
    proposed = staff(
        tenant,
        """select public.propose_payout_account(%s, %s, 'EUR', %s, 'CLIENT TEST', null, %s,
                                                'client', null, null)""",
        str(uuid.uuid4()),
        tenant["client"],
        iban,
        _evidence(tenant, "payout_rib"),
    )
    evidence = _evidence(tenant, "client_status_evidence")
    outcome: dict[str, Any] = {}
    event_conn = psycopg.connect(DB)
    confirm_conn = psycopg.connect(DB)
    try:
        with event_conn.transaction():
            as_user(event_conn, tenant["admin"], "aal2")
            # its transaction starts before the other's
            started = one(event_conn, "select now()", ())
            with confirm_conn.transaction():
                as_user(confirm_conn, second, "aal2")
                confirmed = one(
                    confirm_conn,
                    "select public.confirm_payout_account(%s, %s, %s)",
                    (str(uuid.uuid4()), proposed["payout_account_id"], iban),
                )
                assert confirmed["confirmed_via"] == "second_admin"

                def record() -> None:
                    try:
                        outcome["event"] = one(
                            event_conn,
                            """select public.record_client_status_event(%s, %s, 'mandate_ended',
                                 %s, %s, null, null, null, null, null, null)""",
                            (
                                str(uuid.uuid4()),
                                tenant["client"],
                                today - timedelta(days=1),
                                evidence,
                            ),
                        )
                    except psycopg.Error as e:
                        outcome["error"] = str(e).splitlines()[0]

                t = threading.Thread(target=record)
                t.start()
                t.join(0.5)
                assert t.is_alive()  # waits for the confirmation's lock (2 s at most)
            t.join(10.0)
            assert "error" not in outcome, outcome
    finally:
        event_conn.close()
        confirm_conn.close()
    with psycopg.connect(DB) as conn:
        stamps = conn.execute(
            """select e.recorded_at, a.confirmed_at from public.client_status_event e,
                 public.client_payout_account a where e.id = %s and a.id = %s""",
            (outcome["event"]["client_status_event_id"], proposed["payout_account_id"]),
        ).fetchone()
        blockers = one(
            conn,
            "select private.remittance_payout_blockers(%s, 'EUR', %s)",
            (tenant["client"], today),
        )
    assert stamps is not None
    recorded_at, confirmed_at = stamps
    assert started < confirmed_at < recorded_at
    assert "client_status:mandate_ended" in blockers, blockers


def test_the_allocation_job_reads_the_mandate_s_end_as_the_worker_s_role() -> None:
    """(Review round 1, CC-4) the job's end read (private.client_end_event) is executable by the
    service role the worker is to log in as (ADR-0012), as its other private reads are."""
    tenant = remittance_tenant()
    day = recent_business_day()
    _event(tenant, "mandate_ended", day - timedelta(days=1))
    f, _payment = paid_file(tenant, 50_000, day)
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("set local role service_role")
        files = load_files(conn, str(tenant["servicer"]), [f.id])
    assert files[f.id].ended_on == day - timedelta(days=1)
