"""M2c-7b review round 2, SWEEP-7B-STATS (needs `make up`; ADR-0014 « M2c-7b review fixes »
round 2): 7b's reads by a parameter or correlated key stay keyed whatever the statistics.

M2c-7a's CI round on main (test_remitted_cover_reads_integration.py) found a plan class: when a
table's last analyse saw a key column with two values (n_distinct 2, as CI's scale order leaves
remittance_line), a probe of that key by a parameter or a correlated key — every SQL function's
statement in PostgreSQL 17, PL/pgSQL's under its cached generic plan, a prepared statement's —
is priced at half the table, and a sequential scan, a hash of the whole table or another index
read whole (a partial one whose predicate the filter implies) cheaper. Here, in each test's
rolled-back transaction, every table 7b reads by such a key is planted that way: remittance_line
as that test plants it (two runs, one released; the live index rebuilt), and
commission_settlement, client_advance, private.unplanned_paid_item, private.remittance_pending,
client_status_event and mandate_terms with PLANTED rows each over two values of each key 7b
reads them by (no trigger, no foreign key: they belong to no servicer, client, run or entry of
ours), each analysed with those columns' n_distinct pinned at 2; every plan generic
(plan_cache_mode). Then, on a lot of LOT payouts made through the jobs, the line short of one
member booked and K members' collections taken back (« Désimputer »: K covers posted), each 7b
read run as its caller runs it — the SQL helpers, the pages, the item's settlement, the night's
advance checks, « Passer en perte », transfer_line_check's advance_in_flight rule; the worker's
prepare (its loader, as its role reads it), the draft written and its approval (the documents'
re-check, the line insert guard) — and the rows it read from the planted tables
(pg_stat_xact: sequential reads and index entries returned) a few per advance, never the planted
rows. Before the round, the loader's three 7b statements read every planted client_advance
(twice) and unplanned_paid_item row: a hash of the table, a sequential scan."""

from __future__ import annotations

import json
import uuid
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import one
from psycopg.types.json import Jsonb
from test_debit_bookings_scale_integration import _file_payouts
from test_remitted_cover_reads_integration import _plant as _plant_lines
from test_transfer_line_scale_integration import REASON, _insert_short_line

from collectoo_worker.jobs.remittances import (
    _open_advances,
    _unplanned_paid,
    load_facts,
    write_draft,
)
from collectoo_worker.remittance.run import prepare_run

pytestmark = pytest.mark.integration
LOT = 6
K = 3  # the members whose collection is taken back once their run is booked: K covers
PLANTED = 10_000  # the planted rows per table, over two values of each key
# the rows a read may take from the planted tables: a few per advance it reads, plus a slack for
# its own servicer's rows (the lot's runs, lines, entries)
PER_ADVANCE = 12
SLACK = 60
WATCHED = (
    "public.remittance_line",
    "private.remittance_pending",
    "public.commission_settlement",
    "public.client_advance",
    "private.unplanned_paid_item",
    "public.client_status_event",
    "public.mandate_terms",
)
# the tables 7b's statements in the worker's prepare and in the approval read (those paths' other
# reads are earlier slices' statements: printed, not bounded — ADR « Left open »)
SEVEN_B = ("client_advance", "commission_settlement", "private.unplanned_paid_item")
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"
# each planted table: its rows over two values of each key 7b reads it by, the triggers that fire
# always (off while planting), the keys whose n_distinct is pinned
PLANTS = (
    (
        """insert into public.commission_settlement (organization_id, client_organization_id,
             document_kind, document_id, kind, amount_minor, settled_on)
           select k.org[1 + g % 2], k.client[1 + g % 2], 'advance', k.doc[1 + g % 2],
                  'compensation', 1, private.paris_today()
           from (select {two} org, {two} client, {two} doc) k, generate_series(1, {n}) g""",
        "public.commission_settlement",
        ("commission_settlement_advance_guard",),
        ("document_id", "client_organization_id"),
    ),
    (
        """insert into public.client_advance (organization_id, client_organization_id, currency,
             amount_minor, cause, cause_entry_id, entry_id)
           select k.org[1 + g % 2], k.client[1 + g % 2], 'EUR', 100, 'double_payout',
                  k.cause[1 + g % 2], gen_random_uuid()
           from (select {two} org, {two} client, {two} cause) k, generate_series(1, {n}) g""",
        "public.client_advance",
        ("client_advance_guard",),
        ("organization_id", "client_organization_id", "cause_entry_id"),
    ),
    (
        """insert into private.unplanned_paid_item (booking_entry_id, ledger_entry_id,
             organization_id, client_organization_id, currency, amount_minor)
           select case when g % 4 < 2 then k.booking[1 + g % 2] else gen_random_uuid() end,
                  case when g % 4 < 2 then gen_random_uuid() else k.entry[1 + g % 2] end,
                  k.org[1 + g % 2], k.client[1 + g % 2], 'EUR', 1
           from (select {two} booking, {two} entry, {two} org, {two} client) k,
                generate_series(1, {n}) g""",
        "private.unplanned_paid_item",
        (),
        ("booking_entry_id", "ledger_entry_id", "organization_id"),
    ),
    (
        """insert into private.remittance_pending (ledger_entry_id, organization_id,
             client_organization_id, currency, kind, amount_minor, posted_at, draft_run_id)
           select gen_random_uuid(), k.org[1 + g % 2], k.client[1 + g % 2], 'EUR',
                  'allocation', 1, now(), k.run[1 + g % 2]
           from (select {two} org, {two} client, {two} run) k, generate_series(1, {n}) g""",
        "private.remittance_pending",
        (),
        ("draft_run_id", "client_organization_id"),
    ),
    (
        """insert into public.client_status_event (organization_id, client_organization_id, kind,
             effective_date, evidence_document_id, note, recorded_by)
           select k.org[1 + g % 2], k.client[1 + g % 2], 'proceeding_opened',
                  date '2000-01-01' + g, gen_random_uuid(), 'Planted', gen_random_uuid()
           from (select {two} org, {two} client) k, generate_series(1, {n}) g""",
        "public.client_status_event",
        ("client_status_event_guard",),
        ("client_organization_id",),
    ),
    (
        """insert into public.mandate_terms (mandate_id, valid_from, valid_to)
           select k.mandate[1 + g % 2], date '1900-01-01' + g, date '1900-01-01' + g + 2
           from (select {two} mandate) k, generate_series(1, {n}) g""",
        "public.mandate_terms",
        ("mandate_terms_guard", "mandate_terms_hash"),
        ("mandate_id",),
    ),
)


@pytest.fixture(scope="module")
def lot(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    return _file_payouts(tmp_path_factory, LOT, 0, "advance-reads")


def _plant(conn: psycopg.Connection[Any]) -> None:
    """remittance_line as the cover test plants it, its live index rebuilt; then each table of
    PLANTS, without its triggers and foreign keys, in `conn`'s transaction only (the superuser's),
    analysed with its keys' n_distinct pinned at 2."""
    _plant_lines(conn)
    conn.execute("reindex index public.remittance_line_live_uq")
    conn.execute("set local session_replication_role = replica")
    for sql, table, triggers, _keys in PLANTS:
        for t in triggers:
            conn.execute(f"alter table {table} disable trigger {t}")
        conn.execute(sql.format(two=TWO, n=PLANTED))
        for t in triggers:
            conn.execute(f"alter table {table} enable always trigger {t}")
    conn.execute("set local session_replication_role = origin")
    for _sql, table, _triggers, keys in PLANTS:
        for key in keys:
            conn.execute(f"alter table {table} alter column {key} set (n_distinct = 2)")
        conn.execute(f"analyze {table}")


def _rows(conn: psycopg.Connection[Any]) -> dict[str, int]:
    """This transaction's rows of each watched table so far: sequential reads and the index
    entries its indexes returned (an index-only or bitmap read of a whole index counts)."""
    rows = conn.execute(
        """select t.relid::regclass::text,
                  coalesce(pg_stat_get_xact_tuples_returned(t.relid), 0)
                  + coalesce((select sum(pg_stat_get_xact_tuples_returned(i.indexrelid))
                              from pg_index i where i.indrelid = t.relid), 0)
           from (select unnest(%s::regclass[]) relid) t""",
        (list(WATCHED),),
    ).fetchall()
    return {str(r[0]).replace("public.", ""): int(r[1]) for r in rows}


def _delta(before: dict[str, int], after: dict[str, int]) -> dict[str, int]:
    return {k: after[k] - before[k] for k in after if after[k] - before[k]}


def _as(conn: psycopg.Connection[Any], user: str) -> None:
    """The rest of this transaction's statements as the API's session at aal2 (until a reset)."""
    claims = json.dumps({"sub": user, "role": "authenticated", "aal": "aal2"})
    conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
    conn.execute("set local role authenticated")
    conn.execute("set local statement_timeout = '8s'")


class _Reads:
    """The rows each measured read took from the watched tables, and its bound."""

    def __init__(self, conn: psycopg.Connection[Any]) -> None:
        self.conn = conn
        self.rows: dict[str, dict[str, int]] = {}
        self.bounds: dict[str, int] = {}
        self.before: dict[str, int] = {}

    def start(self) -> None:
        self.before = _rows(self.conn)

    def stop(self, name: str, advances: int, only: tuple[str, ...] | None = None) -> None:
        """The reads since start(), bounded at `advances` advances; with `only`, the tables
        outside it printed apart (earlier slices' statements), not bounded."""
        got = _delta(self.before, _rows(self.conn))
        self.rows[name] = {k: v for k, v in got.items() if only is None or k in only}
        self.bounds[name] = PER_ADVANCE * advances + SLACK
        if only is not None and any(k not in only for k in got):
            self.rows[f"{name} (earlier slices' reads)"] = {
                k: v for k, v in got.items() if k not in only
            }
            self.bounds[f"{name} (earlier slices' reads)"] = 10**9

    def call(self, name: str, advances: int, user: str | None, sql: str, *params: Any) -> Any:
        """`sql`'s single value, as `user` (the API's session) or the worker's role, measured."""
        self.start()
        if user is None:
            self.conn.execute("set role postgres")
        else:
            _as(self.conn, user)
        value = one(self.conn, sql, params)
        self.conn.execute("reset role")
        self.stop(name, advances)
        return value

    def check(self) -> None:
        lines = [f"{n}: {r} (bound {self.bounds[n]})" for n, r in self.rows.items()]
        print(
            f"\n{LOT}-member lot short of one, {K} covers, {PLANTED} rows planted per table (two"
            " values of each key, n_distinct 2), generic plans — rows read from the planted"
            " tables:\n  " + "\n  ".join(lines)
        )
        over = {n: r for n, r in self.rows.items() if sum(r.values()) > self.bounds[n]}
        assert over == {}, over


def _book_short(conn: psycopg.Connection[Any], lot: dict[str, Any]) -> list[str]:
    """The lot's line short of one member booked as the API's session books it: the runs."""
    conn.execute("set role postgres")
    line, _left = _insert_short_line(conn, lot)
    conn.execute("reset role")
    _as(conn, lot["tenant"]["staff"])
    opts = one(conn, "select public.transfer_line_options(%s)", (line,))
    (proposal,) = opts["proposals"]
    res = one(
        conn,
        "select public.book_transfer_line(%s, %s, %s, %s, %s)",
        (
            str(uuid.uuid4()),
            line,
            Jsonb(proposal["request"]),
            proposal["preview"]["expected_text"],
            REASON,
        ),
    )
    conn.execute("reset role")
    assert len(res["bookings"]) == LOT - 1, res
    runs = conn.execute(
        "select id from public.remittance_run where id = any(%s::uuid[]) and status = 'booked'",
        (lot["paid"],),
    ).fetchall()
    return [str(r[0]) for r in runs]


def _take_back(conn: psycopg.Connection[Any], lot: dict[str, Any]) -> list[dict[str, str]]:
    """The planted statistics, every plan generic, the line booked; then « Désimputer » (ops) of
    one collection of each of K booked runs: each posts its cover at once (an advance of that
    run's client, on its mandate). What each took back."""
    _plant(conn)
    conn.execute("set local plan_cache_mode = force_generic_plan")
    taken = []
    for run in _book_short(conn, lot)[:K]:
        payment, account, entry, client = conn.execute(
            """select l.payment_id, l.account_id, l.ledger_entry_id, l.client_organization_id
               from public.remittance_line l
               where l.run_id = %s and not l.released and l.kind = 'allocation'
               order by l.line_no limit 1""",
            (run,),
        ).fetchone() or (None, None, None, None)
        entries = one(
            conn,
            """select array_agg(x.id order by x.id) from public.ledger_entry x
               where x.payment_id = %s and x.entry_type = 'allocation' and x.account_id = %s
                 and not exists (select 1 from public.ledger_entry r
                                 where r.reverses_entry_id = x.id)""",
            (payment, account),
        )
        _as(conn, lot["tenant"]["staff"])
        out = one(
            conn,
            "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
            (str(uuid.uuid4()), payment, account, entries, "Imputation erronée (test)"),
        )
        conn.execute("reset role")
        assert len(out["advances"]) == 1, out  # remitted and booked: covered at once
        advance = one(
            conn,
            "select a.id from public.client_advance a where a.cause_entry_id = %s",
            (out["reversals"][0],),
        )
        taken.append(
            {
                "run": run,
                "payment": str(payment),
                "entry": str(entry),
                "client": str(client),
                "advance": str(advance),
            }
        )
    return taken


def test_the_advance_reads_stay_keyed_whatever_the_statistics(lot: dict[str, Any]) -> None:
    """The SQL helpers, the pages, the item's settlement, the night's advance checks, « Passer en
    perte » and transfer_line_check's advance_in_flight rule, on K advances under the planted
    statistics: a few rows per advance, never the planted ones."""
    tenant = lot["tenant"]
    ops, admin, org = tenant["staff"], tenant["admin"], lot["org"]
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        reads = _Reads(conn)
        a0 = _take_back(conn, lot)[0]
        adv, client = a0["advance"], a0["client"]
        # the advance's helpers (SQL functions: generic plans in PostgreSQL 17)
        for name in ("advance_open", "advance_born_on", "advance_mandate", "advance_recovery"):
            reads.call(name, 1, None, f"select private.{name}(%s)", adv)
        today = "private.paris_today()"
        reads.call("client_opening_on", 1, None, f"select private.client_opening_on(%s, {today})",
                   client)  # fmt: skip
        # (M2c-7c-1 review round 2) the opening 7c-1's client payments read: a proceeding_opened or
        # a liquidation (plan §6.2.2), by the same index
        reads.call("client_opening_date", 1, None,
                   f"select private.client_opening_date(%s, {today})", client)  # fmt: skip
        reads.call("document_open", 1, None, "select private.document_open(%s)", adv)
        reads.call("advance_row", 1, None, "select private.advance_row(%s)", adv)
        # the pages (the API's session)
        page = reads.call("client_advances", K, ops,
                          "select public.client_advances(%s, null, false)", org)  # fmt: skip
        assert len(page["rows"]) == K, page
        reads.call("client_advances (one client)", 1, ops,
                   "select public.client_advances(%s, %s)", org, client)  # fmt: skip
        space = reads.call("client_space_advances", 1, ops,
                           "select public.client_space_advances(%s)", client)  # fmt: skip
        assert len(space["rows"]) == 1, space
        reads.call("allocation_remitted", 1, ops,
                   "select public.allocation_remitted(%s)", a0["payment"])  # fmt: skip
        reads.call("remittance_run_payout", 1, ops,
                   "select public.remittance_run_payout(%s)", a0["run"])  # fmt: skip
        # the item's settlement (the nightly's depth detail, the « Désimputer » read)
        reads.call("item_settled_at", 1, None, "select private.item_settled_at(%s, %s, 0)",
                   a0["entry"], a0["run"])  # fmt: skip
        # the night's advance checks (the servicer's first night: the full pass)
        conn.execute("set role postgres")
        one(conn, "select private.run_payment_checks(%s)", (org,))
        conn.execute("reset role")
        # M2c-7e-1 (R3, ADR-0014 « M2c-7e-1 »): measured in a check run of its own, still
        # open — the night's run is finished (its rows refused), and since 7e-1 this servicer's
        # nightly writes one: it owes the dedicated account its advances and has no own account
        # (top_up_account_missing). Review round 1 of 7e-1 (TUI-6): the full pass asked for, as
        # before — with the night's run finished, an unasked pass would be the delta one
        check_run = one(conn, "insert into public.payment_check_run (organization_id) "
                              "values (%s) returning id", (org,))  # fmt: skip
        reads.call("run_advance_checks", K, None,
                   "select private.run_advance_checks(%s, %s, null, true)",
                   check_run, org)  # fmt: skip
        # « Passer en perte » (an admin): the command, its settlement's guard, the checks
        doc = one(
            conn,
            """insert into public.document (organization_id, client_organization_id, kind,
                 storage_path, sha256, mime_type)
               values (%s, %s, 'advance_write_off_evidence', %s, repeat('a', 64),
                       'application/pdf')
               returning id""",
            (org, client, f"client/test/{uuid.uuid4()}.pdf"),
        )
        open_minor = one(conn, "select private.advance_open(%s)", (adv,))
        out = reads.call(
            "write_off_advance", 1, admin,
            "select public.write_off_advance(%s, %s, '1,00', %s, 'Motif (test)', %s)",
            str(uuid.uuid4()), adv, str(open_minor), doc,
        )  # fmt: skip
        assert int(out["open_after_minor"]) == int(open_minor) - 100, out
        # (M2c-7c-1 review round 1, MONEY-1) the loss to recover as « Ce que le client doit au
        # cabinet » and a client's payment read it: what is left to recover, and whether the client
        # may repay it on the day (private.document_client_payable, per loss); (review round 4)
        # the day the loss was passed, its write-off settlements read by the advance's key — a
        # payment of an earlier day is no recovery
        owes = reads.call("client_open_documents (a loss to recover)", 2, ops,
                          "select public.client_open_documents(%s, 'EUR')", client)  # fmt: skip
        assert [(w["id"], w["available_minor"], w["payable"]) for w in owes["written_off"]] == [
            (adv, "100", True)
        ], owes
        recoveries = reads.call(
            "client_payment_recoveries", 1, None,
            """select private.client_payment_recoveries(%s, 'EUR', array[%s]::uuid[],
                                                         private.paris_today())""",
            client, adv,
        )  # fmt: skip
        paris_day = one(conn, "select private.paris_today()::text")
        assert recoveries == [
            {
                "id": adv,
                "available": "100",
                "payable": True,
                "written_off_on": paris_day,
                "open_on": True,
            }
        ], recoveries
        preview = reads.call(
            "client_payment_preview (a recovery)", 2, ops,
            "select public.client_payment_preview(%s, 'EUR', '1,00', null, array[%s]::uuid[])",
            client, adv,
        )  # fmt: skip
        assert [(r["document_kind"], r["amount_minor"]) for r in preview["rows"]] == [
            ("written_off", "100")
        ], preview
        # transfer_line_check's advance_in_flight rule: a PL/pgSQL statement by its variable,
        # here prepared (generic) under the function's settings
        conn.execute("set local enable_seqscan = off")
        conn.execute(
            """prepare in_flight (uuid) as
               select exists (select 1 from public.client_advance a
                              cross join lateral private.advance_in_flight_run(a.id) f
                              where a.cause_entry_id = $1 and a.cause = 'double_payout')"""
        )
        reads.call("transfer_line_check: advance_in_flight", 1, None,
                   f"execute in_flight('{uuid.uuid4()}')")  # fmt: skip
        conn.execute("reset enable_seqscan")
    reads.check()


def test_the_claw_back_s_prepare_and_approval_read_by_key_whatever_the_statistics(
    lot: dict[str, Any],
) -> None:
    """The worker's prepare of a client's draft (its reversal and its cover), as its role reads
    it under the planted statistics — its loader, the open advances, the unplanned payouts'
    attributions — the draft written, then its approval (ops' command, the job: the documents'
    re-check reads the advance, the line insert guard puts the cover's item on its mandate): 7b's
    reads a few rows per advance. Before the round, the loader read every planted client_advance
    row (twice: its items' advances by a hash of the table, its open advances by a sequential
    scan) and every planted unplanned_paid_item row of the two bookings asked."""
    ops = lot["tenant"]["staff"]
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        reads = _Reads(conn)
        a0 = _take_back(conn, lot)[0]
        _as(conn, ops)
        draft = one(conn, "select public.request_remittance_run(%s, %s, 'EUR')",
                    (str(uuid.uuid4()), a0["client"]))["run_id"]  # fmt: skip
        conn.execute("reset role")
        token = one(conn, "select job_token from public.remittance_run where id = %s", (draft,))
        conn.execute("set role postgres")  # the worker's role
        reads.start()
        facts = load_facts(conn, str(draft), str(token))
        reads.stop("load_facts", 1, SEVEN_B)
        assert facts is not None and [a.id for a in facts.open_advances] == [a0["advance"]]
        reads.start()
        assert [a.id for a in _open_advances(conn, a0["client"], "EUR")] == [a0["advance"]]
        reads.stop("_open_advances", 1)
        reads.start()  # (a booking of ours that paid nothing: none of the planted rows is its)
        assert _unplanned_paid(conn, [str(uuid.uuid4()) for _ in range(8)]) == []
        reads.stop("_unplanned_paid", 0)
        reads.start()
        assert write_draft(conn, str(draft), str(token), prepare_run(facts))
        reads.stop("write_draft", 1, SEVEN_B)
        conn.execute("reset role")
        head = conn.execute(
            "select inputs_hash, net_minor from public.remittance_run where id = %s", (draft,)
        ).fetchone()
        assert head is not None
        item = {"run_id": str(draft), "inputs_hash": head[0], "net_text": str(head[1])}
        _as(conn, ops)
        approved = one(conn, "select public.approve_remittance_runs(%s, %s, null, null)",
                       (str(uuid.uuid4()), json.dumps([item])))  # fmt: skip
        conn.execute("reset role")
        assert [r["status"] for r in approved["results"]] == ["queued"], approved
        token = one(conn, "select job_token from public.remittance_run where id = %s", (draft,))
        conn.execute("set role postgres")
        reads.start()
        one(conn, "select private.approve_remittance_run(%s, %s)", (str(draft), str(token)))
        conn.execute("set constraints all immediate")
        conn.execute("set constraints all deferred")
        reads.stop("approve_remittance_run (the job)", 1, SEVEN_B)
        conn.execute("reset role")
        status = one(conn, "select status from public.remittance_run where id = %s", (draft,))
        assert status == "approved", status
    reads.check()


def _plant_servicer_advances(conn: psycopg.Connection[Any], org: str) -> None:
    """(M2c-7c-1, ADR-0014 7b round 2 « Left open ») PLANTED advances of the lot's own servicer to
    two other clients (no trigger, no foreign key: they name no entry of ours), client_advance
    analysed with its client column's n_distinct pinned at 2 and its servicer column's at -1 (the
    statistics of a table analysed while each servicer had a few advances): the servicer's index,
    priced at one row, then returns every one of them; the client's index a handful."""
    conn.execute("set local session_replication_role = replica")
    conn.execute("alter table public.client_advance disable trigger client_advance_guard")
    conn.execute(
        """insert into public.client_advance (organization_id, client_organization_id, currency,
             amount_minor, cause, cause_entry_id, entry_id)
           select %s, k.client[1 + g %% 2], 'EUR', 100, 'double_payout', gen_random_uuid(),
                  gen_random_uuid()
           from (select (array[gen_random_uuid(), gen_random_uuid()]) client) k,
                generate_series(1, %s) g""",
        (org, PLANTED),
    )
    conn.execute("alter table public.client_advance enable always trigger client_advance_guard")
    conn.execute("set local session_replication_role = origin")
    conn.execute(
        "alter table public.client_advance alter column organization_id set (n_distinct = -1)"
    )
    conn.execute(
        "alter table public.client_advance alter column client_organization_id set (n_distinct = 2)"
    )
    conn.execute("analyze public.client_advance")


def test_the_client_space_reads_its_client_s_advances_by_its_key(lot: dict[str, Any]) -> None:
    """(M2c-7c-1, the 7b round 2 verifier's item) public.client_space_advances read its client's
    advances unfenced, the client and the servicer together: with PLANTED of the servicer's
    advances to other clients and generic plans, one client's space read them all through the
    servicer's index (10,005 rows on 7b's body). Read on client_advance_client_idx, the servicer
    checked outside the fence (as private.client_open_advances): a few rows per advance."""
    tenant = lot["tenant"]
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        reads = _Reads(conn)
        a0 = _take_back(conn, lot)[0]
        _plant_servicer_advances(conn, lot["org"])
        space = reads.call("client_space_advances (the servicer's other clients planted)", 1,
                           tenant["staff"], "select public.client_space_advances(%s)",
                           a0["client"])  # fmt: skip
        assert [r["advance_id"] for r in space["rows"]] == [a0["advance"]], space
    reads.check()
