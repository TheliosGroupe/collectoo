# ruff: noqa: E501, PLR0913, PLR0917 - SQL fixtures read better unwrapped
"""M2c-7e-1 (needs `make up`; ADR-0014 « M2c-7e-1 »): the slice's reads by a parameter or a
correlated key stay keyed whatever the statistics — the plan class that broke main after 7a (a key
the last analyse saw with two values, priced at half the table: a sequential scan, a hash of the
whole table, a partial index whose predicate a parameter's filter must imply).

In the test's rolled-back transaction the tables are planted with PLANTED rows each of: the
top-ups and sweeps of two other servicers in flight or booked (bank_transfer, in two other files of
two other accounts), those files (transfer_file) and their items (transfer_file_item, each the item
of a planted transfer: a read of the items of booked transfers reads them), the postings of
two other servicers' 4679 accounts (ledger_posting), the bank charges of two other servicers
(ledger_entry), their closed shortfall periods (private.servicer_shortfall_period) and two other
accounts' credits under two other end-to-end ids (bank_transaction) — each analysed with its keys'
n_distinct pinned (2); every plan generic. Then, on a servicer whose bank charge the debit job
booked, whose hourly job ordered its top-up, with a top-up typed by ops, its own-account file
written by the job, the TOP credit of the filed top-up and a credit without a TOP id waiting:
what is needed (private.top_up_needed), the hourly step (private.order_due_top_up), the three
reads (public.top_up_overview, public.top_up_credit_options, public.servicer_shortfall_periods),
« Générer le fichier (compte propre) », « Annuler le fichier » (each in a savepoint), the file's
first download refused (review round 1: the TOP1 credit is on a statement), a new file generated,
recorded as the job writes it and downloaded twice, the funds pass of the debit job on the TOP1
credit (the worker's own reads and the SQL re-check), « Rattacher à TOP… »
(public.book_top_up_credit), « Annuler » a filed top-up (public.cancel_top_up), and (review round
1, CC-2) « Annuler » of the payout files refusing an own-account file and the file job's failure on
one (private.transfer_file_failed) — and the rows each read from the planted tables: a few per
call, never the planted rows. (Review round 1, CC-1: a fifth of the planted transfers carry the
waiting credit's amount, amount_minor's n_distinct pinned too. Review round 2, own-account-history-reads: the
servicer's own account also carries OWN_HISTORY booked top-ups of its past, under the debtor key pinned with the
others: « Générer le fichier » and the overview's count read its ordered top-ups only; the overview lists its latest
LISTED by design.) The nightly's private.run_advance_checks reads the
servicer's own rows whole by design: its bound is 7d-3's body's reads in the same transaction (read
from the migration file) plus PER_CALL, none of the planted rows."""

from __future__ import annotations

import uuid
from pathlib import Path
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import DB, one, storage
from psycopg.types.json import Jsonb
from remittance_helpers import drain, own_account, paris_today, remittance_tenant, staff
from statement_helpers import upload
from test_client_payment_reads_integration import _as
from test_top_ups_integration import _fee, _import_only, _last_statement

from collectoo_worker.jobs.debits import _process_funds_lines
from collectoo_worker.synth.camt053 import Entry, Tx, make_doc, render_camt053

pytestmark = pytest.mark.integration
PLANTED = 10_000
PER_CALL = 60
OWN_HISTORY = 5_000  # (review round 2) the own account's past top-ups, booked
LISTED = 50  # the overview's latest top-ups of an own account (by bank_transfer_top_up_idx, in its order)
WATCHED = (
    "public.bank_transfer",
    "public.transfer_file",
    "public.transfer_file_item",
    "public.ledger_posting",
    "public.ledger_entry",
    "private.servicer_shortfall_period",
    "public.bank_transaction",
)
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"
AMOUNT = 900  # the credit without a TOP id waiting (« Rattacher à TOP… »), and TOP3's amount
MIGRATIONS = Path(__file__).resolve().parents[2] / "supabase/migrations"
BEFORE_7E1 = (
    "20261128090000_declarations_statement.sql",
    "create or replace function private.run_advance_checks(",
)


def _plants(
    top: str, file: str, item_file: str, line: str, fee: str, period: str
) -> tuple[tuple[str, str, dict[str, int]], ...]:
    """Copies of the servicer's own rows (a top-up, its file, an item, a credit line, a fee entry and
    its posting, a period) with their keys moved to two other servicers' values."""
    return (
        (
            f"""insert into public.bank_transfer
               select (jsonb_populate_record(null::public.bank_transfer, to_jsonb(t)
                        || jsonb_build_object('id', md5('plant-t' || g)::uuid, 'organization_id', k.org[1 + g % 2],
                             'debtor_bank_account_id', k.acct[1 + g % 2],
                             'creditor_bank_account_id', k.cf[1 + g % 2],
                             'kind', case when g % 3 = 0 then 'sweep' else 'top_up' end,
                             'status', case when g % 2 = 0 then 'in_file' when g % 4 = 1 then 'ordered'
                                            else 'booked' end,
                             'transfer_file_id', case when g % 4 <> 1 then k.f[1 + g % 2] end,
                             -- a booked one's entry (the plant runs as replica: no foreign key is checked)
                             'entry_id', case when g % 4 = 3 then gen_random_uuid() end,
                             'end_to_end_id', case when g % 3 = 0 then 'SWP' else 'TOP' end
                               || 'E' || upper(lpad(to_hex(g), 11, '0')),
                             -- (review round 1, CC-1) a fifth of them of the waiting credit's amount
                             'amount_minor', case when g % 5 = 0 then {AMOUNT} else t.amount_minor end))).*
               from (select {TWO} org, {TWO} acct, {TWO} cf, {TWO} f) k,
                    (select q.* from public.bank_transfer q where q.id = '{top}') t,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.bank_transfer",
            {
                "organization_id": 2,
                "debtor_bank_account_id": 2,
                "creditor_bank_account_id": 2,
                "transfer_file_id": 2,
                "end_to_end_id": 2,
                "amount_minor": 2,
            },
        ),
        (
            # (review round 2, own-account-history-reads) the servicer's own account's past: OWN_HISTORY booked
            # top-ups (copies of TOP1, executed long ago, by hand), under the key its reads are keyed by
            f"""insert into public.bank_transfer
               select (jsonb_populate_record(null::public.bank_transfer, to_jsonb(t)
                        || jsonb_build_object('id', md5('plant-own' || g)::uuid, 'status', 'booked',
                             'transfer_file_id', null, 'entry_id', gen_random_uuid(),
                             'end_to_end_id', 'TOPD' || upper(lpad(to_hex(g), 11, '0')),
                             'created_at', t.created_at - make_interval(days => 1, secs => g)))).*
               from (select q.* from public.bank_transfer q where q.id = '{top}') t,
                    generate_series(1, {OWN_HISTORY}) g""",  # noqa: S608 - the tests' own constants
            "public.bank_transfer",
            {
                "organization_id": 2,
                "debtor_bank_account_id": 2,
                "creditor_bank_account_id": 2,
                "transfer_file_id": 2,
                "end_to_end_id": 2,
                "amount_minor": 2,
            },
        ),
        (
            f"""insert into public.transfer_file
               select (jsonb_populate_record(null::public.transfer_file, to_jsonb(f)
                        || jsonb_build_object('id', gen_random_uuid(), 'organization_id', k.org[1 + g % 2],
                             'debtor_bank_account_id', k.acct[1 + g % 2],
                             'number', 'TF-2098-' || lpad(g::text, 6, '0'),
                             'msg_id', 'TF-2098-' || lpad(g::text, 6, '0'),
                             'storage_path', 'plant/' || g || '.xml'))).*
               from (select {TWO} org, {TWO} acct) k,
                    (select q.* from public.transfer_file q where q.id = '{file}') f,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.transfer_file",
            {"organization_id": 2, "debtor_bank_account_id": 2},
        ),
        (
            f"""insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id,
                 pmt_inf_id, execution_date)
               select k.f[1 + g % 2], g, md5('plant-t' || g)::uuid, k.org[1 + g % 2],
                      'TF-2098-00000' || (1 + g % 2) || '-1', current_date
               from (select {TWO} f, {TWO} org) k, generate_series(1, {PLANTED}) g
               where '{item_file}' is not null""",  # noqa: S608 - the tests' own constants
            "public.transfer_file_item",
            {"file_id": 2, "transfer_id": 2, "pmt_inf_id": 2},
        ),
        (
            f"""insert into public.bank_transaction
               select (jsonb_populate_record(null::public.bank_transaction, to_jsonb(x)
                        || jsonb_build_object('id', gen_random_uuid(), 'organization_id', k.org[1 + g % 2],
                             'bank_account_id', k.acct[1 + g % 2], 'statement_id', k.st[1 + g % 2],
                             'line_no', g, 'dedup_key', 't:plant-' || g,
                             'end_to_end_id', 'TOPPLANTED00' || (g % 2)))).*
               from (select {TWO} org, {TWO} acct, {TWO} st) k,
                    (select q.* from public.bank_transaction q where q.id = '{line}') x,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.bank_transaction",
            {"organization_id": 2, "bank_account_id": 2, "end_to_end_id": 2, "statement_id": 2},
        ),
        (
            f"""insert into public.ledger_entry
               select (jsonb_populate_record(null::public.ledger_entry, to_jsonb(e)
                        || jsonb_build_object('id', gen_random_uuid(), 'organization_id', k.org[1 + g % 2],
                             'idempotency_key', 'fee:plant-' || lpad(g::text, 8, '0'),
                             'posted_at', now() - make_interval(secs => g)))).*
               from (select {TWO} org) k,
                    (select q.* from public.ledger_entry q where q.id = '{fee}') e,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.ledger_entry",
            {"organization_id": 2},
        ),
        (
            f"""insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor,
                 currency, effective_date)
               select k.e[1 + g % 2], g, k.acct[1 + g % 2], 100, 'EUR', current_date
               from (select {TWO} e, {TWO} acct) k, generate_series(1, {PLANTED}) g""",  # noqa: S608
            "public.ledger_posting",
            {"ledger_account_id": 2, "entry_id": 2},
        ),
        (
            f"""insert into private.servicer_shortfall_period (organization_id, currency, since_at,
                 opened_at, closed_at, peak_minor, last_minor)
               select k.org[1 + g % 2], 'EUR', now() - interval '2 days', now() - interval '1 day',
                      now(), 100, 0
               from (select {TWO} org) k, generate_series(1, {PLANTED}) g
               where '{period}' is not null""",  # noqa: S608 - the tests' own constants
            "private.servicer_shortfall_period",
            {"organization_id": 2},
        ),
    )


def _plant(conn: psycopg.Connection[Any], ids: dict[str, str]) -> None:
    plants = _plants(ids["top"], ids["file"], ids["file"], ids["line"], ids["fee"], ids["file"])
    conn.execute("set local session_replication_role = replica")
    for sql, table, _keys in plants:
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
    for _sql, table, keys in plants:
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


def _written(conn: psycopg.Connection[Any], file_id: str) -> str:
    """The transfer_file job's record of a file it wrote (emulated, as 047a's pg_temp.write: no bytes, their
    hash standing for them): the hash the download checks."""
    with conn.transaction():
        conn.execute("set local role postgres")
        conn.execute(
            """select private.transfer_file_record(f.id, f.job_token,
                 encode(sha256(convert_to(f.id::text, 'UTF8')), 'hex'), 1234,
                 f.organization_id || '/' || f.id || '/' || f.number || '.xml', false, 'pain001-1',
                 f.nb_of_txs, f.ctrl_sum_minor)
               from public.transfer_file f where f.id = %s""",
            (file_id,),
        )
        conn.execute("reset role")
    return str(one(conn, "select file_sha256 from public.transfer_file where id = %s", (file_id,)))


def _body_before_7e1() -> str:
    text = (MIGRATIONS / BEFORE_7E1[0]).read_text()
    start = text.index(BEFORE_7E1[1])
    end = text.index("\n$$;", start) + len("\n$$;")
    return text[start:end]


@pytest.fixture(scope="module")
def owing() -> dict[str, Any]:
    """A servicer owing its dedicated account a bank charge: its hourly order (TOP1), a top-up typed
    by ops (TOP2), both in its own-account file written by the job (generated, not downloaded); the
    TOP1 credit and a credit without a TOP id waiting (imported, the debit job not run), the TOP3 of
    that credit's amount ordered."""
    tenant = remittance_tenant()
    own, own_iban = own_account(tenant)
    _fee(tenant, 1_500)
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("select pgmq.send('remittances', %s)",
                     (Jsonb({"type": "top_ups", "organization_id": str(tenant["servicer"])}),))  # fmt: skip
    drain()
    top2 = staff(tenant, "select public.request_top_up(%s, %s, %s, '400', 'test')", str(uuid.uuid4()),
                 own, tenant["bank"])  # fmt: skip
    file_id = staff(tenant, "select public.generate_top_up_file(%s, %s)", str(uuid.uuid4()), own)[
        "file_id"
    ]
    drain()
    top3 = staff(tenant, "select public.request_top_up(%s, %s, %s, '900', 'test')", str(uuid.uuid4()),
                 own, tenant["bank"])  # fmt: skip
    with psycopg.connect(DB) as conn:
        top1 = one(conn, """select end_to_end_id from public.bank_transfer where organization_id = %s
                             and kind = 'top_up' and amount_minor = 1500""", (tenant["servicer"],))  # fmt: skip
    opening, day = _last_statement(tenant)
    refs = [f"R{uuid.uuid4().hex[:10].upper()}" for _ in range(2)]
    entries = [
        Entry(1_500, True, day, day, ref=refs[0], txs=(Tx(1_500, ref=f"L{refs[0]}", end_to_end_id=top1,
                                                          iban=own_iban),)),
        Entry(900, True, day, day, ref=refs[1], txs=(Tx(900, ref=f"L{refs[1]}", iban=own_iban),)),
    ]  # fmt: skip
    doc = make_doc(entries, iban=tenant["iban"], from_date=day, to_date=day, opening_minor=opening,
                   stmt_id=f"S{refs[0]}")  # fmt: skip
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{refs[0]}.xml")
    _import_only()
    with psycopg.connect(DB) as conn:
        lines = {str(r[1]): str(r[0]) for r in conn.execute(
            "select id, entry_ref from public.bank_transaction where bank_account_id = %s",
            (tenant["bank"],)).fetchall()}  # fmt: skip
        fee = one(conn, """select id from public.ledger_entry where organization_id = %s
                            and entry_type = 'bank_fee'""", (tenant["servicer"],))  # fmt: skip
        top1_id = one(conn, "select id from public.bank_transfer where end_to_end_id = %s", (top1,))
        sha = one(conn, "select file_sha256 from public.transfer_file where id = %s", (file_id,))
    return {"tenant": tenant, "own": own, "file": str(file_id), "sha": sha, "top1": str(top1_id),
            "top2": str(top2["transfer_id"]), "top3": str(top3["transfer_id"]),
            "line1": lines[refs[0]], "line3": lines[refs[1]], "fee": str(fee)}  # fmt: skip


def test_the_top_up_reads_stay_keyed_whatever_the_statistics(  # noqa: PLR0915
    owing: dict[str, Any],
) -> None:
    tenant = owing["tenant"]
    org, user = str(tenant["servicer"]), str(tenant["staff"])
    measured: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn, {"top": owing["top1"], "file": owing["file"], "line": owing["line1"],
                      "fee": owing["fee"]})  # fmt: skip
        conn.execute("set local plan_cache_mode = force_generic_plan")

        def call(name: str, who: str | None, sql: str, *params: Any, keep: bool = True) -> Any:
            before = _rows(conn)
            value: Any = None
            try:
                with conn.transaction(force_rollback=not keep):
                    if who is None:
                        conn.execute("set local role postgres")
                    else:
                        _as(conn, who)
                    value = one(conn, sql, params)
                    conn.execute("reset role")
            except psycopg.errors.CheckViolation as exc:
                value = str(exc.diag.message_primary)
            after = _rows(conn)
            measured[name] = {k: after[k] - before[k] for k in after if after[k] - before[k]}
            return value

        assert call("top_up_needed", None, "select private.top_up_needed(%s, 'EUR')", org) == 0
        assert call("order_due_top_up", None, "select private.order_due_top_up(%s)", org) == 0
        overview = call("top_up_overview", user, "select public.top_up_overview()")
        assert [a["bank_account_id"] for a in overview["accounts"]] == [owing["own"]]
        # (review round 2) the one ordered top-up a file would take (TOP3; TOP1 and TOP2 are in the file), the
        # account's latest LISTED shown
        own_row = overview["accounts"][0]
        assert (own_row["ordered_count"], own_row["can_generate"]) == (1, True), own_row
        assert len(own_row["top_ups"]) == LISTED, own_row
        options = call("top_up_credit_options", user, "select public.top_up_credit_options(%s)",
                       owing["line3"])  # fmt: skip
        assert [o["transfer_id"] for o in options["top_ups"]] == [owing["top3"]]
        periods = call("servicer_shortfall_periods", user,
                       "select public.servicer_shortfall_periods(%s)", org)  # fmt: skip
        assert len(periods["periods"]) == 1
        call("generate_top_up_file", user, "select public.generate_top_up_file(%s, %s)",
             str(uuid.uuid4()), owing["own"], keep=False)  # fmt: skip
        call("cancel_top_up_file", user, "select public.cancel_top_up_file(%s, %s, 'test')",
             str(uuid.uuid4()), owing["file"], keep=False)  # fmt: skip
        # (review round 1, MONEY-BANK-2) the TOP1 credit is on a statement before the first download: the bank
        # executed it — the file is refused, superseded, its top-ups ordered again
        seen = call("transfer_file_download (credit seen)", user,
                    "select public.transfer_file_download(%s, %s)", owing["file"], owing["sha"])  # fmt: skip
        assert seen["refused"] == "file_blocked", seen
        assert [b["reason"] for b in seen["blocked"]] == ["top_up_credited"], seen
        # a new file of the top-ups still to execute (TOP2, TOP3; TOP1's credit waits to be booked), written as the
        # job records it, downloaded, then again
        second = call("generate_top_up_file (kept)", user, "select public.generate_top_up_file(%s, %s)",
                      str(uuid.uuid4()), owing["own"])  # fmt: skip
        assert second["nb_of_txs"] == 2, second
        sha = _written(conn, second["file_id"])
        first = call("transfer_file_download (first)", user,
                     "select public.transfer_file_download(%s, %s)", second["file_id"], sha)  # fmt: skip
        assert first["status"] == "downloaded", first
        again = call("transfer_file_download (again)", user,
                     "select public.transfer_file_download(%s, %s, true)", second["file_id"], sha)  # fmt: skip
        assert again["download"] == 2, again
        before = _rows(conn)
        with conn.transaction():
            conn.execute("set local role postgres")  # the worker's role (its temporary tables)
            summary = _process_funds_lines(conn, org, None)
            conn.execute("reset role")
        after = _rows(conn)
        measured["funds pass"] = {k: after[k] - before[k] for k in after if after[k] - before[k]}
        assert summary.get("top_ups") == 1, summary
        call("book_top_up_credit", user, "select public.book_top_up_credit(%s, %s, %s, 'test')",
             str(uuid.uuid4()), owing["line3"], owing["top3"])  # fmt: skip
        call("cancel_top_up (filed)", user, "select public.cancel_top_up(%s, %s, 'test')",
             str(uuid.uuid4()), owing["top2"])  # fmt: skip
        # (review round 1, CC-2) an own-account file the job could not write, and « Annuler » of the payout files
        # refusing it: closed by private.top_up_file_close, keyed — never transfer_file_release's run update
        call("request_top_up", user, "select public.request_top_up(%s, %s, %s, '700', 'test')",
             str(uuid.uuid4()), owing["own"], tenant["bank"])  # fmt: skip
        third = call("generate_top_up_file (to fail)", user, "select public.generate_top_up_file(%s, %s)",
                     str(uuid.uuid4()), owing["own"])  # fmt: skip
        row = conn.execute("select job_token, version from public.transfer_file where id = %s",
                           (third["file_id"],)).fetchone()  # fmt: skip
        assert row is not None
        token, version = row
        refused = call("cancel_transfer_file (own file)", user,
                       "select public.cancel_transfer_file(%s, %s, %s, 'test')",
                       str(uuid.uuid4()), third["file_id"], version)  # fmt: skip
        assert refused == "transfer file refused: not_a_payout_file", refused
        failed = call("transfer_file_failed (own file)", None,
                      "select private.transfer_file_failed(%s, %s, 'test')", third["file_id"], token)  # fmt: skip
        assert failed["status"] == "failed", failed
        # the nightly: 7d-3's body on the same books, then this slice's
        nightly: dict[str, dict[str, int]] = {}
        for label, setup in (("7d-3", _body_before_7e1()), ("7e-1", None)):
            with conn.transaction(force_rollback=True):
                if setup is not None:
                    conn.execute(setup)
                check = one(conn, "insert into public.payment_check_run (organization_id) values (%s) "
                                  "returning id", (org,))  # fmt: skip
                b0 = _rows(conn)
                conn.execute(
                    "select private.run_advance_checks(%s, %s, %s)", (check, org, paris_today())
                )
                b1 = _rows(conn)
                nightly[label] = {k: b1[k] - b0[k] for k in b1 if b1[k] - b0[k]}
    # (review round 2) the overview lists the own account's latest LISTED top-ups by design: beside OWN_HISTORY booked
    # ones it reads those LISTED, never the account's past (5,075 bank_transfer rows before the round)
    by_design = {"top_up_overview": {"bank_transfer": LISTED}}
    over = {
        name: {k: v for k, v in rows.items() if v > PER_CALL + by_design.get(name, {}).get(k, 0)}
        for name, rows in measured.items()
    }
    assert not any(over.values()), (over, measured)
    for table in WATCHED:
        key = table.replace("public.", "")
        assert nightly["7e-1"].get(key, 0) <= nightly["7d-3"].get(key, 0) + PER_CALL, nightly
