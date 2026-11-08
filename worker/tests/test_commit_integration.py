"""Integration (needs `make up`): staged -> commit -> rollback / confirm (M1-18)."""

import csv
import json
import uuid
from pathlib import Path
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, as_user, board, drain, make_tenant, one, storage

from collectoo_worker.synth.civil import DIALECT_SPECS, generate_civil

pytestmark = pytest.mark.integration


@pytest.fixture
def tenant() -> dict[str, Any]:
    return make_tenant()


def _clean_file(tmp_path: Path, kind: str = "b2b_invoice", rows: int = 120) -> Path:
    table, _ = generate_civil(kind, "fr_semicolon", rows, 23, defect_rate=0)  # type: ignore[arg-type]
    path = tmp_path / f"{kind}.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        csv.writer(fh, delimiter=DIALECT_SPECS["fr_semicolon"].delimiter).writerows(table)
    return path


def _to_staged(tenant: dict[str, Any], path: Path) -> str:
    store = storage()
    batch = board(tenant, store, path)
    drain(store)
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.approve_mapping(%s, %s)", (batch, json.dumps({})))
    drain(store)
    with psycopg.connect(DB) as conn:
        assert (
            one(conn, "select status from public.boarding_batch where id = %s", (batch,))
            == "staged"
        )
    return batch


def _call(user: str, sql: str, params: tuple[Any, ...], aal: str = "aal1") -> None:
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, user, aal)
        conn.execute(sql, params)


def _count(sql: str, params: tuple[Any, ...]) -> int:
    with psycopg.connect(DB) as conn:
        return int(one(conn, sql, params))


def test_commit_then_rollback_leaves_only_the_audit_trail(
    tenant: dict[str, Any], tmp_path: Path
) -> None:
    path = _clean_file(tmp_path)
    refs = {r[0] for r in csv.reader(path.open(encoding="utf-8"), delimiter=";")} - {
        "Compte client"
    }
    batch = _to_staged(tenant, path)
    with psycopg.connect(DB) as conn:
        digest = one(
            conn, "select staging_digest from public.boarding_batch where id = %s", (batch,)
        )
    assert digest["account"]["rows"] == len(refs)

    _call(tenant["user"], "select public.commit_boarding_batch(%s)", (batch,))
    accounts = _count("select count(*) from public.account where boarding_batch_id = %s", (batch,))
    assert accounts == len(refs)
    assert (
        _count(
            "select count(*) from public.account"
            " where boarding_batch_id = %s and status <> 'staged'",
            (batch,),
        )
        == 0
    )
    assert (
        _count(
            "select count(*) from public.claim_item i join public.account a on a.id = i.account_id"
            " where a.boarding_batch_id = %s",
            (batch,),
        )
        == 120
    )
    assert (
        _count(
            "select count(*) from public.claim_ownership_period o"
            " join public.account a on a.id = o.account_id"
            " where a.boarding_batch_id = %s",
            (batch,),
        )
        == accounts
    )
    assert _count(
        "select count(*) from public.party where boarding_batch_id = %s", (batch,)
    ) == len(refs)

    with pytest.raises(psycopg.errors.CheckViolation, match="reason"):
        _call(tenant["user"], "select public.rollback_boarding_batch(%s, %s)", (batch, " "))
    _call(
        tenant["user"],
        "select public.rollback_boarding_batch(%s, %s)",
        (batch, "wrong client file"),
    )
    assert _count("select count(*) from public.account where boarding_batch_id = %s", (batch,)) == 0
    assert _count("select count(*) from public.party where boarding_batch_id = %s", (batch,)) == 0
    assert (
        _count(
            "select count(*) from public.boarding_batch where id = %s and status = 'rolled_back'",
            (batch,),
        )
        == 1
    )
    # The audit trail keeps every insert and delete of the batch's accounts.
    assert (
        _count(
            "select count(*) from private.change_log"
            " where table_name = 'public.account' and op = 'DELETE'"
            " and changed ->> 'boarding_batch_id' = %s",
            (batch,),
        )
        == accounts
    )


def test_confirm_needs_staff_and_an_active_mandate(tenant: dict[str, Any], tmp_path: Path) -> None:
    batch = _to_staged(tenant, _clean_file(tmp_path, "rent", 60))
    _call(tenant["user"], "select public.commit_boarding_batch(%s)", (batch,))
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        _call(tenant["user"], "select public.confirm_boarding_batch(%s)", (batch,))
    with pytest.raises(psycopg.errors.CheckViolation, match="mandate"):
        _call(tenant["staff"], "select public.confirm_boarding_batch(%s)", (batch,), aal="aal2")

    with psycopg.connect(DB) as conn, conn.transaction():
        mandate = one(
            conn,
            "insert into public.mandate"
            " (organization_id, client_organization_id, reference, mandate_type, signed_on)"
            " values (%s, %s, %s, 'mandate_amicable', current_date - 30) returning id",
            (tenant["servicer"], tenant["client"], f"M-{uuid.uuid4().hex[:6]}"),
        )
        conn.execute(
            "insert into public.mandate_terms (mandate_id, valid_from, commission_rate)"
            " values (%s, current_date - 30, 0.15)",
            (mandate,),
        )
        conn.execute(
            "update public.portfolio set mandate_id = %s where id = %s",
            (mandate, tenant["portfolio"]),
        )
    _call(tenant["staff"], "select public.confirm_boarding_batch(%s)", (batch,), aal="aal2")
    drain(storage())  # the confirmation job posts the opening balances (M2-05)
    total = _count("select count(*) from public.account where boarding_batch_id = %s", (batch,))
    waiting = _count(
        "select count(*) from public.account where boarding_batch_id = %s"
        " and status = 'awaiting_first_letter'",
        (batch,),
    )
    assert total > 0 and waiting == total  # first possible contact: the R124-4 letter
    # M2-05: Σ opening balances = the data-quality report's reconciled outstanding total.
    with psycopg.connect(DB) as conn:
        outstanding = one(
            conn,
            "select (dq_report #>> '{reconciliation,computed,outstanding_minor}')::bigint"
            " from public.boarding_batch where id = %s",
            (batch,),
        )
        posted = one(
            conn,
            """select coalesce(sum(p.amount_minor), 0)::bigint from public.ledger_entry e
               join public.ledger_posting p on p.entry_id = e.id
               join public.ledger_account la on la.id = p.ledger_account_id
               where la.book = 'debtor_receivable'
                 and e.boarding_batch_id = %s and e.entry_type = 'opening'""",
            (batch,),
        )
        status = one(conn, "select status from public.boarding_batch where id = %s", (batch,))
    assert status == "confirmed" and posted == outstanding > 0
    with pytest.raises(psycopg.errors.CheckViolation, match="committed, unconfirmed"):
        _call(tenant["user"], "select public.rollback_boarding_batch(%s, %s)", (batch, "too late"))


def test_a_mismatch_needs_a_reason_to_commit(tenant: dict[str, Any], tmp_path: Path) -> None:
    store = storage()
    batch = board(tenant, store, _clean_file(tmp_path, "b2c_invoice", 50))
    drain(store)
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.set_control_totals(%s, %s, %s)", (batch, 1, 50))
        conn.execute("select public.approve_mapping(%s, %s)", (batch, json.dumps({})))
    drain(store)
    with pytest.raises(psycopg.errors.CheckViolation, match="reason is required"):
        _call(tenant["user"], "select public.commit_boarding_batch(%s)", (batch,))
    _call(
        tenant["user"],
        "select public.commit_boarding_batch(%s, %s)",
        (batch, "seller total excludes VAT"),
    )
    with psycopg.connect(DB) as conn:
        reason = one(
            conn, "select commit_override_reason from public.boarding_batch where id = %s", (batch,)
        )
    assert reason == "seller total excludes VAT"


def test_reboarding_skips_accounts_already_in_the_portfolio(
    tenant: dict[str, Any], tmp_path: Path
) -> None:
    path = _clean_file(tmp_path, "b2b_invoice", 40)
    first = _to_staged(tenant, path)
    _call(tenant["user"], "select public.commit_boarding_batch(%s)", (first,))
    (tmp_path / "again").mkdir()
    second = _to_staged(tenant, _clean_file(tmp_path / "again", "b2b_invoice", 40))
    with psycopg.connect(DB) as conn:
        report = one(conn, "select dq_report from public.boarding_batch where id = %s", (second,))
    assert report["staging"]["already_boarded_accounts_skipped"] > 0
    # M2-05 bridge: computed = opening of the staged accounts + opening of the skipped ones.
    staging, computed = report["staging"], report["reconciliation"]["computed"]["currencies"]
    skipped = staging["skipped"]["currencies"]["EUR"]
    assert (
        skipped["accounts"] + skipped["accounts_without_balance"]
        == (staging["already_boarded_accounts_skipped"])
    )
    opening = staging["opening"]["currencies"].get("EUR", {"outstanding_minor": "0"})
    assert int(computed["EUR"]["outstanding_minor"]) == int(opening["outstanding_minor"]) + int(
        skipped["outstanding_minor"]
    )
    _call(tenant["user"], "select public.commit_boarding_batch(%s)", (second,))
    assert (
        _count("select count(*) from public.account where boarding_batch_id = %s", (second,)) == 0
    )


def test_a_dead_job_is_shown_on_its_batch(tenant: dict[str, Any], tmp_path: Path) -> None:
    from collectoo_worker.jobs.boarding import record_dead_job  # noqa: PLC0415

    batch = board(tenant, storage(), _clean_file(tmp_path, rows=20))
    with psycopg.connect(DB) as conn, conn.transaction():
        record_dead_job({"type": "profile", "batch_id": batch}, "ValueError: not a CSV", conn)
    with psycopg.connect(DB) as conn:
        failed = one(conn, "select failed_job from public.boarding_batch where id = %s", (batch,))
        files = conn.execute(
            "select status, error from public.boarding_file where batch_id = %s", (batch,)
        ).fetchall()
    assert failed["type"] == "profile" and failed["error"] == "ValueError: not a CSV"
    assert files == [("failed", "ValueError: not a CSV")]


def test_jobs_of_an_abandoned_batch_do_nothing(tenant: dict[str, Any], tmp_path: Path) -> None:
    store = storage()
    batch = board(tenant, store, _clean_file(tmp_path, rows=20))
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.abandon_boarding_batch(%s, %s)", (batch, "wrong client file"))
    drain(store)  # the queued profiling job is consumed without effect
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.boarding_batch where id = %s", (batch,))
        profiled = one(
            conn,
            "select count(*) from public.boarding_file where batch_id = %s and profile is not null",
            (batch,),
        )
    assert status == "abandoned" and profiled == 0


def test_a_file_that_cannot_be_read_as_a_table_blocks_the_batch(
    tenant: dict[str, Any], tmp_path: Path
) -> None:
    """A fixed-width file without layout next to a CSV is never dropped silently."""
    dat = tmp_path / "historique.dat"
    dat.write_text("C0001  0000012345 20260115\n", encoding="utf-8")
    store = storage()
    batch = board(tenant, store, _clean_file(tmp_path, rows=20), dat)
    drain(store)
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.approve_mapping(%s, %s)", (batch, json.dumps({})))
    drain(store)
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.boarding_batch where id = %s", (batch,))
        issues = conn.execute(
            """select f.file_name, i.severity from public.validation_issue i
               join public.boarding_file f on f.id = i.file_id
               where i.batch_id = %s and i.code = 'file_not_boarded'""",
            (batch,),
        ).fetchall()
    assert status == "needs_fix"
    assert issues == [("historique.dat", "blocking")]
    with psycopg.connect(DB) as conn:
        report = one(conn, "select dq_report from public.boarding_batch where id = %s", (batch,))
    listed = {f["name"]: f["issues"] for f in report["files"]}
    assert listed["historique.dat"] == {"file_not_boarded": {"severity": "blocking", "count": 1}}
