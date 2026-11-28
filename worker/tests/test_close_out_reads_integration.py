# ruff: noqa: E501 - SQL fixtures read better unwrapped
"""M2c-7f-1 (needs `make up`; ADR-0014 « M2c-7f-1 », plan docs/design/m2c-7f-plan.md §2): the reads the
close-out hardening redefines or adds stay keyed whatever the statistics — the plan class that broke main
after 7a and again in PR #50's CI round (a per-row read by a parameter key whose filter implies a partial
index's predicate; a function without enable_seqscan off; a multi-column partial index losing to a
single-column index under a correlated organization_id). Each test plants stale statistics in its own
rolled-back transaction (the `*_reads_integration.py` files' plants: `_plant`, `_servicer_unseen`) and bounds
the rows read (pg_stat_xact_*: sequential reads and the index entries returned). Each fails on the bodies
7f-1 replaces (their latest definitions, read from the migration files where a test runs them side by side).

- H3, H4, H5, H6 (`test_the_servicers_lines_are_read_by_their_kinds_whatever_the_correlation`): PR #50's plant
  (the servicer unseen by the analyse, organization_id in the heap's order) and the servicer's own lines of
  every kind, mixed — the nightly's probes (private.run_payment_checks: debit_unclassified's three branches,
  duplicate_unresolved; private.run_transfer_checks' other_debit read; run_advance_checks' label read) read
  their kinds' lines only; the funds pass's candidates (private.bank_booking_candidates) at most their limit
  per branch; « Débits et retours » (public.debit_queue, its four tabs) at most two rows per candidate line
  per probed table; the funds pass's review replacement (private.apply_bank_bookings) the reviews it writes.
- H1 (`test_the_nightly_reads_refunds_and_transfers_by_key_under_forgotten_statistics`): PR #40's forgotten
  statistics — the nightly's refund_request and bank_transfer reads by key, never a scan per row or of every
  servicer's transfers.
- H19 (`test_an_in_flight_runs_overdue_lines_are_read_by_the_runs_key`): the remitted-cover file's plant (two
  runs holding every line, run_id's n_distinct 2) — private.inflight_overdue_lines reads each run in flight's
  lines by the run's key alone.
- CI round, PR #52 (`test_the_servicers_flight_is_read_by_its_key_without_statistics`): bank_transfer with no
  statistics and its flight index bloated (the db job's state at test_declarations_reads) — what is needed
  (private.top_up_needed) reads the servicer's sweeps and top-ups in flight of the currency only, never a whole
  partial index of the transfers in flight or of the top-ups (every servicer's) nor the servicer's other transfers
  in flight; the nightly's advance checks and the whole nightly within their bounds (round 2: again beside the
  servicer's booked sweeps and top-ups).
- CI round, PR #52, round 2 (`test_the_servicers_top_up_reads_are_keyed_per_call_without_statistics`,
  `test_no_partial_index_of_the_transfers_is_read_without_its_key`): the same state, with and without the servicer's
  booked past and a run's payouts in flight — « Approvisionnements », « Générer le fichier (compte propre) »,
  « Rattacher à TOP… », a line's « remplace le fichier » check and each account's transfers in flight read their own
  key's rows per call, their results the same; no partial index of bank_transfer is read without its key.
"""

from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timedelta
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import one, storage
from reconciliation_helpers import pay
from remittance_helpers import (
    add_admin,
    own_account,
    paris_today,
    recent_business_day,
    remittance_tenant,
)
from test_advance_reads_integration import (
    _plant_servicer_advances,
    _Reads,
    _take_back,
    lot,  # noqa: F401 - the module's fixture, shared
)
from test_client_payment_reads_integration import WATCHED as CP_WATCHED
from test_client_payment_reads_integration import (
    _as,
    owing,  # noqa: F401 - the module's fixture, shared
)
from test_client_payment_reads_integration import _plant as _plant_payments
from test_client_payments_integration import REASON as CP_REASON
from test_label_reference_reads_integration import (
    WATCHED,
    _own_lines,
    _plant,
    _servicer_unseen,
    held,  # noqa: F401 - the module's fixture, shared
)
from test_remitted_cover_reads_integration import _lines_read
from test_remitted_cover_reads_integration import _plant as _plant_lines
from test_top_up_reads_integration import LISTED
from test_top_up_reads_integration import owing as topped  # noqa: F401 - 7e-1's fixture, shared
from test_transfer_cancellation_scale_integration import (
    PARIS,
    _backdate,
    _credits,
    _file,
    _refund,
    _statement,
)
from test_transfer_cancellation_scale_integration import _as as _as_user

from collectoo_worker.jobs.debits import _process_funds_lines
from collectoo_worker.jobs.remittances import load_facts, write_draft
from collectoo_worker.remittance.run import prepare_run

pytestmark = pytest.mark.integration
PER_CALL = 60
# the servicer's own lines of each kind the probes read (copies of one of its lines under other keys)
PER_KIND = 10
KINDS = (
    ("credit", "return", None),
    ("debit", "refund_out", None),
    ("debit", "suspected_duplicate", None),
    ("debit", "transfer_out", None),
    ("credit", "own_transfer_in", None),
    ("credit", "client_transfer_in", None),
    ("debit", "other_debit", None),
    # a batch line of our files: no end-to-end id, our PmtInfId (the funds pass's and the queue's batch branch)
    ("debit", "other_debit", "TF-2026-000001-1"),
)
# other servicers' lines of each of KINDS, planted before the analyse
OTHERS_PER_KIND = 500
# the funds pass's candidates asked at a time in the test (its six branches each limited so)
LIMIT = 500
CANDIDATE_BRANCHES = 6


def _own_kinds(
    conn: psycopg.Connection[Any], line: str, per_kind: int = PER_KIND, others: bool = False
) -> None:
    """`per_kind` lines of each of KINDS (copies of `line` under other keys, five days old: each probe's age passed):
    the servicer's, after the analyse (the statistics know none of them); or (`others`) two other servicers', before
    it — every kind's index then holds live lines of other servicers, as a database in use does (after the db job's
    pgTAP files, a kind's index holds only the dead entries of their rolled-back fixtures: priced on its few live
    lines, it lost to the servicer's index)."""
    conn.execute("set local session_replication_role = replica")
    always = [
        r[0]
        for r in conn.execute(
            """select t.tgname from pg_trigger t where t.tgrelid = 'public.bank_transaction'::regclass
                 and not t.tgisinternal and t.tgenabled = 'A'"""
        ).fetchall()
    ]
    for t in always:
        conn.execute(f"alter table public.bank_transaction disable trigger {t}")
    tag, base = ("o", 400000) if others else ("", 300000)
    other = (
        " 'organization_id', k.org[1 + g %% 2], 'bank_account_id', k.org[2 - g %% 2], 'statement_id', k.org[1 + g %% 2],"
        if others
        else ""
    )
    for n, (direction, kind, pmt_inf) in enumerate(KINDS):
        conn.execute(
            f"""insert into public.bank_transaction
               select (jsonb_populate_record(null::public.bank_transaction, to_jsonb(x)
                        || jsonb_build_object('id', md5('closeout-kind-{tag}{n}-' || g)::uuid,
                             'line_no', {base} + {n} * {per_kind} + g, 'dedup_key', 'h:closeout-kind-{tag}{n}-' || g,
                             'kind', %s::text, 'direction', %s::text,{other}
                             'reference_from_label', null, 'end_to_end_id', null, 'original_end_to_end_id', null,
                             'payment_info_id', %s::text, 'amount_minor', 1000 + g,
                             'booking_date', current_date - 5))).*
               from (select q.* from public.bank_transaction q where q.id = '{line}') x,
                    (select (array[gen_random_uuid(), gen_random_uuid()]) org) k,
                    generate_series(1, {per_kind}) g""",  # noqa: S608 - the tests' own constants
            (kind, direction, pmt_inf),
        )
    for t in always:
        conn.execute(f"alter table public.bank_transaction enable always trigger {t}")
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


def _delta(before: dict[str, int], after: dict[str, int]) -> dict[str, int]:
    return {k: after[k] - before[k] for k in after if after[k] - before[k]}


def _kinds(conn: psycopg.Connection[Any], org: str) -> dict[str, int]:
    """The servicer's lines per kind (a batch line counted apart)."""
    return {
        str(k): int(n)
        for k, n in conn.execute(
            """select case when direction = 'debit' and end_to_end_id is null and payment_info_id is not null
                           then 'batch' else kind end, count(*)
               from public.bank_transaction where organization_id = %s group by 1""",
            (org,),
        ).fetchall()
    }


def test_the_servicers_lines_are_read_by_their_kinds_whatever_the_correlation(  # noqa: PLR0915
    held: dict[str, Any],  # noqa: F811 - the shared fixture
) -> None:
    tenant, lines = held["tenant"], held["lines"]
    org, user = str(tenant["servicer"]), str(tenant["staff"])
    measured: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _own_kinds(conn, lines[0], OTHERS_PER_KIND, others=True)  # before _plant's analyse
        _plant(conn, held["rmt"], lines[0])
        _servicer_unseen(conn, org)
        _own_lines(conn, lines[0])
        _own_kinds(conn, lines[0])
        kinds = _kinds(conn, org)
        own = sum(kinds.values())
        keyed = int(
            one(
                conn,
                """select (select count(*) from public.payment where organization_id = %s)
                          + (select count(distinct bank_transaction_id) from public.bank_line_booking
                             where organization_id = %s)""",
                (org, org),
            )
        )
        transfers = int(
            one(
                conn, "select count(*) from public.bank_transfer where organization_id = %s", (org,)
            )
        )
        # (T2, ADR-0014 « M2c-7e-2 — CI round (PR #50) », Left open) an untimed arm first: the same plans and
        # caches for the measured one; (7f-1 review round 1, CC-1) then the same with every plan generic
        for name, mode in (
            ("run_payment_checks", None),
            ("run_payment_checks (generic)", "force_generic_plan"),
        ):
            with conn.transaction(force_rollback=True):
                if mode:
                    conn.execute(f"set local plan_cache_mode = {mode}")
                conn.execute("select private.run_payment_checks(%s)", (org,))
            before = _rows(conn)
            with conn.transaction(force_rollback=True):
                if mode:
                    conn.execute(f"set local plan_cache_mode = {mode}")
                conn.execute("set local role postgres")  # the nightly job's role
                conn.execute("select private.run_payment_checks(%s)", (org,))
            measured[name] = _delta(before, _rows(conn))
        before = _rows(conn)
        cands = one(
            conn,
            "select count(*) from private.bank_booking_candidates(%s, null, null, %s)",
            (org, LIMIT),
        )
        measured["bank_booking_candidates"] = _delta(before, _rows(conn))
        # « Débits et retours », its four tabs, as ops reads them (the API's session at aal2)
        for tab in ("a-classer", "doublons", "frais", "traites"):
            before = _rows(conn)
            with conn.transaction(force_rollback=True):
                _as(conn, user)
                listed = one(conn, "select count(*) from public.debit_queue(%s, 0, 100)", (tab,))
                conn.execute("reset role")
            measured[f"debit_queue ({tab}: {listed} listed)"] = _delta(before, _rows(conn))
        # the debit job's whole funds pass (the worker's reads and the SQL): its reviews replaced by key
        before = _rows(conn)
        with conn.transaction(force_rollback=True):
            conn.execute("set local role postgres")  # the worker's role (its temporary tables)
            summary = _process_funds_lines(conn, org, None)
        measured["funds pass"] = _delta(before, _rows(conn))
    print(
        f"\nthe servicer's {own} lines ({kinds}) and {transfers} transfers, unseen by the analyse, organization_id"
        f" correlated; generic plans off unless named — rows read:\n  "
        + "\n  ".join(f"{n}: {r}" for n, r in measured.items())
    )
    # H3: each of the nightly's probes reads the lines of its kinds only — debit_unclassified's branches (debit
    # kinds, own kinds read by an index holding label_reference too, other_debit), duplicate_unresolved (by the
    # debit kinds' index), run_transfer_checks' other_debit, run_advance_checks' label lines — plus one keyed read
    # per payment and per booked line, plus PER_CALL; before 7f, five probes read every line of the servicer
    debit_kinds = sum(kinds.get(k, 0) for k in ("return", "refund_out", "suspected_duplicate"))
    own_kinds = sum(
        kinds.get(k, 0)
        for k in ("transfer_out", "own_transfer_in", "client_transfer_in", "label_reference")
    )
    other = kinds.get("other_debit", 0) + kinds.get("batch", 0)
    probes = 2 * debit_kinds + own_kinds + 2 * other + kinds.get("label_reference", 0)
    for arm in ("run_payment_checks", "run_payment_checks (generic)"):
        night = measured[arm].get("bank_transaction", 0)
        assert night <= probes + keyed + PER_CALL, (arm, night, probes, keyed, kinds, measured)
        # (7f-1 review round 1, CC-1) the nightly's transfers by key: a few reads per transfer of the servicer
        # (private.run_transfer_checks' sweeps, payouts and refunds in flight and private.transfers_in_flight by
        # the servicer's key; before, per paying account, a status- or kind-only scan of every servicer's
        # transfers in flight), plus PER_CALL
        flown = measured[arm].get("bank_transfer", 0)
        assert flown <= PER_ROW * transfers + PER_CALL, (arm, flown, transfers, measured)
    # H4: the funds pass's candidates, each branch at most its limit, plus PER_CALL
    assert cands <= LIMIT, cands
    read = measured["bank_booking_candidates"].get("bank_transaction", 0)
    assert read <= CANDIDATE_BRANCHES * (LIMIT + PER_CALL), (read, kinds, measured)
    assert read < own, (read, own)  # never every line of the servicer
    # H5: « Débits et retours » — every probed table at most two rows per candidate line of the servicer (the
    # lines of the queue's kinds), the lines themselves at most four times (an other debit is a candidate of
    # three branches: our batch lines, a pending refund's amount, rule 3b), plus PER_CALL; never another
    # servicer's planted rows (before 7f: the review, link, release and resolution tables read whole)
    candidates = debit_kinds + own_kinds + other
    for name, rows in measured.items():
        if name.startswith("debit_queue"):
            for table, n in rows.items():
                bound = (4 if table == "bank_transaction" else 2) * candidates + PER_CALL
                assert n <= bound, (name, table, n, bound, measured)
    # H6: the funds pass writes its reviews and replaces the earlier ones by key — the review table read at
    # most twice per review written, plus PER_CALL (before 7f: a hash join over the planted reviews)
    reviews = int(summary.get("reviews", 0))
    assert reviews > 0, summary
    review_reads = measured["funds pass"].get("bank_debit_review", 0)
    assert review_reads <= 2 * reviews + PER_CALL, (review_reads, reviews, measured)


# H19 -----------------------------------------------------------------------------------------------------------------
def test_an_in_flight_runs_overdue_lines_are_read_by_the_runs_key(
    lot: dict[str, Any],  # noqa: F811 - the shared fixture
) -> None:
    """The night's in-flight check (private.inflight_overdue_lines: each run approved or sent whose payout is not
    booked, its live lines overdue) under the remitted-cover file's plant: two runs holding every line of
    remittance_line, one of them released, run_id's n_distinct 2. Each run's lines by the run's key alone (the
    7a CI round's form, its conditions outside the fence): at most the runs' own lines, plus PER_CALL — before
    7f, `not released` in the fenced filter implied remittance_line_live_uq's predicate and every planted live
    line was read once per run in flight (ADR-0014 « M2c-7a — CI round (main) », Left open: 10,048 for one run)."""
    org = str(lot["org"])
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant_lines(conn)
        runs, own = conn.execute(
            """select count(distinct r.id), count(l.*)
               from public.remittance_run r left join public.remittance_line l on l.run_id = r.id
               where r.organization_id = %s and r.status in ('approved', 'sent')""",
            (org,),
        ).fetchone() or (0, 0)
        assert runs >= 1, runs
        conn.execute("set local plan_cache_mode = force_generic_plan")
        conn.execute("set role postgres")  # the nightly job's role
        before = _lines_read(conn)
        late = one(
            conn,
            "select count(*) from private.inflight_overdue_lines(%s, %s)",
            (org, paris_today() + timedelta(days=60)),
        )
        read = _lines_read(conn) - before
        conn.execute("reset role")
    print(
        f"\n{runs} runs in flight ({own} lines), every planted line live in two runs: {read} remittance_line"
        f" rows read, {late} lines overdue"
    )
    assert late > 0, late  # the runs' lines read, and overdue that far on
    assert read <= own + PER_CALL, (read, own, runs)


# H1 (PR #40's statistics) ----------------------------------------------------------------------------------------------
# refund_request and bank_transfer forgotten (never analysed), a probe of a key index priced at 1,000 pages: what made
# the nightly read refund_request once per payment by a scan (ADR-0014 « M2c-6b-3b part 3 — CI round (PR #40) », Left
# open: 1.7 million rows for 640 payments) and bank_transfer by a scan of every servicer's transfers
FORGOTTEN = ("bank_transfer", "refund_request", "transfer_file_item", "transfer_file")
PROBE_PAGES = 1_000
# other servicers' refund requests planted (no foreign key, no trigger): the table a scan per payment reads
OTHERS = 2_000
PAYMENTS = 60
REFUNDS = 40
PER_ROW = 12


def _raw(conn: psycopg.Connection[Any], table: str, sql: str) -> None:
    """`sql` (an insert into `table`) without its triggers or foreign keys, in `conn`'s transaction only."""
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
    conn.execute(sql)
    for t in always:
        conn.execute(f"alter table {table} enable always trigger {t}")
    conn.execute("set local session_replication_role = origin")


def test_the_nightly_reads_refunds_and_transfers_by_key_under_forgotten_statistics() -> None:
    tenant = remittance_tenant()
    org = str(tenant["servicer"])
    pay(tenant, storage(), _credits(PAYMENTS), prefix="F", start=recent_business_day(back=10), days=1,
        allocate=False)  # fmt: skip
    assert _refund(tenant, REFUNDS) == REFUNDS
    _file(tenant, REFUNDS)
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _raw(
            conn,
            "public.refund_request",
            f"""insert into public.refund_request
               select (jsonb_populate_record(null::public.refund_request, to_jsonb(q)
                        || jsonb_build_object('id', gen_random_uuid(), 'organization_id', gen_random_uuid(),
                             'payment_id', gen_random_uuid(), 'transfer_id', null, 'execution_mode', 'manual',
                             'bank_account_id', gen_random_uuid(),
                             'end_to_end_id', 'RFD' || upper(substr(md5('closeout-other-' || g), 1, 12)),
                             'idempotency_key', 'closeout-other-' || g))).*
               from (select r.* from public.refund_request r where r.organization_id = '{org}' limit 1) q,
                    generate_series(1, {OTHERS}) g""",  # noqa: S608 - the tests' own constants
        )
        # and as many other servicers' transfers (copies of one of the servicer's refunds under other keys): what a
        # scan of bank_transfer reads beyond the servicer's own
        _raw(
            conn,
            "public.bank_transfer",
            f"""insert into public.bank_transfer
               select (jsonb_populate_record(null::public.bank_transfer, to_jsonb(t)
                        || jsonb_build_object('id', gen_random_uuid(), 'organization_id', gen_random_uuid(),
                             'debtor_bank_account_id', gen_random_uuid(), 'transfer_file_id', null,
                             'status', 'ordered', 'entry_id', null, 'return_entry_id', null,
                             'end_to_end_id', 'RFD' || upper(substr(md5('closeout-transfer-' || g), 1, 12))))).*
               from (select x.* from public.bank_transfer x where x.organization_id = '{org}' limit 1) t,
                    generate_series(1, {OTHERS}) g""",  # noqa: S608 - the tests' own constants
        )
        # (M2c-7f-1, H1) and their files (copies of the servicer's under other keys): with the file side priced as a
        # database in use has it, the failed-file probe's join read every servicer's ordered transfers
        # (bank_transfer_to_file_idx) to find the servicer's failed files
        _raw(
            conn,
            "public.transfer_file",
            f"""insert into public.transfer_file
               select (jsonb_populate_record(null::public.transfer_file, to_jsonb(f)
                        || jsonb_build_object('id', gen_random_uuid(), 'organization_id', gen_random_uuid(),
                             'debtor_bank_account_id', gen_random_uuid(),
                             'number', 'TF-2099-' || lpad((900000 + g)::text, 7, '0'),
                             'msg_id', 'CLOSEOUT' || upper(substr(md5('closeout-file-' || g), 1, 20)),
                             'storage_path', 'closeout/planted-file-' || g || '.xml'))).*
               from (select x.* from public.transfer_file x where x.organization_id = '{org}' limit 1) f,
                    generate_series(1, {OTHERS}) g""",  # noqa: S608 - the tests' own constants
        )
        conn.execute("set local session_replication_role = origin")
        owned, payments = conn.execute(
            """select (select count(*) from public.bank_transfer where organization_id = %s),
                      (select count(*) from public.payment where organization_id = %s)""",
            (org, org),
        ).fetchone() or (0, 0)
        stored = one(conn, "select count(*) from public.bank_transfer")
        for t in FORGOTTEN:
            conn.execute("delete from pg_statistic where starelid = %s::regclass", (f"public.{t}",))
            conn.execute(
                "update pg_class set reltuples = -1, relpages = 0 where oid = %s::regclass",
                (f"public.{t}",),
            )
        conn.execute(f"set local random_page_cost = {PROBE_PAGES}")

        def reads() -> dict[str, int]:
            return {
                str(r[0]): int(r[1])
                for r in conn.execute(
                    """select relname, coalesce(idx_tup_fetch, 0) + seq_tup_read from pg_stat_xact_user_tables
                       where relid in ('public.refund_request'::regclass, 'public.bank_transfer'::regclass)"""
                ).fetchall()
            }

        conn.execute("set role postgres")
        before = reads()
        run = one(conn, "select private.run_payment_checks(%s)", (org,))
        after = reads()
        conn.execute("reset role")
    work = {k: after[k] - before.get(k, 0) for k in after}
    print(
        f"\n{payments} payments, {REFUNDS} refunds in a downloaded file, {OTHERS} other servicers' requests;"
        f" the servicer's {owned} transfers of {stored}: the night read {work} ({run['by_code']})"
    )
    # refund_request by the payment's and the transfer's keys: a few rows per payment and transfer, never a scan
    # of the table per row
    assert work.get("refund_request", 0) <= PER_ROW * (payments + owned) + PER_CALL, (
        work,
        payments,
        owned,
    )
    # bank_transfer by the servicer's keys: a few rows per transfer it owns, never every servicer's transfers
    assert work.get("bank_transfer", 0) <= PER_ROW * owned + PER_CALL, (work, owned, stored)


# H20 -----------------------------------------------------------------------------------------------------------------
def test_the_prepare_and_the_approval_read_every_table_by_key_whatever_the_statistics(
    lot: dict[str, Any],  # noqa: F811 - the shared fixture
) -> None:
    """7b round 2's claw-back prepare and approval (test_advance_reads_integration.py's steps and plants: 10,000 rows
    per table over two values of each key, n_distinct 2, every plan generic), every table now bounded — 7b bounded
    its own statements only and printed the earlier slices' reads (ADR-0014 « M2c-7b review fixes, round 2 », Left
    open): the loader's pending items by draft (remittance_pending 10,013), its terms by mandate (mandate_terms
    10,098), the blockers (client_status_event 10,000), write_draft's remittance_pending (10,006) and the approval
    job's (remittance_pending 20,012, client_status_event 10,000, mandate_terms 10,099). Each call: a few rows per
    advance, plus the slack."""
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
        reads.stop("load_facts", 1)
        assert facts is not None and [a.id for a in facts.open_advances] == [a0["advance"]]
        reads.start()
        assert write_draft(conn, str(draft), str(token), prepare_run(facts))
        reads.stop("write_draft", 1)
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
        reads.stop("approve_remittance_run (the job)", 1)
        conn.execute("reset role")
        status = one(conn, "select status from public.remittance_run where id = %s", (draft,))
        assert status == "approved", status
    reads.check()


# H11, H16, H22 -------------------------------------------------------------------------------------------------------
DOCUMENTS = 10_000


def test_the_proofs_the_totals_and_the_match_reads_are_keyed_whatever_the_statistics(
    owing: dict[str, Any],  # noqa: F811 - the shared fixture
) -> None:
    """7c-1's plant (test_client_payment_reads_integration.py: 10,000 rows per table it reads, the servicer's own
    entries and invoices for other clients among them, n_distinct 2, every plan generic) and DOCUMENTS proofs of
    the client (its payment and refund evidence, each its own file; the statistics pinned at two values per key) and 5,000 settled advances of the servicer (7b round 2's plant): « Règlement du client » and « Enregistrer
    le remboursement » read the client's proofs of the same file by their key (H11: evidence_already_used — the
    proof's document, then the entries naming it, by their source's partial index), « Avances »' totals and the chip
    (H16: public.client_advance_totals) the servicer's 4112[c] / 419[c] accounts' postings only, and « Lier »'s
    files (H22: public.match_queue_accounts, the client's mandate's end by its key) a few rows per file."""
    tenant = owing["tenant"]
    org, client, ops = str(tenant["servicer"]), str(tenant["client"]), str(tenant["staff"])
    measured: dict[str, dict[str, int]] = {}
    watched = (*CP_WATCHED, "public.document", "public.ledger_posting", "public.ledger_account")
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant_payments(conn, org)
        _plant_servicer_advances(conn, org)
        _raw(
            conn,
            "public.document",
            f"""insert into public.document (organization_id, client_organization_id, kind, storage_path, sha256,
                  mime_type)
               select '{org}', case when g % 3 = 0 then gen_random_uuid() else '{client}'::uuid end,
                      case when g % 2 = 0 then 'client_payment_evidence' else 'client_refund_evidence' end,
                      'client/planted/' || g || '.pdf', encode(sha256(convert_to('planted-' || g, 'UTF8')), 'hex'),
                      'application/pdf'
               from generate_series(1, {DOCUMENTS}) g""",  # noqa: S608 - the tests' own constants
        )
        for key, n in (("client_organization_id", 2), ("sha256", 2), ("kind", 2)):
            conn.execute(f"alter table public.document alter column {key} set (n_distinct = {n})")
        conn.execute("analyze public.document")
        conn.execute("set local plan_cache_mode = force_generic_plan")

        def rows() -> dict[str, int]:
            got = conn.execute(
                """select t.relid::regclass::text,
                          coalesce(pg_stat_get_xact_tuples_returned(t.relid), 0)
                          + coalesce((select sum(pg_stat_get_xact_tuples_returned(i.indexrelid))
                                      from pg_index i where i.indrelid = t.relid), 0)
                   from (select unnest(%s::regclass[]) relid) t""",
                (list(watched),),
            ).fetchall()
            return {str(r[0]).replace("public.", ""): int(r[1]) for r in got}

        def call(name: str, user: str, sql: str, *params: Any) -> Any:
            before = rows()
            with conn.transaction():
                _as(conn, user)
                value = one(conn, sql, params)
                conn.execute("reset role")
            measured[name] = _delta(before, rows())
            return value

        paid = call(
            "record_client_payment",
            ops,
            """select public.record_client_payment(%s, %s, 'EUR', '365,00', private.paris_today(), %s, null, null,
                                                   null, '36000', %s)""",
            str(uuid.uuid4()),
            client,
            owing["evidence"],
            CP_REASON,
        )
        credit = one(
            conn, "select id from public.client_credit where entry_id = %s", (paid["entry_id"],)
        )
        call(
            "record_client_refund",
            ops,
            """select public.record_client_refund(%s, %s, '5,00', private.paris_today(), %s, '500', %s)""",
            str(uuid.uuid4()),
            credit,
            owing["refund_evidence"],
            CP_REASON,
        )
        totals = call("client_advance_totals", ops, "select public.client_advance_totals(%s)", org)
        # (review round 1, TEST-H16-CLIENT-ADVANCES) « Avances » itself: the servicer's first page and the client's,
        # their totals from the same balances (before 7f-1: Σ advance_open over every advance of the servicer)
        first = call(
            "client_advances (the servicer's, one row)",
            ops,
            "select public.client_advances(%s, null, true, null, 1)",
            org,
        )
        theirs = call(
            "client_advances (the client's)",
            ops,
            "select public.client_advances(%s, %s)",
            org,
            client,
        )
        accounts = conn.execute(
            "select array_agg(id) from public.account where organization_id = %s", (org,)
        ).fetchone()
        files = call(
            "match_queue_accounts",
            ops,
            "select count(*) from public.match_queue_accounts(%s::uuid[])",
            (accounts or [None])[0],
        )
        postings = one(
            conn,
            """select count(*) from public.ledger_posting p join public.ledger_account a on a.id = p.ledger_account_id
               where a.organization_id = %s and a.book in ('client_advance_receivable', 'client_credit_owed')""",
            (org,),
        )
    print(
        f"\n{DOCUMENTS} proofs planted, 7c-1's plant, 5,000 settled advances of the servicer — rows read:\n  "
        + "\n  ".join(f"{n}: {r}" for n, r in measured.items())
        + f"\n  (totals {totals}; {files} files; {postings} postings on 4112/419)"
    )
    # H11: the proofs of the same file by the client's key and the SHA-256 (two of them here: the command's own
    # and none other recorded), the entries naming each by the unique index — never the client's planted proofs
    for name in ("record_client_payment", "record_client_refund"):
        assert measured[name].get("document", 0) <= PER_CALL, (name, measured)
    # H16: the servicer's 4112[c] and 419[c] accounts and their postings only — never its advances one by one
    assert measured["client_advance_totals"].get("client_advance", 0) <= PER_CALL, measured
    assert sum(measured["client_advance_totals"].values()) <= 2 * postings + PER_CALL, (
        postings,
        measured,
    )
    # (review round 1, TEST-H16-CLIENT-ADVANCES) « Avances »: the page's advances (and the one after it) and a
    # few reads each, plus PER_CALL — never every advance of the servicer for its totals
    assert first["totals"] == totals["advances"], (first, totals)
    for name, page in (
        ("client_advances (the servicer's, one row)", first),
        ("client_advances (the client's)", theirs),
    ):
        shown = len(page["rows"]) + 1
        assert measured[name].get("client_advance", 0) <= PER_ROW * shown + PER_CALL, (
            name,
            shown,
            measured,
        )
    # H22: each file's client's mandate's end by the client's key
    assert measured["match_queue_accounts"].get("client_status_event", 0) <= PER_CALL, measured


# H1 (7c-1's plant: the servicer's invoices read by the night's statements) -----------------------------------------
SCAN_RE = re.compile(
    r"(?:Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan)(?: using \S+)? on (\w+)"
)
ACTUAL_RE = re.compile(r"actual time=[\d.]+\.\.[\d.]+ rows=(\d+) loops=(\d+)")
REMOVED_RE = re.compile(r"Rows Removed by (?:Filter|Index Recheck): (\d+)")


def _plans(conn: psycopg.Connection[Any], sql: str, *params: Any) -> list[str]:
    """Every statement's plan `sql` runs, nested ones included, as auto_explain logs them (sent to this session)."""
    plans: list[str] = []

    def keep(diag: psycopg.errors.Diagnostic) -> None:
        if diag.message_primary and "plan:" in diag.message_primary:
            plans.append(diag.message_primary)

    conn.add_notice_handler(keep)
    try:
        with conn.transaction():
            for setting, value in (
                ("auto_explain.log_min_duration", "0"),
                ("auto_explain.log_analyze", "on"),
                ("auto_explain.log_nested_statements", "on"),
                ("auto_explain.log_level", "notice"),
                ("client_min_messages", "notice"),
            ):
                conn.execute(f"set local {setting} = '{value}'")
            conn.execute(sql, params)
    finally:
        conn.remove_notice_handler(keep)
    return plans


def _reads_of(plan: str, table: str) -> list[tuple[str, int, int]]:
    """Each scan of `table` in a statement's plan: its alias, the rows it read (its rows and the rows it removed,
    times its loops) and its loops."""
    nodes = []
    lines = plan.split("\n")
    for k, line in enumerate(lines):
        m = SCAN_RE.search(line)
        if m is None or m.group(1) != table:
            continue
        a = ACTUAL_RE.search(line)
        if a is None:
            continue
        rows, loops = int(a.group(1)), int(a.group(2))
        removed = 0
        for nxt in lines[k + 1 : k + 4]:
            r = REMOVED_RE.search(nxt)
            if r is not None:
                removed += int(r.group(1))
        alias = line.split(f" on {table} ", 1)[-1].split(" ", 1)[0]
        nodes.append((alias, (rows + removed) * loops, loops))
    return nodes


# other servicers' invoices (their own clients, mandates and entries), planted after 7c-1's analyse: what a read of
# the table by anything but the servicer's key reads beyond the servicer's own
OTHER_INVOICES = 2_000

# the sub-checks of the night's remittance checks (private.run_remittance_runs_checks' one statement) that read the
# servicer's invoices by design, each once: the numbering (invoice_numbering), the invoice ledger and its clients,
# the VAT pending and its three per-client sums, the commission totals (three sums), the overdue alerts — ADR-0014
# « M2c-7f-1 », H1
BY_DESIGN = 12


def test_the_nights_statements_read_the_servicers_invoices_once_each(
    owing: dict[str, Any],  # noqa: F811 - the shared fixture
) -> None:
    """7c-1's plant (the servicer's own invoices for two other clients: 10,000, n_distinct 2): its night read them
    18 times, 180,012 rows (docs/benchmarks/remittances.md, 7c-1). Attributed scan by scan (auto_explain, nested
    statements, actual rows): each scan reads them at most once — a sub-check that sums or lists the servicer's
    invoices reads each once, by design (BY_DESIGN of them, in one statement), and every per-row read is a keyed read
    of its own document (private.document_open and the like: one row each), never the servicer's invoices once per
    row of another read."""
    tenant = owing["tenant"]
    org = str(tenant["servicer"])
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant_payments(conn, org)
        # (M2c-7f-1, H1) and other servicers' invoices, unseen by the analyse: before the partial (organization_id)
        # index the pending-VAT sums read every servicer's invoices by commission_invoice_mandate_idx's second column
        _raw(
            conn,
            "public.commission_invoice",
            f"""insert into public.commission_invoice
               select (jsonb_populate_record(null::public.commission_invoice, to_jsonb(q)
                        || jsonb_build_object('id', gen_random_uuid(), 'organization_id', gen_random_uuid(),
                             'client_organization_id', gen_random_uuid(), 'mandate_id', gen_random_uuid(),
                             'ledger_entry_id', gen_random_uuid(), 'run_id', null))).*
               from (select x.* from public.commission_invoice x where x.organization_id = '{org}'
                     and x.kind = 'invoice' limit 1) q,
                    generate_series(1, {OTHER_INVOICES}) g""",  # noqa: S608 - the tests' own constants
        )
        invoices, stored = conn.execute(
            """select count(*) filter (where organization_id = %s), count(*)
               from public.commission_invoice""",
            (org,),
        ).fetchone() or (0, 0)
        assert stored >= invoices + OTHER_INVOICES, (stored, invoices)
        conn.execute("set role postgres")
        plans = _plans(conn, "select private.run_payment_checks(%s)", org)
        conn.execute("reset role")
    whole, keyed, keyed_rows = [], 0, 0
    for plan in plans:
        nodes = _reads_of(plan, "commission_invoice")
        read = sum(n for _a, n, _l in nodes)
        if read > PER_CALL:
            body = " ".join(plan.split("Query Text:", 1)[-1].split())[:120]
            whole.append((body, nodes))
        elif read:  # a per-row function's read of its own document by key
            keyed, keyed_rows = keyed + 1, keyed_rows + read
    print(
        f"\nthe servicer's {invoices} invoices of {stored}; the night's {len(plans)} statements: {keyed} keyed reads"
        f" ({keyed_rows} rows), {len(whole)} reading more than {PER_CALL}:\n  "
        + "\n  ".join(f"{b}: {[(a, n, lp) for a, n, lp in nodes if n]}" for b, nodes in whole)
    )
    assert keyed_rows <= keyed, (keyed, keyed_rows)  # one row each
    assert whole, plans[:3]
    scans = [(b, a, n, lp) for b, nodes in whole for a, n, lp in nodes if n > PER_CALL]
    for body, alias, read, loops in scans:
        assert read <= invoices + PER_CALL, (alias, read, loops, body)
    assert len(scans) <= BY_DESIGN, scans


# H8 (the audit of status-filtered updates beside a key array) --------------------------------------------------------
CURRENT_RUNS = 10_000
PER_RUN_READ = 12


def test_the_funds_pass_books_runs_by_key_beside_every_servicers_current_runs(
    lot: dict[str, Any],  # noqa: F811 - the shared fixture
) -> None:
    """7e-3 round 2's plant of current rows (ADR-0014 « M2c-7e-3 review fixes », round 2, Left open: « audit them in
    the 7f hardening slice »): every other servicer's runs in flight — CURRENT_RUNS approved or sent, each its own
    client, inserted after the analyse (the statistics know none of them: remittance_run_pending_uq, whose predicate
    `status in ('draft', 'approved', 'sent')` the booking's `r.status in ('approved', 'sent')` implies, is priced as
    small) — then the lot's payouts debited one line each and booked by the debit job's funds pass
    (private.bank_booking_post_rows: its remittance_run update beside the key array). The runs are read by key: a few
    rows per run booked, never every servicer's current runs."""
    org = str(lot["org"])
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        conn.execute("analyze public.remittance_run")
        _raw(
            conn,
            "public.remittance_run",
            f"""insert into public.remittance_run (id, organization_id, client_organization_id, currency, number,
                 status, trigger, known_at, approved_at)
               select gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'EUR',
                      'RV-2099-' || lpad(g::text, 6, '0'), case when g % 2 = 0 then 'approved' else 'sent' end,
                      'manual', now(), now()
               from generate_series(1, {CURRENT_RUNS}) g""",  # noqa: S608 - the tests' own constants
        )
        payouts = conn.execute(
            """select t.end_to_end_id, t.amount_minor from public.bank_transfer t
               where t.run_id = any(%s::uuid[]) and t.status = 'in_file' order by t.end_to_end_id""",
            (lot["paid"],),
        ).fetchall()
        assert payouts, lot["paid"]
        st = one(
            conn,
            """insert into public.bank_statement (organization_id, bank_account_id, currency, format, file_name,
                 file_sha256, size_bytes, storage_path)
               values (%s, %s, 'EUR', 'camt053', 'h8.xml', %s, 1, %s) returning id""",
            (org, lot["tenant"]["bank"], uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
        )
        conn.execute(
            "update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = %s",
            (st,),
        )
        for n, (e2e, amount) in enumerate(payouts, 1):
            conn.execute(
                """insert into public.bank_transaction (organization_id, bank_account_id, statement_id, line_no,
                     dedup_key, direction, amount_minor, currency, booking_date, kind, end_to_end_id)
                   values (%s, %s, %s, %s, %s, 'debit', %s, 'EUR', private.paris_today(), 'transfer_out', %s)""",
                (org, lot["tenant"]["bank"], st, n, f"t:h8-{st}-{n}", amount, e2e),
            )

        def runs_read() -> int:
            return int(
                one(
                    conn,
                    """select coalesce(pg_stat_get_xact_tuples_returned('public.remittance_run'::regclass), 0)
                              + coalesce((select sum(pg_stat_get_xact_tuples_returned(i.indexrelid)) from pg_index i
                                          where i.indrelid = 'public.remittance_run'::regclass), 0)""",
                )
            )

        before = runs_read()
        conn.execute("set role postgres")  # the worker's role (its temporary tables)
        summary = _process_funds_lines(conn, org, None)
        conn.execute("reset role")
        read = runs_read() - before
        booked = one(
            conn,
            "select count(*) from public.remittance_run where id = any(%s::uuid[]) and status = 'booked'",
            (lot["paid"],),
        )
    print(
        f"\n{CURRENT_RUNS} other runs in flight unseen by the analyse; {len(payouts)} payouts debited: {booked} runs"
        f" booked, remittance_run rows read {read} ({summary})"
    )
    assert booked == len(payouts), (booked, summary)
    assert read <= PER_RUN_READ * len(payouts) + PER_CALL, (read, len(payouts))


# H7 (a file's transfers read through its items, D12) ------------------------------------------------------------------
FILED = 80  # the servicer's refunds in its downloaded file
# other servicers' payouts, sweeps and refunds, in flight or booked, in two other files
OTHER_TRANSFERS = 10_000
# rows inserted and rolled back: the dead index entries earlier rolled-back plants leave
DEAD = 30_000
FILE_WATCHED = ("public.bank_transfer", "public.transfer_file_item", "public.remittance_run")
# each statement of a call reads each item's own transfer (and the item) once by key: the release after a download
# reads each 16 times (its lock, its loop, its updates, the re-issue and its guard), the two-step confirmation 26 (its
# evidence, its return checks, then the release) — a few dozen rows per item, never the plant's OTHER_TRANSFERS
PER_ITEM = 32


def _file_plant(conn: psycopg.Connection[Any], file_id: str) -> None:
    """7e-1 round 2's plant (ADR-0014 « M2c-7e-1 review fixes », round 2): every other servicer's runs in flight
    (approved or sent, each its own client) unseen by the analyse, as H8 plants them; OTHER_TRANSFERS other
    servicers' transfers (copies of one of the file's refunds under other keys: payouts of their runs, sweeps and
    refunds; in a file, ordered or booked) in two other files, with their items; DEAD transfers and DEAD items
    inserted with a file and rolled back (a subtransaction), the dead index entries rolled-back plants leave; then
    bank_transfer and transfer_file_item analysed with their keys' n_distinct pinned at 2 (a file's transfers priced
    at half the table); then as many of their transfers cancelled out of a file, unseen by the analyse."""
    conn.execute("analyze public.remittance_run")
    _raw(
        conn,
        "public.remittance_run",
        f"""insert into public.remittance_run (id, organization_id, client_organization_id, currency, number,
             status, trigger, known_at, approved_at)
           select gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'EUR',
                  'RV-2098-' || lpad(g::text, 6, '0'), case when g % 2 = 0 then 'approved' else 'sent' end,
                  'manual', now(), now()
           from generate_series(1, {CURRENT_RUNS}) g""",  # noqa: S608 - the tests' own constants
    )
    template = one(
        conn,
        "select id from public.bank_transfer where transfer_file_id = %s order by id limit 1",
        (file_id,),
    )
    _raw(
        conn,
        "public.bank_transfer",
        f"""insert into public.bank_transfer
           select (jsonb_populate_record(null::public.bank_transfer, to_jsonb(t)
                    || jsonb_build_object('id', md5('closeout-h7-' || g)::uuid, 'organization_id', k.org[1 + g % 2],
                         'debtor_bank_account_id', k.acct[1 + g % 2],
                         'kind', case g % 3 when 0 then 'sweep' when 1 then 'payout' else 'refund' end,
                         'creditor_bank_account_id', case g % 3 when 0 then gen_random_uuid() end,
                         'client_organization_id', case g % 3 when 1 then gen_random_uuid() end,
                         'run_id', case g % 3 when 1 then gen_random_uuid() end,
                         'status', case when g % 2 = 0 then 'in_file' when g % 4 = 1 then 'ordered'
                                        else 'booked' end,
                         'transfer_file_id', case when g % 4 <> 1 then k.f[1 + g % 2] end,
                         'entry_id', case when g % 4 = 3 then gen_random_uuid() end,
                         'replaces_transfer_id', null, 'return_entry_id', null,
                         'end_to_end_id', case g % 3 when 0 then 'SWP' when 1 then 'RMT' else 'RFD' end
                           || 'F' || upper(lpad(to_hex(g), 11, '0'))))).*
           from (select array[gen_random_uuid(), gen_random_uuid()] org,
                        array[gen_random_uuid(), gen_random_uuid()] acct,
                        array[gen_random_uuid(), gen_random_uuid()] f) k,
                (select q.* from public.bank_transfer q where q.id = '{template}') t,
                generate_series(1, {OTHER_TRANSFERS}) g""",  # noqa: S608 - the tests' own constants
    )
    _raw(
        conn,
        "public.transfer_file_item",
        f"""insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id,
             execution_date)
           select t.transfer_file_id, row_number() over (partition by t.transfer_file_id order by t.id), t.id,
                  t.organization_id, 'TF-2098-H7', current_date
           from public.bank_transfer t
           where t.id in (select md5('closeout-h7-' || g)::uuid from generate_series(1, {OTHER_TRANSFERS}) g)
             and t.transfer_file_id is not null""",  # noqa: S608 - the tests' own constants
    )
    with conn.transaction(force_rollback=True):
        _raw(
            conn,
            "public.bank_transfer",
            f"""insert into public.bank_transfer
               select (jsonb_populate_record(null::public.bank_transfer, to_jsonb(t)
                        || jsonb_build_object('id', gen_random_uuid(), 'status', 'booked',
                             'entry_id', gen_random_uuid(), 'transfer_file_id', gen_random_uuid(),
                             'end_to_end_id', 'RFDE' || upper(lpad(to_hex(g), 11, '0'))))).*
               from (select q.* from public.bank_transfer q where q.id = '{template}') t,
                    generate_series(1, {DEAD}) g""",  # noqa: S608 - the tests' own constants
        )
        # and as many items of other files, rolled back: the file's key indexes of transfer_file_item bloated too
        _raw(
            conn,
            "public.transfer_file_item",
            f"""insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id,
                 execution_date)
               select gen_random_uuid(), 1, gen_random_uuid(), gen_random_uuid(), 'TF-2098-H7D', current_date
               from generate_series(1, {DEAD}) g""",  # noqa: S608 - the tests' own constants
        )
    for table, keys in (
        ("public.bank_transfer", ("transfer_file_id", "organization_id", "debtor_bank_account_id")),
        ("public.transfer_file_item", ("file_id", "transfer_id")),
    ):
        for key in keys:
            conn.execute(f"alter table {table} alter column {key} set (n_distinct = 2)")
        conn.execute(f"analyze {table}")
    # and as many of their transfers cancelled out of their files since, unseen by the analyse (a database whose
    # statistics know few cancellations): bank_transfer_cancelled_filed_idx's predicate, which a re-issue's check of its
    # predecessor implies, is priced as nearly empty
    _raw(
        conn,
        "public.bank_transfer",
        f"""insert into public.bank_transfer
           select (jsonb_populate_record(null::public.bank_transfer, to_jsonb(t)
                    || jsonb_build_object('id', gen_random_uuid(), 'organization_id', k.org[1 + g % 2],
                         'debtor_bank_account_id', k.acct[1 + g % 2], 'status', 'cancelled',
                         'transfer_file_id', k.f[1 + g % 2], 'cancelled_at', now(),
                         'cancel_reason', 'Fichier retiré (test)', 'entry_id', null,
                         'end_to_end_id', 'RFDC' || upper(lpad(to_hex(g), 11, '0'))))).*
           from (select array[gen_random_uuid(), gen_random_uuid()] org,
                        array[gen_random_uuid(), gen_random_uuid()] acct,
                        array[gen_random_uuid(), gen_random_uuid()] f) k,
                (select q.* from public.bank_transfer q where q.id = '{template}') t,
                generate_series(1, {OTHER_TRANSFERS}) g""",  # noqa: S608 - the tests' own constants
    )


def _file_rows(conn: psycopg.Connection[Any]) -> dict[str, int]:
    rows = conn.execute(
        """select t.relid::regclass::text,
                  coalesce(pg_stat_get_xact_tuples_returned(t.relid), 0)
                  + coalesce((select sum(pg_stat_get_xact_tuples_returned(i.indexrelid))
                              from pg_index i where i.indrelid = t.relid), 0)
           from (select unnest(%s::regclass[]) relid) t""",
        (list(FILE_WATCHED),),
    ).fetchall()
    return {str(r[0]).replace("public.", ""): int(r[1]) for r in rows}


def test_a_files_transfers_are_read_through_its_items_whatever_the_statistics() -> None:  # noqa: PLR0915
    """H7 (ADR-0014 « M2c-7e-1 review fixes », round 2, Left open: « 7f's hardening measures them and moves them to
    the items »; D12): under 7e-1 round 2's plant (_file_plant) the payout files' commands and helpers that read a
    file's transfers — private.transfer_file_release (its sweeps cancelled, its payouts and refunds re-issued after a
    download, the switch on: private.bank_transfer_guard's re-issue check, the rest ordered again, its runs back to
    approved), « Marquer comme déposé » (public.mark_transfer_file_sent: its runs sent), the line's « remplace le
    fichier » check (private.transfer_line_supersedes, enable_seqscan off as public.transfer_line_preview runs it),
    « Annuler le fichier » before the download (public.cancel_transfer_file: private.transfer_file_lock_runs, then the
    release), whether the bank executed the file (private.transfer_file_executed: « Télécharger » again, « Marquer
    comme déposé »), the switch-on two-step cancellation (public.request_transfer_file_cancellation, then
    public.confirm_transfer_file_cancellation by another admin, each with private.transfer_cancel_evidence; the switch
    on in rolled-back subtransactions only) and private.transfer_line_locks' read of a late predecessor's file (its
    statement, with the function's enable_seqscan off: by `transfer_file_id` it took bank_transfer_filed_amount_idx
    whole) — read the file's items and each one's transfer by its key: a few rows per item, never every servicer's
    transfers, items or runs."""
    tenant = remittance_tenant()
    admin = add_admin(tenant)
    org = str(tenant["servicer"])
    d0 = recent_business_day(back=20)
    sid = pay(tenant, storage(), _credits(FILED), prefix="H", start=d0, days=1, allocate=False)
    assert _refund(tenant, FILED) == FILED
    filed = _file(tenant, FILED)
    with psycopg.connect(ADMIN) as conn:
        x = one(
            conn,
            """select min(c.day) from public.business_calendar c
               where c.scope = 'FR-conservative' and not c.closed and c.day > %s""",
            (d0 + timedelta(days=2),),
        )
        y = one(conn, "select private.next_business_day(%s)", (x,))
        opening = one(
            conn, "select closing_booked_minor from public.bank_statement where id = %s", (sid,)
        )
    # time moved on (as the cancellation tests): the file dated back to X, a statement of X and Y produced after them
    # shows no debit — the evidence the two-step cancellation asks for
    with psycopg.connect(ADMIN) as conn, conn.transaction():
        _backdate(conn, filed, x)
        _statement(
            conn, tenant, start=d0 + timedelta(days=1), end=y, opening=int(opening), debits=[],
            created=datetime.combine(y + timedelta(days=1), datetime.min.time(), PARIS) + timedelta(hours=9),
        )  # fmt: skip
    measured: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _file_plant(conn, filed)
        conn.execute("set local plan_cache_mode = force_generic_plan")
        stored = one(conn, "select count(*) from public.bank_transfer")
        version = one(conn, "select version from public.transfer_file where id = %s", (filed,))
        line = one(
            conn,
            "select id from public.bank_transaction where organization_id = %s limit 1",
            (org,),
        )

        def call(name: str, step: Any, keep: bool = False) -> Any:
            before = _file_rows(conn)
            with conn.transaction(force_rollback=not keep):
                value = step()
            measured[name] = _delta(before, _file_rows(conn))
            return value

        def switch_on() -> None:
            conn.execute(
                "update private.feature_switch set enabled = true"
                " where key = 'downloaded_file_cancellation'"
            )

        def release() -> Any:
            switch_on()  # a downloaded file is released only with the switch on (transfer_file_guard)
            conn.execute("set local role postgres")
            v = one(
                conn,
                "select private.transfer_file_release(%s, 'superseded', 'test', null, null)",
                (filed,),
            )
            conn.execute("reset role")
            return v

        def sent() -> Any:
            return _as_user(
                conn, tenant["staff"], "select public.mark_transfer_file_sent(%s, %s, %s) ->> 'status'",
                str(uuid.uuid4()), filed, version,
            )  # fmt: skip

        def generated() -> None:
            # the file not downloaded yet (generated), as before its first download
            conn.execute("alter table public.transfer_file disable trigger transfer_file_guard")
            conn.execute(
                "update public.transfer_file set status = 'generated', download_count = 0,"
                " first_downloaded_at = null where id = %s",
                (filed,),
            )
            conn.execute(
                "alter table public.transfer_file enable always trigger transfer_file_guard"
            )

        def supersedes() -> Any:
            # a line's parts to book (a bank charge): the check reads the servicer's generated files' sweeps
            generated()
            conn.execute(
                """create temp table _tl (kind text, amount bigint, adv bigint, tr_client uuid, tr_run uuid)
                   on commit drop"""
            )
            conn.execute("insert into pg_temp._tl values ('fee', 100, 0, null, null)")
            conn.execute("set local enable_seqscan = off")
            return one(conn, "select private.transfer_line_supersedes(%s)", (line,))

        def executed() -> Any:
            # « Télécharger » again and « Marquer comme déposé » ask whether the bank executed the file
            conn.execute("set local role postgres")
            value = one(conn, "select private.transfer_file_executed(%s)", (filed,))
            conn.execute("reset role")
            return value

        def lock_runs() -> Any:
            # as public.cancel_transfer_file calls it (no enable_seqscan of its own)
            conn.execute("set local role postgres")
            one(conn, "select private.transfer_file_lock_runs(%s)", (filed,))
            conn.execute("reset role")
            return True

        def cancel() -> Any:
            # « Annuler le fichier » before its download (the switch off): its transfers ordered again
            generated()
            v = one(conn, "select version from public.transfer_file where id = %s", (filed,))
            return _as_user(
                conn, admin, "select public.cancel_transfer_file(%s, %s, %s, 'Annulé (test)')",
                str(uuid.uuid4()), filed, v,
            )  # fmt: skip

        def request() -> Any:
            return _as_user(
                conn, tenant["staff"],
                """select public.request_transfer_file_cancellation(%s, %s, %s, 'Fichier non déposé (test)',
                     'not_uploaded') ->> 'status'""",
                str(uuid.uuid4()), filed, version,
            )  # fmt: skip

        def confirm() -> Any:
            return _as_user(
                conn, admin, "select public.confirm_transfer_file_cancellation(%s, %s, %s)",
                str(uuid.uuid4()), filed, version,
            )  # fmt: skip

        def late_file() -> Any:
            conn.execute("set local enable_seqscan = off")
            # its read of a late predecessor's file not downloaded yet (its body as M2c-7f-1 copies it: the file's
            # items, each transfer by its key)
            conn.execute(
                "prepare h7_late(uuid) as"
                " select x.id from public.transfer_file_item i"
                " cross join lateral (select q.id, q.transfer_file_id from public.bank_transfer q"
                " where q.id = i.transfer_id offset 0) x"
                " where i.file_id = $1 and x.transfer_file_id = $1 offset 0"
            )
            # (EXECUTE takes no bound parameter: the file id, a uuid, inlined)
            n = len(conn.execute(f"execute h7_late('{uuid.UUID(filed)}')").fetchall())
            conn.execute("deallocate h7_late")
            return n

        assert call("transfer_file_release", release) == FILED  # each refund re-issued
        assert call("mark_transfer_file_sent", sent) == "sent"
        # its generated file holds no sweep
        assert call("transfer_line_supersedes", supersedes) is None
        assert call("transfer_file_executed", executed) is False  # no debit on the statement
        assert call("transfer_file_lock_runs", lock_runs)
        cancelled = call("cancel_transfer_file (not downloaded)", cancel)
        assert (cancelled["status"], cancelled["transfers_back"]) == ("superseded", FILED), (
            cancelled
        )
        # the switch-on two-step, in a subtransaction of its own: the request kept for its confirmation
        with conn.transaction(force_rollback=True):
            switch_on()
            asked = call("request_transfer_file_cancellation", request, keep=True)
            assert asked == "requested", asked
            confirmed = call("confirm_transfer_file_cancellation", confirm)
            assert (confirmed["status"], confirmed["transfers_back"]) == ("superseded", FILED), (
                confirmed
            )
        assert call("transfer_line_locks (a late predecessor's file)", late_file) == FILED
    print(
        f"\nthe servicer's file of {FILED} refunds beside {OTHER_TRANSFERS} other servicers' transfers in two other"
        f" files ({stored} stored, {DEAD} dead entries) and {CURRENT_RUNS} other runs in flight: "
        + "; ".join(f"{k} {v}" for k, v in measured.items())
    )
    for name, rows in measured.items():
        for table in ("bank_transfer", "transfer_file_item"):
            assert rows.get(table, 0) <= PER_ITEM * FILED + PER_CALL, (name, table, rows)
        assert rows.get("remittance_run", 0) <= PER_CALL, (name, rows)


# CI round, PR #52 ----------------------------------------------------------------------------------------------------
# other servicers' transfers in flight (refunds, sweeps, top-ups of two other servicers, ordered or in a file): what a
# whole read of bank_transfer_debtor_idx (status in flight) or bank_transfer_top_up_idx (every top-up) returns
FLIGHT_OTHERS = 2_000
# the servicer's own transfers in flight that no call for its sweeps and top-ups of EUR reads: refunds on other
# accounts (ordered or in a file) and sweeps of another currency
FLIGHT_OWN_OTHER = 500
FLIGHT_OWN_CHF = 50
# sweeps in flight inserted and rolled back (a subtransaction): the flight index's dead pages, as the reads tests'
# rolled-back plants left them in the db job (bank_transfer_servicer_flight_idx: 31 pages for 10 entries)
FLIGHT_DEAD = 5_000
# the servicer's sweeps and top-ups in flight (EUR): what top_up_needed sums
OWN_SWEEPS, SWEEP_MINOR = 3, 1_000
OWN_TOP_UPS, TOP_UP_MINOR = 2, 500
# bank_transfer and its indexes as the db job left them when test_declarations_reads ran (run 46054376194; reproduced
# on the second stack in CI's order): (reltuples, relpages) — vacuumed back to their live rows and entries, the pages
# of the rolled-back plants kept (M2c-7f-1's H7 file plant: 10,000 + 30,000 transfers, a third of them sweeps); the
# new key index priced as bloated as the flight index
DB_JOB_RELATIONS = {
    "bank_transfer": (199, 2_703),
    "bank_transfer_servicer_flight_idx": (10, 31),
    "bank_transfer_servicer_flight_key_idx": (10, 31),
    "bank_transfer_debtor_idx": (173, 52),
    "bank_transfer_top_up_idx": (10, 8),
    "bank_transfer_org_idx": (227, 107),
}
# (CI round, PR #52, round 2) the « big » plant's servicer past and present, as 7e-1's OWN_HISTORY plants an account's:
# FLIGHT_HISTORY booked sweeps and top-ups (half each, between its dedicated and its own account, long executed) —
# what a key without the status reads (round 1's key index without its status column: 5,008 rows per sum) — and
# FLIGHT_PAYOUTS payouts in flight on its dedicated account (a big run's, half ordered, half in a file)
FLIGHT_HISTORY = 5_000
FLIGHT_PAYOUTS = 5_000


def _flight_plant(
    conn: psycopg.Connection[Any],
    tenant: dict[str, Any],
    own: str,
    history: int = 0,
    payouts: int = 0,
) -> None:
    """FLIGHT_DEAD sweeps inserted and rolled back (the flight index's dead pages); the servicer's sweeps and top-ups
    in flight, its other transfers in flight, other servicers' (no trigger, no foreign key); (round 2) `history`
    booked sweeps and top-ups of the servicer and `payouts` payouts of its in flight on its dedicated account; then
    bank_transfer's statistics as the db job had them: none (the table never analysed outside the reads tests'
    rolled-back transactions; autovacuum's analyse came after), the table and its indexes priced as it left them."""
    org, bank, iban = str(tenant["servicer"]), str(tenant["bank"]), str(tenant["iban"])
    prefix = "case z.kind when 'refund' then 'RFD' when 'sweep' then 'SWP' else 'TOP' end"

    # (tag, rows, servicer, kinds, debtor, creditor, currency, amount, statuses), each an SQL expression but the tag,
    # the rows, the currency and the amount; `k.k` two other keys (servicers or accounts), `g` the row
    plants = (
        ("sweep", OWN_SWEEPS, f"'{org}'::uuid", "array['sweep']", f"'{bank}'::uuid", f"'{own}'::uuid",
         "EUR", SWEEP_MINOR, "array['ordered']"),
        ("top", OWN_TOP_UPS, f"'{org}'::uuid", "array['top_up']", f"'{own}'::uuid", f"'{bank}'::uuid",
         "EUR", TOP_UP_MINOR, "array['ordered']"),
        ("own", FLIGHT_OWN_OTHER, f"'{org}'::uuid", "array['refund']", "k.k[1 + g % 2]", "null::uuid",
         "EUR", 100, "array['ordered', 'in_file']"),
        ("chf", FLIGHT_OWN_CHF, f"'{org}'::uuid", "array['sweep']", "k.k[1 + g % 2]", "gen_random_uuid()",
         "CHF", 100, "array['ordered', 'in_file']"),
        ("other", FLIGHT_OTHERS, "k.k[1 + g % 2]", "array['refund', 'sweep', 'top_up']", "gen_random_uuid()",
         "gen_random_uuid()", "EUR", 100, "array['ordered', 'in_file']"),
    )  # fmt: skip
    for tag, n, servicer, kinds, debtor, creditor, currency, amount, statuses in (
        ("dead", FLIGHT_DEAD, "k.k[1 + g % 2]", "array['sweep']", "gen_random_uuid()", "gen_random_uuid()",
         "EUR", 100, "array['ordered']"),
        *plants,
    ):  # fmt: skip
        with conn.transaction(force_rollback=tag == "dead"):
            _raw(
                conn,
                "public.bank_transfer",
                f"""insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id,
                     creditor_bank_account_id, currency, amount_minor, payee_name, payee_iban, end_to_end_id,
                     requested_execution_date, status, transfer_file_id)
                   select {servicer}, z.kind, {debtor}, case when z.kind in ('sweep', 'top_up') then {creditor} end,
                          '{currency}', {amount}, 'Plant', '{iban}',
                          {prefix} || upper(substr(md5('ci52-{tag}-' || g), 1, 12)), current_date, z.status,
                          case when z.status = 'in_file' then gen_random_uuid() end
                   from (select array[gen_random_uuid(), gen_random_uuid()] k) k, generate_series(1, {n}) g,
                        lateral (select ({kinds})[1 + g % cardinality({kinds})] as kind,
                                        ({statuses})[1 + g % cardinality({statuses})] as status) z""",  # noqa: S608
            )
    if history:
        # the servicer's past: booked sweeps (dedicated → own) and top-ups (own → dedicated), each with its entry
        _raw(
            conn,
            "public.bank_transfer",
            f"""insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id,
                 creditor_bank_account_id, currency, amount_minor, payee_name, payee_iban, end_to_end_id,
                 requested_execution_date, status, transfer_file_id, entry_id, created_at)
               select '{org}'::uuid, z.kind, case z.kind when 'sweep' then '{bank}'::uuid else '{own}'::uuid end,
                      case z.kind when 'sweep' then '{own}'::uuid else '{bank}'::uuid end, 'EUR', 100, 'Plant',
                      '{iban}', case z.kind when 'sweep' then 'SWP' else 'TOP' end
                        || upper(substr(md5('ci52-hist-' || g), 1, 12)), current_date - 30, 'booked',
                      gen_random_uuid(), gen_random_uuid(), now() - make_interval(days => 30, secs => g)
               from generate_series(1, {history}) g,
                    lateral (select case when g % 2 = 0 then 'sweep' else 'top_up' end as kind) z""",  # noqa: S608
        )
    if payouts:
        # the servicer's payouts in flight on its dedicated account (half ordered, half in a file)
        _raw(
            conn,
            "public.bank_transfer",
            f"""insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id,
                 client_organization_id, currency, amount_minor, payee_name, payee_iban, end_to_end_id,
                 requested_execution_date, status, transfer_file_id)
               select '{org}'::uuid, 'payout', '{bank}'::uuid, '{tenant["client"]}'::uuid, 'EUR', 100, 'Plant',
                      '{iban}', 'RMT' || upper(substr(md5('ci52-pay-' || g), 1, 12)), current_date,
                      case when g % 2 = 0 then 'ordered' else 'in_file' end,
                      case when g % 2 = 1 then gen_random_uuid() end
               from generate_series(1, {payouts}) g""",  # noqa: S608
        )
    # (round 2) bank_transfer_org_idx rebuilt on the plant's rows (in this transaction: rolled back with it). The planner
    # prices a whole index by its file's pages, which the earlier tests' rolled-back plants leave at any size: after a
    # few, the servicer's whole read through it priced above the bloated flight index and the old bodies' reads stayed
    # keyed by chance (43 rows for top_up_overview in the module's order, 1,702 on a fresh database); rebuilt, it is
    # the plant's size whatever ran before, as the db job's was its rows' (107 pages)
    conn.execute("reindex index public.bank_transfer_org_idx")
    conn.execute("delete from pg_statistic where starelid = 'public.bank_transfer'::regclass")
    for relation, (tuples, pages) in DB_JOB_RELATIONS.items():
        conn.execute(
            "update pg_class set reltuples = %s, relpages = %s where oid = to_regclass(%s)",
            (tuples, pages, f"public.{relation}"),
        )
    conn.execute("set local plan_cache_mode = force_generic_plan")


@pytest.mark.parametrize(
    "history", (0, FLIGHT_HISTORY), ids=("flight", "flight and booked history")
)
def test_the_servicers_flight_is_read_by_its_key_without_statistics(history: int) -> None:
    """(CI round, PR #52; ADR-0014 « M2c-7f-1 — CI round (PR #52) ») In run 46054376194 the nightly's advance checks
    read 209 bank_transfer rows for a servicer with two: private.top_up_needed's two sums (the servicer's sweeps,
    then its top-ups, in flight in a currency) read bank_transfer_debtor_idx and bank_transfer_top_up_idx whole —
    every servicer's transfers in flight, every servicer's top-ups — their predicates proved by the sums' constants,
    bank_transfer then without statistics and its flight index bloated by rolled-back plants. Under that state
    (_flight_plant): what is needed reads the servicer's sweeps and top-ups in flight of EUR only (a constant per
    call: never the other servicers' FLIGHT_OTHERS, nor the servicer's FLIGHT_OWN_OTHER refunds on other accounts and
    FLIGHT_OWN_CHF sweeps of another currency), its value unchanged; the nightly's advance checks the same (no
    proceeding: nothing else of bank_transfer); the whole nightly (private.run_payment_checks: run_transfer_checks'
    sweeps, payouts and refunds in flight and top-ups pending, each sweep's check by its id, the shortfall, the
    advance checks) within CC-1's bound, a few reads per transfer of the servicer (with the flight index's predicate
    not bound to the servicer's key, each sweep's check read it whole: every servicer's sweeps in flight, per sweep).
    (Round 2, item 5) Again beside FLIGHT_HISTORY booked sweeps and top-ups of the servicer: what is needed still
    reads its sweeps and top-ups in flight only (the key index without its status column read the booked ones too:
    5,008 rows per call)."""
    tenant = remittance_tenant()
    own, _iban = own_account(tenant)
    org = str(tenant["servicer"])
    measured: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _flight_plant(conn, tenant, own, history=history)
        owed = int(one(conn, "select private.servicer_owed_minor(%s, 'EUR')", (org,)))
        transfers = int(
            one(
                conn, "select count(*) from public.bank_transfer where organization_id = %s", (org,)
            )
        )

        def call(name: str, sql: str, *params: Any) -> Any:
            before = _file_rows(conn)
            with conn.transaction(force_rollback=True):
                conn.execute("set local role postgres")  # the nightly's and the hourly job's role
                value = one(conn, sql, params)
            measured[name] = _delta(before, _file_rows(conn))
            return value

        needed = call("top_up_needed", "select private.top_up_needed(%s, 'EUR')", org)
        check = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (org,),
        )
        call(
            "run_advance_checks (whole)",
            "select private.run_advance_checks(%s, %s, %s, true)",
            check,
            org,
            paris_today(),
        )
        call("run_payment_checks (whole)", "select private.run_payment_checks(%s)", org)
    print(
        f"\nthe servicer's {OWN_SWEEPS} sweeps and {OWN_TOP_UPS} top-ups in flight beside its {FLIGHT_OWN_OTHER}"
        f" refunds on other accounts, {FLIGHT_OWN_CHF} CHF sweeps, {history} booked sweeps and top-ups and"
        f" {FLIGHT_OTHERS} other servicers' transfers in flight, no statistics, generic plans — rows read: "
        + "; ".join(f"{n} {r}" for n, r in measured.items())
    )
    # the same value: Σ4679 + its sweeps in flight, less its top-ups in flight, never below 0
    assert needed == max(0, owed + OWN_SWEEPS * SWEEP_MINOR - OWN_TOP_UPS * TOP_UP_MINOR), (
        needed,
        owed,
    )
    # what is needed: the servicer's sweeps and top-ups in flight of the currency, a constant per call
    assert measured["top_up_needed"].get("bank_transfer", 0) <= PER_CALL, measured
    assert measured["run_advance_checks (whole)"].get("bank_transfer", 0) <= PER_CALL, measured
    # the whole nightly: CC-1's bound (a few reads per transfer of the servicer, never every servicer's in flight)
    nightly = measured["run_payment_checks (whole)"].get("bank_transfer", 0)
    assert nightly <= PER_ROW * transfers + PER_CALL, (nightly, transfers, measured)


# CI round, PR #52, round 2 -------------------------------------------------------------------------------------------
# the sweep of a generated payout file of the dedicated account that a line's « remplace le fichier » check weighs
SUPERSEDING_FEE = (
    100  # the line's part to book (a bank charge): what the check takes from the servicer's share
)
# what the servicer's share leaves once the fee and its other sweeps in flight are taken (a credit planted on its 4679
# account so that the threshold is this, whatever the fixture's books): a sweep of more supersedes the file
SUPERSEDING_ROOM = 1_000


def _in_file(conn: psycopg.Connection[Any], account: str) -> int:
    return int(
        one(
            conn,
            "select count(*) from public.bank_transfer where debtor_bank_account_id = %s and status = 'in_file'",
            (account,),
        )
    )


def _flight_sum(conn: psycopg.Connection[Any], org: str, kind: str) -> int:
    return int(
        one(
            conn,
            """select coalesce(sum(amount_minor), 0) from public.bank_transfer where organization_id = %s
                 and currency = 'EUR' and kind = %s and status in ('ordered', 'in_file')""",
            (org, kind),
        )
    )


def _superseding_sweep(
    conn: psycopg.Connection[Any], tenant: dict[str, Any], own: str, model: str, amount: int
) -> tuple[str, str]:
    """A payout file of the dedicated account, generated (a copy of `model`'s row under new keys), holding one sweep
    of `amount` in a file to the own account (no trigger, no foreign key): its id and number."""
    file_id, number = str(uuid.uuid4()), f"TF-2099-{uuid.uuid4().int % 10**9:09d}"
    sweep = str(uuid.uuid4())
    org, bank = str(tenant["servicer"]), str(tenant["bank"])
    _raw(
        conn,
        "public.transfer_file",
        f"""insert into public.transfer_file
           select (jsonb_populate_record(null::public.transfer_file, to_jsonb(f)
                    || jsonb_build_object('id', '{file_id}', 'debtor_bank_account_id', '{bank}',
                         'number', '{number}', 'msg_id', '{number}', 'status', 'generated',
                         'storage_path', f.storage_path || '-{file_id}',
                         'nb_of_txs', 1, 'ctrl_sum_minor', {amount}, 'download_count', 0,
                         'first_downloaded_at', null, 'first_downloaded_by', null))).*
           from public.transfer_file f where f.id = '{model}'""",  # noqa: S608 - the tests' own constants
    )
    _raw(
        conn,
        "public.bank_transfer",
        f"""insert into public.bank_transfer (id, organization_id, kind, debtor_bank_account_id,
             creditor_bank_account_id, currency, amount_minor, payee_name, payee_iban, end_to_end_id,
             requested_execution_date, status, transfer_file_id)
           values ('{sweep}', '{org}', 'sweep', '{bank}', '{own}', 'EUR', {amount}, 'Plant', '{tenant["iban"]}',
                   'SWP' || upper(substr(md5('{sweep}'), 1, 12)), current_date, 'in_file', '{file_id}')""",  # noqa: S608
    )
    _raw(
        conn,
        "public.transfer_file_item",
        f"""insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id, pmt_inf_id,
             execution_date) values ('{file_id}', 1, '{sweep}', '{org}', '{number}-1', current_date)""",  # noqa: S608
    )
    return file_id, number


@pytest.mark.parametrize(
    "big", (False, True), ids=("flight", "flight, booked history and payouts in flight")
)
def test_the_servicers_top_up_reads_are_keyed_per_call_without_statistics(  # noqa: PLR0915
    topped: dict[str, Any],  # noqa: F811 - the shared fixture
    big: bool,
) -> None:
    """(CI round, PR #52, round 2; ADR-0014 « M2c-7f-1 — CI round (PR #52) », round 2) Under round 1's state
    (_flight_plant: no bank_transfer statistics, the flight index bloated, every plan generic) and again (`big`)
    beside FLIGHT_HISTORY booked sweeps and top-ups of the servicer and FLIGHT_PAYOUTS of its payouts in flight on its
    dedicated account, on 7e-1's top-up servicer (`topped`: its fee owed, TOP1 and TOP2 in its own-account file
    generated, TOP3 ordered, the TOP1 credit and a credit without a TOP id on a statement): each read is bounded per
    call by a constant (PER_CALL) plus the rows the call lists, never the servicer's whole set nor every servicer's,
    its result the same —
    - « Approvisionnements » (public.top_up_overview): its sums of the sweeps and top-ups in flight once, by
      private.servicer_flight_minor, its count of the own account's ordered top-ups by the servicer's key, its
      latest LISTED top-ups listed (round 1: 1,705 rows; 16,746 big);
    - « Rattacher à TOP… » (public.top_up_credit_options): the servicer's top-ups in flight by its key (558; 5,558);
    - « Générer le fichier (compte propre) » (public.generate_top_up_file): its locks and its items (1,153; 11,153);
    - a line's « remplace le fichier » check (private.transfer_line_supersedes) per generated file's sweep: the
      servicer's other sweeps in flight by its key, the result on both sides of the threshold;
    - an account's transfers in a file (private.transfers_in_flight, through private.transfer_cash_position and
      directly): by its paying account and the status, one read per transfer of the account in a file, never its
      ordered ones nor the servicer's other accounts' (round 1: the servicer's transfers in a file once per account,
      281 and 277; 2,781 big);
    - what is needed (private.top_up_needed), round 1's: still PER_CALL beside the booked history."""
    tenant, own = topped["tenant"], topped["own"]
    org, user, bank = str(tenant["servicer"]), str(tenant["staff"]), str(tenant["bank"])
    measured: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _flight_plant(
            conn,
            tenant,
            own,
            history=FLIGHT_HISTORY if big else 0,
            payouts=FLIGHT_PAYOUTS if big else 0,
        )
        owed = int(one(conn, "select private.servicer_owed_minor(%s, 'EUR')", (org,)))
        sweeps, tops = _flight_sum(conn, org, "sweep"), _flight_sum(conn, org, "top_up")
        ordered = int(
            one(
                conn,
                """select count(*) from public.bank_transfer t where t.debtor_bank_account_id = %s
                     and t.kind = 'top_up' and t.status = 'ordered' and not private.top_up_credit_seen(t.id)""",
                (own,),
            )
        )
        own_top_ups = int(
            one(
                conn,
                "select count(*) from public.bank_transfer where debtor_bank_account_id = %s and kind = 'top_up'",
                (own,),
            )
        )
        # the own account's top-ups a new file takes: the ordered ones and those of its generated file (superseded),
        # never one whose credit is on a statement
        filed = one(
            conn,
            """select jsonb_build_object('n', count(*), 'sum', coalesce(sum(t.amount_minor), 0))
               from public.bank_transfer t
               where t.debtor_bank_account_id = %s and t.kind = 'top_up' and not private.top_up_credit_seen(t.id)
                 and (t.status = 'ordered'
                      or (t.status = 'in_file' and exists (select 1 from public.transfer_file f
                                                           where f.id = t.transfer_file_id
                                                             and f.status in ('pending', 'generated'))))""",
            (own,),
        )
        in_file = {"own": _in_file(conn, own), "bank": _in_file(conn, bank)}
        share = -int(
            one(
                conn,
                """select coalesce(sum(lp.amount_minor), 0) from public.ledger_account la
                   join public.ledger_posting lp on lp.ledger_account_id = la.id
                   where la.organization_id = %s and la.book = 'due_to_servicer' and la.currency = 'EUR'""",
                (org,),
            )
        )
        due = one(
            conn,
            """select id from public.ledger_account
               where organization_id = %s and book = 'due_to_servicer' and currency = 'EUR'""",
            (org,),
        )

        def call(name: str, who: str | None, sql: str, *params: Any) -> Any:
            before = _file_rows(conn)
            with conn.transaction(force_rollback=True):
                if who is None:
                    conn.execute("set local role postgres")  # the jobs' role
                else:
                    _as(conn, who)
                value = one(conn, sql, params)
            measured[name] = _delta(before, _file_rows(conn))
            return value

        needed = call("top_up_needed", None, "select private.top_up_needed(%s, 'EUR')", org)
        overview = call("top_up_overview", user, "select public.top_up_overview()")
        options = call(
            "top_up_credit_options",
            user,
            "select public.top_up_credit_options(%s)",
            topped["line3"],
        )
        made = call(
            "generate_top_up_file",
            user,
            "select public.generate_top_up_file(%s, %s)",
            str(uuid.uuid4()),
            own,
        )
        position = call(
            "transfer_cash_position (dedicated)",
            None,
            "select private.transfer_cash_position(%s)",
            bank,
        )
        flight = {
            account: call(
                f"transfers_in_flight ({account})",
                None,
                "select count(*) from private.transfers_in_flight(%s)",
                key,
            )
            for account, key in (("own", own), ("bank", bank))
        }
        # the line's check on both sides of its threshold: the sweep filed beyond what the servicer's share leaves
        # once its other sweeps in flight are executed supersedes the file. The share is raised by a credit on its 4679
        # account (no trigger) so that the threshold is SUPERSEDING_ROOM: at it, the sweep's own amount counted among
        # the others would supersede the file wrongly
        threshold = SUPERSEDING_ROOM
        credit = threshold + SUPERSEDING_FEE + sweeps - share
        supersedes: dict[int, Any] = {}
        for amount in (threshold, threshold + 1):
            with conn.transaction(force_rollback=True):
                _raw(
                    conn,
                    "public.ledger_posting",
                    f"""insert into public.ledger_posting (entry_id, line_no, ledger_account_id, amount_minor, currency,
                         effective_date)
                       values (gen_random_uuid(), 1, '{due}', {-credit}, 'EUR', current_date)""",  # noqa: S608
                )
                file_id, number = _superseding_sweep(conn, tenant, own, topped["file"], amount)
                conn.execute(
                    """create temp table _tl (kind text, amount bigint, adv bigint, tr_client uuid, tr_run uuid)
                       on commit drop"""
                )
                conn.execute(
                    "insert into pg_temp._tl values ('fee', %s, 0, null, null)", (SUPERSEDING_FEE,)
                )
                conn.execute(
                    "set local enable_seqscan = off"
                )  # as public.transfer_line_preview runs it
                before = _file_rows(conn)
                supersedes[amount] = (
                    one(conn, "select private.transfer_line_supersedes(%s)", (topped["line3"],)),
                    {"file_id": file_id, "number": number} if amount > threshold else None,
                )
                measured[f"transfer_line_supersedes ({amount})"] = _delta(before, _file_rows(conn))
    print(
        f"\n7e-1's top-up servicer under round 1's plant{' with its booked past and payouts in flight' if big else ''}"
        f" ({own_top_ups} top-ups of its own account, {in_file} in a file) — rows read: "
        + "; ".join(f"{n} {r}" for n, r in measured.items())
    )
    # the same results
    assert needed == max(0, owed + sweeps - tops), (needed, owed, sweeps, tops)
    assert overview["needed"] == [
        {
            "currency": "EUR",
            "owed_minor": str(owed),
            "owed_with_sweeps_minor": str(owed + sweeps),
            "needed_minor": str(needed),
            "surplus_minor": str(max(0, tops - max(0, owed + sweeps))),
            "own_account": overview["needed"][0]["own_account"],
        }
    ], overview["needed"]
    assert overview["needed"][0]["own_account"]["id"] == own, overview["needed"]
    [account] = overview["accounts"]
    assert (account["bank_account_id"], account["ordered_count"], account["can_generate"]) == (
        own,
        ordered,
        ordered > 0,
    ), account
    assert len(account["top_ups"]) == min(LISTED, own_top_ups), account
    assert [o["transfer_id"] for o in options["top_ups"]] == [topped["top3"]], options
    assert (made["nb_of_txs"], int(made["ctrl_sum_minor"])) == (filed["n"], filed["sum"]), (
        made,
        filed,
    )
    # no transfer of either account in a downloaded or sent file (the planted ones' files are not stored)
    assert (position["in_flight_count"], position["in_flight_minor"]) == (0, "0"), position
    assert flight == {"own": 0, "bank": 0}, flight
    for amount, (got, expected) in supersedes.items():
        assert got == expected, (amount, threshold, got, expected)
    # each read per call: a constant, plus the rows it lists (the overview's latest LISTED top-ups, the file's
    # top-ups), plus (per account) the account's transfers in a file, each read once by its key (never its ordered
    # ones, nor another account's)
    bounds = {
        "top_up_needed": PER_CALL,
        "top_up_overview": PER_CALL + LISTED,
        "top_up_credit_options": PER_CALL + PER_ROW * len(options["top_ups"]),
        "generate_top_up_file": PER_CALL + PER_ROW * int(made["nb_of_txs"]),
        "transfer_cash_position (dedicated)": PER_CALL + in_file["bank"],
        "transfers_in_flight (own)": PER_CALL + in_file["own"],
        "transfers_in_flight (bank)": PER_CALL + in_file["bank"],
        **{f"transfer_line_supersedes ({amount})": PER_CALL for amount in supersedes},
    }
    over = {
        name: (measured[name].get("bank_transfer", 0), bound)
        for name, bound in bounds.items()
        if measured[name].get("bank_transfer", 0) > bound
    }
    assert not over, (over, in_file, measured)


# (round 2, item 6) reads that name a partial index's predicate terms but not its key (each a whole read of it if
# taken): the index, the read's condition (`$1` a parameter: planned generic)
KEYLESS = (
    ("bank_transfer_to_file_idx", "x.status = 'ordered'"),
    ("bank_transfer_payout_iban_idx", "x.kind = 'payout' and x.status = 'booked'"),
    (
        "bank_transfer_payout_iban_idx",
        "x.kind = 'payout' and x.status = 'booked' and x.payee_iban = $1::text",
    ),
    (
        "bank_transfer_cancelled_filed_idx",
        "x.status = 'cancelled' and x.transfer_file_id is not null",
    ),
    (
        "bank_transfer_client_cancelled_idx",
        "x.kind = 'payout' and x.status = 'cancelled' and x.transfer_file_id is not null",
    ),
    (
        "bank_transfer_client_cancelled_idx",
        "x.kind = 'payout' and x.status = 'cancelled' and x.transfer_file_id = $1::uuid",
    ),
    ("bank_transfer_filed_amount_idx", "x.transfer_file_id = $1::uuid"),
    (
        "bank_transfer_filed_amount_idx",
        "x.transfer_file_id is not null and x.amount_minor = $1::bigint",
    ),
    ("bank_transfer_debtor_idx", "x.status in ('ordered', 'in_file')"),
    ("bank_transfer_debtor_idx", "x.status = 'in_file' and x.organization_id = $1::uuid"),
    ("bank_transfer_top_up_idx", "x.kind = 'top_up'"),
    (
        "bank_transfer_servicer_flight_idx",
        "x.kind = 'sweep' and x.status in ('ordered', 'in_file')",
    ),
    ("bank_transfer_creditor_idx", "x.status = 'ordered' and x.amount_minor = $1::bigint"),
)


def _index_names(node: dict[str, Any]) -> set[str]:
    names = {str(node["Index Name"])} if "Index Name" in node else set()
    for child in node.get("Plans", []):
        names |= _index_names(child)
    return names


def test_no_partial_index_of_the_transfers_is_read_without_its_key() -> None:
    """(CI round, PR #52, round 2, item 6; ADR-0014 « M2c-7f-1 — CI round (PR #52) », round 2) Every partial index of
    bank_transfer serves only the reads that name its key: its predicate holds its key's `is not null` (a NOT NULL
    column, or `payout ⇔ client_organization_id is not null`: the same entries), which only a condition on the key
    proves. Under round 1's state (_flight_plant: no statistics, the flight index bloated) and its functions' setting
    (enable_seqscan off), a generic plan of each KEYLESS read — its predicate's other terms, a non-key column — takes
    no partial index it names whole (before: bank_transfer_to_file_idx, bank_transfer_payout_iban_idx,
    bank_transfer_cancelled_filed_idx and bank_transfer_client_cancelled_idx could be, and
    bank_transfer_filed_amount_idx by the file's key, as 7f-1's H7 saw)."""
    tenant = remittance_tenant()
    own, _iban = own_account(tenant)
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        rows = conn.execute(
            """select c.relname, pg_get_indexdef(i.indexrelid, 1, true), pg_get_expr(i.indpred, i.indrelid, true)
               from pg_index i join pg_class c on c.oid = i.indexrelid
               where i.indrelid = 'public.bank_transfer'::regclass and i.indpred is not null order by 1"""
        ).fetchall()
        # its leading key (a column, or an expression: printed in parentheses, its `is not null` too or without them)
        unbound = [
            (name, key, pred)
            for name, key, pred in rows
            if f"{key} IS NOT NULL" not in str(pred)
            and f"{str(key).removeprefix('(').removesuffix(')')} IS NOT NULL" not in str(pred)
        ]
        _flight_plant(conn, tenant, own)
        conn.execute("set local enable_seqscan = off")
        taken = {}
        for index, condition in KEYLESS:
            plan = one(
                conn,
                f"explain (generic_plan, format json) select x.id from public.bank_transfer x where {condition}",  # noqa: S608
            )
            names = _index_names(plan[0]["Plan"])
            print(f"\n{condition}: {sorted(names)}")
            if index in names:
                taken[condition] = index
    assert len(rows) >= 12, rows
    assert not unbound and not taken, (unbound, taken)
