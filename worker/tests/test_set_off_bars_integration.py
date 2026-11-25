"""M2c-7d-2 « set-off bars » through the real prepare, approval and debit jobs (needs `make up`;
plan docs/design/m2c-7-plan.md §6.2.2, §6.2.4 to §6.2.6, §6.2.9, §6.2.11, §6.6 « Worker »; ADR-0014
« M2c-7d-2 »).

* a client in redressement between two runs: the real prepare reads the opening, each invoice's
  birth and the bars — the invoice born before the opening is not set off, the run's own invoice
  (born after it) is; the draft records the opening and the bars it assumed; approved;
* a liquidation recorded alone (carried from 7c-1): nothing is set off; the run's own invoice is
  issued due with its payment line (« Client en liquidation judiciaire … »), frozen in its payload;
* an event recorded between the prepare and the approval: the approval job sends the run back
  client_status_changed;
* the debit-time withholding through the real debit job: the redressement recorded after the
  file's download, the payout's debit imported — the barred set-off posted and reversed, the
  withheld item queued; the hourly schedule drafts a run under the trigger settlement_withheld,
  whose prepare holds the item to the withheld run's R124-6 date (the twin of
  private.pending_item_deadlines) and pays it outside every mandate.
"""

from __future__ import annotations

import hashlib
import json
import tempfile
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import psycopg
import pytest
from integration_helpers import DB, one, storage
from remittance_helpers import (
    approve,
    book_payout,
    drain,
    paid_file,
    paris_today,
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from test_client_payments_integration import _evidence

from collectoo_worker.jobs.remittances import HELD_TO_SQL, run_schedule

pytestmark = pytest.mark.integration
PARIS = ZoneInfo("Europe/Paris")
NO_NETTING = {"schema": "remittance-1", "frequency": "twice_monthly", "netting": None,
              "clawback": None, "invoice_payment_days": 30}  # fmt: skip


def _value(sql: str, *params: Any) -> Any:
    with psycopg.connect(DB) as conn:
        return one(conn, sql, params)


def _event(tenant: dict[str, Any], kind: str, on: date) -> Any:
    """« Enregistrer un événement » as an admin at aal2 (no representative)."""
    return staff(
        tenant,
        """select public.record_client_status_event(%s, %s, %s, %s, %s, 'Événement (test)', null,
                                                    null, null, null, null)""",
        str(uuid.uuid4()),
        tenant["client"],
        kind,
        on,
        _evidence(tenant, "client_status_evidence"),
        user=tenant["admin"],
    )


def _netting_from_now(tenant: dict[str, Any]) -> None:
    """(test only) the mandate's terms gain the netting clause (the version's guard set aside)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("alter table public.mandate_terms disable trigger mandate_terms_guard")
        conn.execute(
            """update public.mandate_terms
               set remittance_terms = remittance_terms || '{"netting": {"clause_ref": "art. 7.2"}}'
               where mandate_id = %s""",
            (tenant["mandate"],),
        )
        conn.execute("alter table public.mandate_terms enable trigger mandate_terms_guard")


def _due_invoice(tenant: dict[str, Any], day: date, amount: int = 200_000) -> str:
    """A collection of `amount` on `day` remitted by a run without a netting clause, its payout
    booked: its invoice (born on `day`), open in full. The invoice."""
    paid_file(tenant, amount, day=day)
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
    book_payout(run)
    return str(
        _value(
            "select id from public.commission_invoice where run_id = %s and kind = 'invoice'", run
        )
    )


def _draft(run: str) -> dict[str, Any]:
    with psycopg.connect(DB) as conn:
        cur = conn.execute(
            """select proceeding_opened_on, opening_on, set_off_barred, plan, documents
               from private.remittance_draft where run_id = %s""",
            (run,),
        )
        row = cur.fetchone()
        assert row is not None and cur.description is not None
        return {d.name: v for d, v in zip(cur.description, row, strict=True)}


def _refs(plan: dict[str, Any]) -> list[tuple[str, str]]:
    return [(str(s["ref"]), str(s["kind"])) for s in plan.get("settles", [])]


def test_a_client_in_redressement_between_two_runs() -> None:
    tenant = remittance_tenant(terms=NO_NETTING)
    d1 = recent_business_day(8)
    fc1 = _due_invoice(tenant, d1)
    _netting_from_now(tenant)
    opening = d1 + timedelta(days=1)
    _event(tenant, "proceeding_opened", opening)
    paid_file(tenant, 100_000, day=recent_business_day(1))
    run = request_run(tenant)
    draft = _draft(run)
    assert (draft["proceeding_opened_on"], draft["opening_on"], draft["set_off_barred"]) == (
        opening,
        opening,
        "-/proceeding",
    )
    refs = _refs(draft["plan"])
    assert (fc1, "compensation") not in refs  # born before the opening: never set off
    assert any(r.startswith("new:") for r, _ in refs)  # the run's own invoice, born after it
    approve(tenant, run)
    drain()
    assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]


def test_a_liquidation_recorded_alone_sets_nothing_off() -> None:
    tenant = remittance_tenant(terms=NO_NETTING)
    d1 = recent_business_day(8)
    fc1 = _due_invoice(tenant, d1)
    _netting_from_now(tenant)
    judgment = d1 + timedelta(days=1)
    _event(tenant, "liquidation", judgment)
    paid_file(tenant, 100_000, day=recent_business_day(1))
    run = request_run(tenant)
    draft = _draft(run)
    assert draft["set_off_barred"] == "liquidation/liquidation"
    assert _refs(draft["plan"]) == []
    inv = next(x for x in draft["documents"] if x["kind"] == "invoice")
    assert inv["settlement"] == "due"
    assert inv["payment_note"]["text"].startswith(
        f"Client en liquidation judiciaire (jugement du {judgment:%d/%m/%Y})"
    )
    assert _value("select private.document_open(%s)", fc1) == 36_000
    # a liquidation blocks the payout until the liquidator's account is confirmed: the invoice is
    # issued with the run, so the payload is read off the draft here (approved in 046b)


def test_an_event_between_the_prepare_and_the_approval_sends_the_run_back() -> None:
    tenant = remittance_tenant(terms=NO_NETTING)
    d1 = recent_business_day(8)
    _due_invoice(tenant, d1)
    _netting_from_now(tenant)
    paid_file(tenant, 400_000, day=recent_business_day(1))
    run = request_run(tenant)
    assert _draft(run)["set_off_barred"] is None
    assert any(not r.startswith("new:") for r, _ in _refs(_draft(run)["plan"]))  # FC-1 planned
    approve(tenant, run)  # queued; the redressement recorded meanwhile
    _event(tenant, "proceeding_opened", d1 + timedelta(days=1))
    drain()
    assert (run_row(run)["status"], run_row(run)["last_failure"]["code"]) == (
        "draft",
        "client_status_changed",
    )


def _download(tenant: dict[str, Any]) -> None:
    """The ordered payouts filed (the file generated, written by the job) and downloaded."""
    file_id = staff(tenant, "select public.generate_transfer_file(%s, %s, null)",
                    str(uuid.uuid4()), tenant["bank"])["file_id"]  # fmt: skip
    drain()
    path = _value("select storage_path from public.transfer_file where id = %s", file_id)
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "f.xml"
        storage().download("transfer-files", path, dest)
        digest = hashlib.sha256(dest.read_bytes()).hexdigest()
    staff(tenant, "select public.transfer_file_download(%s, %s)", file_id, digest)


def test_the_debit_job_withholds_a_set_off_barred_by_then_and_the_schedule_gives_it_back() -> None:
    tenant = remittance_tenant(terms=NO_NETTING)
    d1 = recent_business_day(8)
    fc1 = _due_invoice(tenant, d1)
    _netting_from_now(tenant)
    paid_file(tenant, 400_000, day=recent_business_day(1))
    run = request_run(tenant)
    taken = sum(int(s["amount"]) for s in _draft(run)["plan"]["settles"] if s["ref"] == fc1)
    assert taken == 36_000
    approve(tenant, run)
    drain()
    assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
    _download(tenant)
    opening = d1 + timedelta(days=1)
    _event(tenant, "proceeding_opened", opening)  # recorded after the download, before the debit
    book_payout(run)
    with psycopg.connect(DB) as conn:
        barred = one(conn, "select id from public.ledger_entry where idempotency_key = %s",
                     (f"settle:{run}:barred",))  # fmt: skip
        back = conn.execute(
            "select id, reason from public.ledger_entry where idempotency_key = %s",
            (f"return:barred:{run}",),
        ).fetchone()
        item = conn.execute(
            """select q.ledger_entry_id, q.kind, q.amount_minor from private.remittance_pending q
               where q.client_organization_id = %s""",
            (tenant["client"],),
        ).fetchall()
        rows = conn.execute(
            "select document_id from public.commission_settlement where run_id = %s", (run,)
        ).fetchall()
    assert barred is not None and back is not None
    assert back[1] == (f"Compensation retenue : procédure collective depuis le {opening:%d/%m/%Y} "
                       "(règle du cabinet)")  # fmt: skip
    assert [(str(i[0]), i[1], int(i[2])) for i in item] == [
        (str(back[0]), "settlement_withheld", 36_000)
    ]
    assert str(fc1) not in {str(r[0]) for r in rows}
    assert _value("select private.document_open(%s)", fc1) == 36_000
    # the schedule drafts a run for it at its next hour (any day), under its own trigger
    now = datetime.now(PARIS).replace(hour=10)
    with psycopg.connect(DB) as conn:
        created = run_schedule(conn, {"organization_id": tenant["servicer"]}, now=now)
        conn.commit()
    drain()
    nxt = _value(
        """select id from public.remittance_run
           where client_organization_id = %s and status = 'draft'""",
        tenant["client"],
    )
    assert created == [str(nxt)]
    assert run_row(str(nxt))["trigger"] == "settlement_withheld"
    with psycopg.connect(DB) as conn:
        line = conn.execute(
            """select kind, mandate_id, commission_minor, latest_execution_date
               from private.remittance_draft_line where run_id = %s""",
            (nxt,),
        ).fetchall()
        held = conn.execute(HELD_TO_SQL, (nxt,)).fetchall()
        sql_date = one(
            conn,
            """select d.latest_execution_date from private.pending_item_deadlines(%s) d
               where d.ledger_entry_id = %s""",
            (tenant["servicer"], back[0]),
        )
        withheld_from = one(
            conn,
            """select min(l.latest_execution_date) from public.remittance_line l
               where l.run_id = %s and l.amount_minor > 0 and not l.released""",
            (run,),
        )
    assert [(k, m, int(c)) for k, m, c, _ in line] == [("settlement_withheld", None, 0)]
    assert len(held) == 1 and str(held[0][0]) == str(back[0])
    assert line[0][3] == sql_date == withheld_from
    assert json.dumps(run_row(str(nxt))["blockers"]) == "[]"
    assert paris_today() >= opening
