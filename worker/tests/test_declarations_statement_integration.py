"""M2c-7d-3 « declarations, liquidation, statement » through the real jobs and commands (needs `make
up`; plan docs/design/m2c-7-plan.md §6.2.8, §6.3, §6.6 « Worker »; ADR-0014 « M2c-7d-3 »).

* the withheld set-off given back, on the statement: a redressement recorded after the file's
  download, the payout's debit through the real debit job withholds the set-off of the invoice born
  before the opening; the hourly schedule drafts the run that gives it back, approved; the documents
  job draws its statement with `releve-reversement-fr-4` (its payload names the withheld run, the
  amount, the day and the ledger's reason) while the withheld run's own statement stayed fr-3; the
  nightly lists the invoice to declare (two months after the publication);
* a payout made to the client after its liquidation: the liquidation recorded after the download,
  the debit booked — the nightly lists it (P0) until an administrator records what became of it («
  Enregistrer la suite »), refused to an ops manager."""

from __future__ import annotations

import tempfile
import uuid
from datetime import datetime, timedelta
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
    recent_business_day,
    remittance_tenant,
    request_run,
    run_row,
    staff,
)
from test_client_payments_integration import _evidence
from test_set_off_bars_integration import (
    NO_NETTING,
    _download,
    _draft,
    _due_invoice,
    _netting_from_now,
)

from collectoo_worker.jobs.remittances import run_schedule

pytestmark = pytest.mark.integration
PARIS = ZoneInfo("Europe/Paris")


def _value(sql: str, *params: Any) -> Any:
    with psycopg.connect(DB) as conn:
        return one(conn, sql, params)


def _event(tenant: dict[str, Any], kind: str, on: Any, publication: Any = None) -> Any:
    return staff(
        tenant,
        """select public.record_client_status_event(%s, %s, %s, %s, %s, 'Événement (test)', null,
                                                    %s, null, null, null)""",
        str(uuid.uuid4()),
        tenant["client"],
        kind,
        on,
        _evidence(tenant, "client_status_evidence"),
        publication,
        user=tenant["admin"],
    )


def _checks(tenant: dict[str, Any], code: str) -> list[tuple[str, int, dict[str, Any]]]:
    """The nightly's payment checks run now (the real job's SQL): the rows of `code`, as
    [(subject, amount, details)]."""
    with psycopg.connect(DB) as conn:
        result = one(conn, "select private.run_payment_checks(%s)", (tenant["servicer"],))
        conn.commit()
        rows = conn.execute(
            """select subject_id::text, amount_minor, details from public.payment_check_result
               where run_id = %s and code = %s order by subject_id""",
            (result["run_id"], code),
        ).fetchall()
    return [(str(r[0]), int(r[1]), dict(r[2])) for r in rows]


def test_the_withheld_set_off_given_back_is_on_the_next_statement_fr4() -> None:
    tenant = remittance_tenant(terms=NO_NETTING)
    d1 = recent_business_day(8)
    fc1 = _due_invoice(tenant, d1)
    _netting_from_now(tenant)
    paid_file(tenant, 400_000, day=recent_business_day(1))
    run = request_run(tenant)
    assert any(s["ref"] == fc1 for s in _draft(run)["plan"]["settles"])
    approve(tenant, run)
    drain()
    assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
    _download(tenant)
    opening = d1 + timedelta(days=1)
    _event(tenant, "proceeding_opened", opening, opening + timedelta(days=1))
    book_payout(run)
    reason = _value(
        "select reason from public.ledger_entry where idempotency_key = %s", f"return:barred:{run}"
    )
    debited = _value("select effective_date from public.ledger_entry where idempotency_key = %s",
                     f"settle:{run}:barred")  # fmt: skip
    now = datetime.now(PARIS).replace(hour=10)
    with psycopg.connect(DB) as conn:
        created = run_schedule(conn, {"organization_id": tenant["servicer"]}, now=now)
        conn.commit()
    drain()
    assert len(created) == 1
    nxt = created[0]
    approve(tenant, nxt)
    drain()  # the approval, then the documents job (its statement drawn)
    assert run_row(nxt)["status"] in ("approved", "booked"), run_row(nxt)["last_failure"]
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select run_id::text, template_version, payload, pdf_document_id
               from public.remittance_statement where run_id in (%s, %s)""",
            (run, nxt),
        ).fetchall()
        by_run = {r[0]: r for r in rows}
        path = one(
            conn, "select storage_path from public.document where id = %s", (by_run[nxt][3],)
        )
    assert by_run[run][1] == "releve-reversement-fr-3"
    assert by_run[nxt][1] == "releve-reversement-fr-4"
    payload = by_run[nxt][2]
    assert payload["schema"] == 2
    assert payload["withheld_given_back"] == [
        {
            "run_number": run_row(run)["number"],
            "amount_minor": "36000",
            "withheld_on": debited.isoformat(),
            "reason": reason,
        }
    ]
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "s.pdf"
        storage().download("documents", path, dest)
        pdf = dest.read_bytes()
    assert pdf[:5] == b"%PDF-" and b"releve-reversement-fr-4" in pdf
    # the withheld run's page: given back by the next run (approved: being given back)
    shown = staff(tenant, "select public.remittance_run_withheld(%s)", run)
    assert run_row(nxt)["number"] in (shown["given_back_by"], shown["giving_back_by"]), shown
    # FC-1, born before the opening and still open, is to declare: two months after the publication
    rows_ = _checks(tenant, "claims_to_declare")
    assert [(s, a) for s, a, _ in rows_] == [(fc1, 36_000)]
    details = rows_[0][2]
    assert (details["pre_opening"], details["deadline_basis"]) == (True, "publication")
    expected = _value("select (%s::date + interval '2 months')::date", opening + timedelta(days=1))
    assert details["deadline"] == expected.isoformat()


def test_a_payout_after_the_liquidation_is_alerted_until_its_disposition() -> None:
    tenant = remittance_tenant(terms=NO_NETTING)
    paid_file(tenant, 150_000, day=recent_business_day(1))
    run = request_run(tenant)
    approve(tenant, run)
    drain()
    assert run_row(run)["status"] == "approved", run_row(run)["last_failure"]
    _download(tenant)
    judgment = recent_business_day(6)
    _event(tenant, "liquidation", judgment)
    transfer = str(run_row(run)["transfer_id"])
    in_file = _checks(tenant, "payout_after_liquidation")
    assert [(s, d["status"], d["cancellable"]) for s, _, d in in_file] == [
        (transfer, "in_file", False)
    ]
    book_payout(run)
    booked = _checks(tenant, "payout_after_liquidation")
    assert [(s, d["status"], d["p0"]) for s, _, d in booked] == [(transfer, "booked", True)]
    evidence = _evidence(tenant, "client_status_evidence")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        staff(tenant, "select public.record_liquidation_payout_disposition(%s, %s, 'ratified', "
              "%s, null)",
              str(uuid.uuid4()), transfer, evidence)  # fmt: skip
    done = staff(
        tenant,
        "select public.record_liquidation_payout_disposition(%s, %s, 'repaid_to_liquidator', "
        "%s, %s)",
        str(uuid.uuid4()),
        transfer,
        evidence,
        "Somme reversée au liquidateur (test)",
        user=tenant["admin"],
    )
    assert done["kind"] == "repaid_to_liquidator"
    assert _checks(tenant, "payout_after_liquidation") == []
