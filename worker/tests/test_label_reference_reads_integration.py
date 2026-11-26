# ruff: noqa: E501 - SQL fixtures read better unwrapped
"""M2c-7e-2 (needs `make up`; ADR-0014 « M2c-7e-2 »): the slice's reads by a parameter or a
correlated key stay keyed whatever the statistics — the plan class that broke main after 7a (a key
the last analyse saw with two values, priced at half the table: a sequential scan, a hash of the
whole table, a partial index whose predicate a parameter's filter implies).

In the test's rolled-back transaction the tables are planted with PLANTED rows each of: two other
servicers' transfers (bank_transfer: payouts, sweeps and top-ups of two other accounts, under other
end-to-end ids), their statement lines (bank_transaction: label_reference lines citing those ids,
our credits and transfers out, held duplicates), the held lines' resolutions (released as
label_reference: bank_duplicate_resolution), the job's reviews (bank_debit_review), their runs
(remittance_run: booked and cancelled; review round 3, the servicer's payout cited is a booked
run's) and the probes
every reader of a line makes (bank_debit_link, bank_line_booking, bank_own_credit_release: a table
of a few rows is read whole by design, cheaply, and the db job's earlier tests leave a few dozen) —
each analysed with its keys' n_distinct pinned (2); every plan generic. Then, on a servicer whose CSV
holds two credits citing its own payout and sweep (label_reference, reviewed by the debit job) and
a held duplicate of one released so: the statement import of another CSV citing a real reference,
a look-alike and another account's, several on a line (private.ingest_statement: one existence probe
per candidate — review round 1, MB-1: every one the label cites —, and one probe of its run by key
per payout of the account among them — review round 3: a booked run's payout is kept over the
others —, the refinement, the stage), the
debit job's funds pass (private.bank_booking_candidates and the
worker's decision), « Débits et retours » (public.debit_queue, « À classer » and « Doublons
possibles »), « Libérer » of a held line read label_reference (public.resolve_duplicate,
private.held_line_kind), « Classer sans comptabiliser » refused (public.link_debit:
private.link_debit_guard) — and the rows each read from the planted tables: a few per call, never
the planted rows. Three reads are bounded by what they read before this slice instead: the import
(its CSV duplicate checks read the account's and the servicer's other accounts' lines in one pass
since M2b-6) by the same import of the same lines staged without a candidate, plus PER_CALL, its
transfers read absolutely (one per candidate) and its runs too (one per payout candidate of the
account); « Débits et retours » by the body 7e-2 found, plus
PER_CALL — that body reads the servicer's lines and the review, link, release and resolution tables
whole under these statistics (review round 1, CC-1: ADR-0014 « M2c-7e-2 review fixes », Left open,
for 7f) —, the transfers its new column reads absolutely (one per listed line); the nightly's
private.run_advance_checks (the servicer's own rows whole by design) by 7e-1's body's reads in the
same transaction (read from the migration file), plus PER_CALL. The funds pass's
candidates (private.bank_booking_candidates) are measured alone; in the whole pass the review
table's reads of private.apply_bank_bookings (unchanged since M2b-6: its temporary table is never
analysed) are set apart — ADR-0014 « M2c-7e-2 », Left open."""

from __future__ import annotations

import hashlib
import uuid
from datetime import timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from debit_helpers import api
from explain_helpers import ADMIN
from integration_helpers import DB, one, storage
from psycopg.types.json import Jsonb
from remittance_helpers import paris_today
from statement_helpers import bank_tenant, drain, upload
from test_client_payment_reads_integration import _as
from test_label_references_integration import DEBTOR, _fr, _transfers

from collectoo_worker.jobs.debits import _process_funds_lines

pytestmark = pytest.mark.integration
PLANTED = 10_000
PER_CALL = 60
WATCHED = (
    "public.bank_transfer",
    "public.bank_transaction",
    "public.bank_duplicate_resolution",
    "public.bank_debit_review",
    "public.bank_debit_link",
    "public.bank_line_booking",
    "public.bank_own_credit_release",
    "public.payment",
    "public.remittance_run",
)
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"
MIGRATIONS = Path(__file__).resolve().parents[2] / "supabase/migrations"
BEFORE_7E2 = (
    "20261129090000_top_ups.sql",
    "create or replace function private.run_advance_checks(",
)
QUEUE_BEFORE_7E2 = ("20261117110000_transfer_line_pages.sql", "create function public.debit_queue(")
QUEUE_TABS = (
    ("debit_queue (à classer)", "select count(*) from public.debit_queue('a-classer', 0, 100) q"),
    ("debit_queue (doublons)", "select count(*) from public.debit_queue('doublons', 0, 100) q"),
)


def _plants(transfer: str, line: str) -> tuple[tuple[str, str, dict[str, int]], ...]:
    """Copies of the servicer's own rows (its payout, its held line) with their keys moved to two
    other servicers' values."""
    return (
        (
            f"""insert into public.bank_transfer
               select (jsonb_populate_record(null::public.bank_transfer, to_jsonb(t)
                        || jsonb_build_object('id', md5('plant-t' || g)::uuid, 'organization_id', k.org[1 + g % 2],
                             'client_organization_id', case when g % 3 = 0 then k.org[2 - g % 2] end, 'run_id', null,
                             'debtor_bank_account_id', k.acct[1 + g % 2],
                             'creditor_bank_account_id', case when g % 3 = 0 then null else k.cf[1 + g % 2] end,
                             'kind', case g % 3 when 0 then 'payout' when 1 then 'sweep' else 'top_up' end,
                             'end_to_end_id', case g % 3 when 0 then 'RMT' when 1 then 'SWP' else 'TOP' end
                               || 'F' || upper(lpad(to_hex(g), 11, '0'))))).*
               from (select {TWO} org, {TWO} acct, {TWO} cf) k,
                    (select q.* from public.bank_transfer q where q.id = '{transfer}') t,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.bank_transfer",
            {
                "organization_id": 2,
                "debtor_bank_account_id": 2,
                "creditor_bank_account_id": 2,
                "end_to_end_id": 2,
                "kind": 2,
                "status": 2,
            },
        ),
        (
            f"""insert into public.bank_transaction
               select (jsonb_populate_record(null::public.bank_transaction, to_jsonb(x)
                        || jsonb_build_object('id', md5('plant-l' || g)::uuid, 'organization_id', k.org[1 + g % 2],
                             'bank_account_id', k.acct[1 + g % 2], 'statement_id', k.st[1 + g % 2],
                             'line_no', g, 'dedup_key', 'h:plant-' || g,
                             'kind', case g % 4 when 0 then 'label_reference' when 1 then 'own_transfer_in'
                                                when 2 then 'suspected_duplicate' else 'client_transfer_in' end,
                             'reference_from_label', 'RMTF' || upper(lpad(to_hex(g), 11, '0'))))).*
               from (select {TWO} org, {TWO} acct, {TWO} st) k,
                    (select q.* from public.bank_transaction q where q.id = '{line}') x,
                    generate_series(1, {PLANTED}) g""",  # noqa: S608 - the tests' own constants
            "public.bank_transaction",
            {
                "organization_id": 2,
                "bank_account_id": 2,
                "statement_id": 2,
                "kind": 2,
                "reference_from_label": 2,
                "booking_date": 2,
                # (dedup_key is unique per account: analyse stores it as scaling with the table, never 2)
            },
        ),
        (
            f"""insert into public.bank_duplicate_resolution (bank_transaction_id, organization_id,
                 bank_account_id, decision, released_kind, reason, decided_by)
               select md5('plant-l' || g)::uuid, k.org[1 + g % 2], k.acct[1 + g % 2], 'released',
                      'label_reference', 'planté', gen_random_uuid()
               from (select {TWO} org, {TWO} acct) k, generate_series(1, {PLANTED}) g
               where g % 4 = 2""",  # noqa: S608 - the tests' own constants
            "public.bank_duplicate_resolution",
            {"organization_id": 2, "released_kind": 2},
        ),
        (
            f"""insert into public.bank_debit_review (bank_transaction_id, organization_id, reason, candidates)
               select md5('plant-l' || g)::uuid, k.org[1 + g % 2], 'label_reference', '[]'
               from (select {TWO} org) k, generate_series(1, {PLANTED}) g""",  # noqa: S608
            "public.bank_debit_review",
            {"organization_id": 2},
        ),
        # the probes every reader of a line makes (linked, booked, released): other servicers' rows, so that each
        # probe is planned against a table of its size (a table of a few rows is read whole, cheaply, by design)
        (
            f"""insert into public.bank_debit_link (bank_transaction_id, organization_id, bank_account_id, kind,
                 method, reason, decided_by, decided_at)
               select md5('plant-k' || g)::uuid, k.org[1 + g % 2], k.acct[1 + g % 2], 'explained', 'ops', 'planté',
                      gen_random_uuid(), now()
               from (select {TWO} org, {TWO} acct) k, generate_series(1, {PLANTED}) g""",  # noqa: S608
            "public.bank_debit_link",
            {"organization_id": 2, "bank_account_id": 2, "kind": 2},
        ),
        (
            f"""insert into public.bank_line_booking (bank_transaction_id, seq, organization_id, bank_account_id,
                 kind, entry_id, amount_minor, method, decided_at)
               select md5('plant-b' || g)::uuid, 1, k.org[1 + g % 2], k.acct[1 + g % 2], 'fee', gen_random_uuid(),
                      100, 'auto', now()
               from (select {TWO} org, {TWO} acct) k, generate_series(1, {PLANTED}) g""",  # noqa: S608
            "public.bank_line_booking",
            {"organization_id": 2, "bank_account_id": 2, "kind": 2},
        ),
        (
            f"""insert into public.bank_own_credit_release (bank_transaction_id, organization_id, bank_account_id,
                 reason, decided_by, decided_at)
               select md5('plant-o' || g)::uuid, k.org[1 + g % 2], k.acct[1 + g % 2], 'planté', gen_random_uuid(),
                      now()
               from (select {TWO} org, {TWO} acct) k, generate_series(1, {PLANTED}) g""",  # noqa: S608
            "public.bank_own_credit_release",
            {"organization_id": 2, "bank_account_id": 2},
        ),
        # review round 3 (first-kept-candidate-hides-p0): two other servicers' runs, booked and cancelled, and a
        # booked run of the servicer with its payout (BOOKED_RMT: a copy of its payout under another id, inserted with
        # its run — never an update, whose old row version a unique probe would also return; the import keeps it over
        # the label's other candidates, its run read by key)
        (
            f"""insert into public.remittance_run (id, organization_id, client_organization_id, currency, number,
                 status, trigger, known_at, approved_at, booked_on, cancelled_at, cancel_reason, transfer_id)
               select md5('plant-r' || g)::uuid, k.org[1 + g % 2], k.client[1 + g % 2], 'EUR',
                      'RV-2098-' || lpad(g::text, 6, '0'), case when g % 2 = 0 then 'booked' else 'cancelled' end,
                      'manual', now(), now(), case when g % 2 = 0 then current_date end,
                      case when g % 2 = 1 then now() end, case when g % 2 = 1 then 'planté' end, null
               from (select {TWO} org, {TWO} client) k, generate_series(1, {PLANTED}) g
               union all
               select md5('reads-run' || t.id)::uuid, t.organization_id, t.client_organization_id, t.currency,
                      'RV-2097-000001', 'booked', 'manual', now(), now(), current_date, null, null,
                      md5('reads-payout' || t.id)::uuid
               from public.bank_transfer t where t.id = '{transfer}'""",  # noqa: S608 - the tests' own constants
            "public.remittance_run",
            {"organization_id": 2, "client_organization_id": 2, "status": 2},
        ),
        (
            f"""insert into public.bank_transfer
               select (jsonb_populate_record(null::public.bank_transfer, to_jsonb(t)
                        || jsonb_build_object('id', md5('reads-payout' || t.id)::uuid,
                             'run_id', md5('reads-run' || t.id)::uuid,
                             'end_to_end_id', 'RMT' || upper(substr(md5('reads-payout' || t.id), 1, 12))))).*
               from public.bank_transfer t where t.id = '{transfer}'""",  # noqa: S608 - the tests' own constants
            "public.bank_transfer",
            {},
        ),
    )


def _booked_rmt(transfer: str) -> str:
    """The end-to-end id of the servicer's booked run's payout the plant inserts (review round 3)."""
    return "RMT" + hashlib.md5(f"reads-payout{transfer}".encode()).hexdigest()[:12].upper()  # noqa: S324


def _plant(conn: psycopg.Connection[Any], transfer: str, line: str) -> None:
    plants = _plants(transfer, line)
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


def _body(file: str, marker: str) -> str:
    text = (MIGRATIONS / file).read_text()
    start = text.index(marker)
    end = text.index("\n$$;", start) + len("\n$$;")
    return text[start:end]


def _body_before_7e2() -> str:
    return _body(*BEFORE_7E2)


def _queue_before_7e2() -> str:
    """public.debit_queue as 7e-2 found it (its other columns: dropped, then created, then granted)."""
    return (
        "drop function public.debit_queue(text, integer, integer);\n"
        + _body(*QUEUE_BEFORE_7E2)
        + "\ngrant execute on function public.debit_queue(text, integer, integer) to authenticated;"
    )


def _csv(*rows: str) -> bytes:
    return (
        "Date;Libellé;Débit;Crédit;IBAN contrepartie\n" + "".join(f"{r}\n" for r in rows)
    ).encode()


@pytest.fixture(scope="module")
def held() -> dict[str, Any]:
    """A servicer whose CSV holds a credit citing its payout and one citing its sweep (the debit job's
    reviews written), then a second CSV holding a duplicate of the first, released as
    label_reference by ops, and a third one held, not released."""
    tenant = bank_tenant(feed="csv")
    ids = _transfers(tenant)
    day = _fr(paris_today())
    tag = uuid.uuid4().hex[:6].upper()
    label = f"VIR SEPA RECU /DE DUPONT JEAN /MOTIF REMB {ids['rmt']} {tag}"
    # (the copies' labels differ by a word: another fingerprint, a similar label — held, never « already imported »)
    for n, rows in enumerate(
        (
            (
                f"{day};{label} A;;1000,00;{DEBTOR}",
                f"{day};VIR SEPA RECU /MOTIF {ids['swp']} {tag};;50,00;{DEBTOR}",
            ),
            (f"{day};{label} B;;1000,00;{DEBTOR}",),
            (f"{day};{label} C;;1000,00;{DEBTOR}",),
        )
    ):
        upload(tenant, storage(), _csv(*rows), name=f"releve-{tag}-{n}.csv")
        drain(storage())
    with psycopg.connect(DB) as conn:
        lines = [
            str(r[0])
            for r in conn.execute(
                """select t.id from public.bank_transaction t
                   join public.bank_statement s on s.id = t.statement_id
                   where t.bank_account_id = %s order by s.created_at, t.line_no""",
                (tenant["bank"],),
            ).fetchall()
        ]
        rmt = one(
            conn, "select id from public.bank_transfer where end_to_end_id = %s", (ids["rmt"],)
        )
    assert len(lines) == 4, lines
    api(
        tenant,
        "select public.resolve_duplicate(%s, %s, false, 'Deux opérations distinctes (test)')",
        str(uuid.uuid4()),
        lines[2],
    )
    drain(storage())
    return {"tenant": tenant, "ids": ids, "lines": lines, "rmt": str(rmt), "tag": tag}


def test_the_label_reference_reads_stay_keyed_whatever_the_statistics(held: dict[str, Any]) -> None:  # noqa: PLR0915
    tenant, ids, lines = held["tenant"], held["ids"], held["lines"]
    org, user = str(tenant["servicer"]), str(tenant["staff"])
    measured: dict[str, dict[str, int]] = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn, held["rmt"], lines[0])
        conn.execute("set local plan_cache_mode = force_generic_plan")

        def call(name: str, who: str | None, sql: str, *params: Any) -> Any:
            before = _rows(conn)
            value: Any = None
            try:
                with conn.transaction():
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

        # the import of another CSV (staged as the parser stages it): our sweep then the booked run's payout, both
        # of the account (review round 3: the payout kept, its run probed by key), a look-alike, another account's
        # then a look-alike (review round 1, MB-1: every candidate probed, five probes) — and, as its bound, the
        # same lines staged without a candidate (the import's reads before this slice: its duplicate checks read
        # the account's lines, M2b-6's one pass)
        header = Jsonb({"format": "csv", "line_count": 3, "skipped_not_booked": 0, "sections": []})

        def staged(candidates: bool) -> str:
            statement = str(uuid.uuid4())
            with conn.transaction():
                conn.execute("set local role postgres")
                conn.execute(
                    """insert into public.bank_statement (id, organization_id, bank_account_id, currency, format,
                         file_name, file_sha256, size_bytes, storage_path)
                       values (%s, %s, %s, 'EUR', 'csv', 'r.csv', md5(%s) || md5(%s), 1, 'test/' || %s)""",
                    (statement, org, tenant["bank"], statement, statement, statement),
                )
                conn.execute(
                    "update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = %s",
                    (statement,),
                )
                for n, (amount, refs) in enumerate(
                    ((7_000, [ids["swp"], _booked_rmt(held["rmt"])]), (7_100, ["RMT0000000047BF"]),
                     (7_200, [ids["other"], "RMT0000000047BF"])), 1
                ):  # fmt: skip
                    conn.execute(
                        """insert into private.bank_import_stage (statement_id, line_no, section_no, dedup_key,
                             direction, amount_minor, currency, booking_date, counterparty_iban, remittance_text,
                             kind, method, label_references)
                           values (%s, %s, 0, %s, 'credit', %s, 'EUR', %s, %s, %s, %s, 'sct', %s)""",
                        (statement, n, f"h:reads-{statement}-{n}#1", amount, paris_today(), DEBTOR,
                         f"VIR SEPA RECU /MOTIF REMB {' '.join(refs)}",
                         "label_reference" if candidates else "debtor_credit", refs if candidates else None),
                    )  # fmt: skip
                conn.execute("reset role")
            return statement

        with conn.transaction(force_rollback=True):
            plain = staged(candidates=False)
            base = call("ingest_statement (no candidate)", None, "select private.ingest_statement(%s, %s)", plain,
                        header)  # fmt: skip
            assert base["label_references"] == 0, base
        imported_before = measured.pop("ingest_statement (no candidate)")
        cited = staged(candidates=True)
        counts = call(
            "ingest_statement", None, "select private.ingest_statement(%s, %s)", cited, header
        )
        assert counts["label_references"] == 1, counts
        assert counts["payments"]["count"] == 2, counts
        imported = measured.pop("ingest_statement")
        # review round 3 (first-kept-candidate-hides-p0): the booked run's payout kept over the sweep before it
        kept = one(conn, "select reference_from_label from public.bank_transaction where statement_id = %s "
                         "and line_no = 1", (cited,))  # fmt: skip
        assert kept == _booked_rmt(held["rmt"]), (kept, ids)
        # the funds pass's candidates (this slice's kind in both branches), then the debit job's whole pass (the
        # worker's own reads and the SQL)
        cands = call("bank_booking_candidates", None,
                     "select count(*) from private.bank_booking_candidates(%s, null, null, 500)", org)  # fmt: skip
        assert cands == 4, cands  # the two lines read so, the released one, the new one
        before = _rows(conn)
        with conn.transaction():
            conn.execute("set local role postgres")  # the worker's role (its temporary tables)
            summary = _process_funds_lines(conn, org, None)
            conn.execute("reset role")
        after = _rows(conn)
        funds = {k: after[k] - before[k] for k in after if after[k] - before[k]}
        # private.apply_bank_bookings (unchanged since M2b-6) replaces the pass's reviews by a join with its
        # temporary table, never analysed: a hash join over the whole review table — not this slice's read
        # (ADR-0014 « M2c-7e-2 », Left open)
        funds.pop("bank_debit_review", None)
        measured["funds pass"] = funds
        assert summary.get("reviews") == 4, (
            summary
        )  # the two held lines, the released one, the new one
        # « Débits et retours »: its reads beyond those of the body 7e-2 found (same books, same plans) — that body
        # reads the servicer's lines and the review, link, release and resolution tables whole under these
        # statistics (hash joins; review round 1, CC-1: Left open for 7f) —, and the transfers its new column
        # reads, absolutely: one per listed line, by the unique end-to-end id
        queue_before: dict[str, dict[str, int]] = {}
        for name, sql in QUEUE_TABS:
            with conn.transaction(force_rollback=True):
                conn.execute("set local role postgres")
                conn.execute(_queue_before_7e2())
                conn.execute("reset role")
                call(name, user, sql)
            queue_before[name] = measured.pop(name)
        queue = call("debit_queue (à classer)", user,
                     "select coalesce(jsonb_agg(q.kind), '[]') from public.debit_queue('a-classer', 0, 100) q")  # fmt: skip
        assert sorted(queue) == ["label_reference"] * 4, queue
        doubles = call("debit_queue (doublons)", user,
                       "select coalesce(jsonb_agg(q.held_kind), '[]') from public.debit_queue('doublons', 0, 100) q")  # fmt: skip
        assert doubles == ["label_reference"], doubles
        queued = {name: measured.pop(name) for name, _sql in QUEUE_TABS}
        refused = call("link_debit (refused)", user,
                       "select public.link_debit(%s, %s, 'explained', null, null, null, 'test')",
                       str(uuid.uuid4()), lines[0])  # fmt: skip
        assert refused == "debit link refused: label_reference_line", refused
        released = call("resolve_duplicate", user, "select public.resolve_duplicate(%s, %s, false, 'test')",
                        str(uuid.uuid4()), lines[3])  # fmt: skip
        assert released["kind"] == "label_reference", released
        # the nightly: 7e-1's body on the same books, then this slice's — run ten days on, so that every line
        # waits more than two business days and each one's candidate and run are read
        nightly: dict[str, dict[str, int]] = {}
        later = paris_today() + timedelta(days=10)
        for label, setup in (("7e-1", _body_before_7e2()), ("7e-2", None)):
            with conn.transaction(force_rollback=True):
                if setup is not None:
                    conn.execute(setup)
                check = one(conn, "insert into public.payment_check_run (organization_id) values (%s) "
                                  "returning id", (org,))  # fmt: skip
                b0 = _rows(conn)
                conn.execute("select private.run_advance_checks(%s, %s, %s)", (check, org, later))
                b1 = _rows(conn)
                nightly[label] = {k: b1[k] - b0[k] for k in b1 if b1[k] - b0[k]}
                waiting = one(conn, "select count(*) from public.payment_check_result where run_id = %s "
                                    "and code = 'label_reference_waiting'", (check,))  # fmt: skip
                assert waiting == (0 if setup is not None else 5), (label, waiting)
    over = {
        name: {k: v for k, v in rows.items() if v > PER_CALL} for name, rows in measured.items()
    }
    assert not any(over.values()), (over, measured)
    for table, rows in imported.items():
        assert rows <= imported_before.get(table, 0) + PER_CALL, (table, imported, imported_before)
    # review round 1 (MB-1, CC-1): the import's candidates, one keyed probe each (five on three lines)
    assert imported.get("bank_transfer", 0) - imported_before.get("bank_transfer", 0) <= 5, (
        imported,
        imported_before,
    )
    # review round 3: and the run of each payout of the account among them, by key (one: the booked run's)
    assert imported.get("remittance_run", 0) - imported_before.get("remittance_run", 0) <= 1, (
        imported,
        imported_before,
    )
    # review round 1 (CC-1): the queue's label_transfer, one keyed read per listed line citing ours (4 in
    # « À classer », the held one in « Doublons possibles »), whatever the statistics
    for name, reads in queued.items():
        listed = len(queue) if "classer" in name else len(doubles)
        assert (
            reads.get("bank_transfer", 0) - queue_before[name].get("bank_transfer", 0) <= listed
        ), (
            name,
            queued,
            queue_before,
        )
    for name, reads in queued.items():
        for table, rows in reads.items():
            assert rows <= queue_before[name].get(table, 0) + PER_CALL, (
                name,
                table,
                queued,
                queue_before,
            )
    for table in WATCHED:
        key = table.replace("public.", "")
        assert nightly["7e-2"].get(key, 0) <= nightly["7e-1"].get(key, 0) + PER_CALL, nightly
