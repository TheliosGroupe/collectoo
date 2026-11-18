"""M2c-6b-2b at the lot cap (plan docs/design/m2c-6b-2-plan.md §8.2 « Scale », critic CSO-3, critic2
CSO2-2, CSO2-3; needs `make up`): a file of LOT payouts (500, `private.transfer_line_lot_cap()`)
generated, written and downloaded through the jobs; its PmtInf debited as one batch line short of
one member (class B, the only subset over every member). As an aal2 API session within the API's
8 s statement timeout: « transfer_line_options » proposes the subset, then « book_transfer_line »
books it — each timed against the plan's budget (options < 2 s, command ≤ 4 s) and written up in
docs/benchmarks/remittances.md. The same line one member longer than the cap is refused
lot_too_large at once (before any subset is searched), with its member count and no member
list. First, in a rolled-back transaction, the same booking read from pg_stat_xact_user_tables (CI
scale fix): every table read once per member read by key, whatever the statistics.

M2c-6b-2b deferred tests (ADR-0014 « M2c-6b-2b deferred tests »): the time the command holds the
servicer's allocation lock (`payments:`) while it books the 500-member lot, watched in pg_locks
from a second connection; the options on a lot of 5,000 members (one PmtInf of a downloaded file:
the file of two payouts made through the jobs, 4,998 members added to its PmtInf in a rolled-back
transaction) answer lot_too_large from the keyed count, the subset search never called (it would
raise), under 0.5 s; a client's draft of 50,000 reserved items (50,000 advances posted
set-based, the draft requested by the command) re-prepared by the command booking that client's
unplanned payout: within the command's 4 s, the allocation lock held under 1 s (the draft's lines
are not cleared under it: the prepare job does that under the run lock)."""

from __future__ import annotations

import json
import os
import random
import threading
import time
import uuid
from typing import Any

import psycopg
import pytest
from debit_helpers import api
from integration_helpers import DB, one
from psycopg.types.json import Jsonb
from remittance_helpers import remittance_tenant, run_row, staff
from test_debit_bookings_integration import _downloaded
from test_debit_bookings_scale_integration import _file_payouts, _statement
from test_transfer_files_integration import _own_account, _two_runs

from collectoo_worker.remittance import pain001

pytestmark = pytest.mark.integration
LOT = int(os.environ.get("TRANSFER_LINE_LOT_SIZE", "500"))
REASON = "Lot débité sans un virement (test d'échelle)"


@pytest.fixture(scope="module")
def lot(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    return _file_payouts(tmp_path_factory, LOT, 0, "lot")


@pytest.fixture(scope="module")
def over(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    return _file_payouts(tmp_path_factory, LOT + 1, 0, "over")


def _insert_short_line(conn: psycopg.Connection[Any], filed: dict[str, Any]) -> tuple[str, str]:
    """The file's PmtInf debited as one batch line without one member, in `conn`'s transaction:
    (line, the left-out member's end-to-end id)."""
    (pmt,) = filed["payouts"].payment_infos
    left = random.Random(LOT).choice(pmt.transactions)
    st = _statement(conn, filed, "lot.xml")
    line = one(
        conn,
        """insert into public.bank_transaction (organization_id, bank_account_id,
             statement_id, line_no, dedup_key, direction, amount_minor, currency,
             booking_date, kind, payment_info_id)
           values (%s, %s, %s, 1, %s, 'debit', %s, 'EUR', private.paris_today(),
                   'batch_unsplit', %s) returning id""",
        (
            filed["org"],
            filed["tenant"]["bank"],
            st,
            f"t:{st}:1",
            pmt.ctrl_sum_minor - left.amount_minor,
            pmt.pmt_inf_id,
        ),
    )
    conn.execute(
        """update public.bank_statement set status = 'imported',
             from_date = private.paris_today(), to_date = private.paris_today(),
             opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
             finished_at = now() where id = %s""",
        (st,),
    )
    return str(line), left.end_to_end_id


def _short_line(filed: dict[str, Any]) -> tuple[str, str]:
    """The file's PmtInf debited as one batch line without one member (committed): (line, the
    left-out member's end-to-end id)."""
    with psycopg.connect(DB) as conn:
        return _insert_short_line(conn, filed)


# The tables the command, its preview and its options read once per member of a lot by their own
# statements (its runs and their lines, the members, their files and file items): by key, never by
# a sequential scan. (bank_line_booking and bank_debit_link are also read once per booking by the
# job's posting and the booking guard, which this fix leaves as they are: while their statistics
# call them small, a booking may read them whole — ADR-0014 « M2c-6b-2b review fixes ».)
PER_MEMBER = (
    "public.remittance_line",
    "public.remittance_run",
    "public.bank_transfer",
    "public.transfer_file",
    "public.transfer_file_item",
)


def _reads(conn: psycopg.Connection[Any]) -> dict[str, tuple[int, int]]:
    """This transaction's reads so far (pg_stat_xact_user_tables): table -> (sequential scans,
    rows read by them or fetched by index)."""
    rows = conn.execute(
        """select schemaname || '.' || relname, seq_scan,
                  seq_tup_read + coalesce(idx_tup_fetch, 0)
           from pg_stat_xact_user_tables where schemaname in ('public', 'private')"""
    ).fetchall()
    return {str(r[0]): (int(r[1]), int(r[2])) for r in rows}


def test_the_command_reads_a_lot_by_key(lot: dict[str, Any]) -> None:
    """CI scale fix (ADR-0014 « M2c-6b-2b review fixes »): this file runs after the 50,000-line
    runs in the CI order, and two runs then hold almost every remittance line — the analysed
    statistics say so (n_distinct of run_id 2). Each member's run was read with the run's
    conditions next to its key: the lock step (the payments of late lines) and the posting's late
    lines by a sequential scan of remittance_line, the check's late flag by a whole scan of a
    partial index — 500 times each, past the API's 8 s. In one rolled-back transaction, a lot at
    the cap short of one member, then the options and the command as the API's session: every
    per-member table read by key (no sequential scan), the lot's runs' lines a few times each —
    what they read, not how long they take, whatever the statistics of the moment."""
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        line, left = _insert_short_line(conn, lot)
        _as_ops(conn, lot["tenant"])
        before = _reads(conn)
        mark = time.monotonic()
        opts = one(conn, "select public.transfer_line_options(%s)", (line,))
        options_s = time.monotonic() - mark
        assert (opts["class"], opts["member_count"], opts["refusal"]) == ("B", LOT, None), opts
        (proposal,) = opts["proposals"]
        mark = time.monotonic()
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
        command_s = time.monotonic() - mark
        after = _reads(conn)
    seq = {t: after.get(t, (0, 0))[0] - before.get(t, (0, 0))[0] for t in PER_MEMBER}
    rows = {t: after.get(t, (0, 0))[1] - before.get(t, (0, 0))[1] for t in PER_MEMBER}
    print(
        f"\n{LOT}-member lot short of one (rolled back): transfer_line_options {options_s:.2f}s,"
        f" book_transfer_line {command_s:.2f}s ({len(res['bookings'])} bookings); sequential"
        f" scans {seq}, rows read {rows}"
    )
    assert len(res["bookings"]) == LOT - 1
    assert left not in {p["end_to_end_id"] for p in proposal["parts"]}
    assert seq == dict.fromkeys(PER_MEMBER, 0), seq
    # each of the lot's runs holds one line, read by the locks, the preview's and the command's
    # checks and the posting — never the other runs' lines (before the fix: 500 x 101,000 rows)
    assert rows["public.remittance_line"] <= 10 * LOT, rows
    assert options_s < 2, options_s
    assert command_s <= 4, command_s


def test_a_lot_at_the_cap_short_of_one_member_is_booked_within_budget(lot: dict[str, Any]) -> None:
    line, left = _short_line(lot)
    tenant = lot["tenant"]
    mark = time.monotonic()
    opts = dict(api(tenant, "select public.transfer_line_options(%s)", line))
    options_s = time.monotonic() - mark
    assert (opts["class"], opts["member_count"], opts["refusal"]) == ("B", LOT, None), opts
    (proposal,) = opts["proposals"]
    assert len(proposal["parts"]) == LOT - 1
    assert left not in {p["end_to_end_id"] for p in proposal["parts"]}
    watch = _LockWatch(str(lot["org"]))
    mark = time.monotonic()
    with watch:
        res = dict(
            api(
                tenant,
                "select public.book_transfer_line(%s, %s, %s, %s, %s)",
                str(uuid.uuid4()),
                line,
                Jsonb(proposal["request"]),
                proposal["preview"]["expected_text"],
                REASON,
            )
        )
        command_s = time.monotonic() - mark
    print(
        f"\n{LOT}-member lot short of one: transfer_line_options {options_s:.2f}s,"
        f" book_transfer_line {command_s:.2f}s ({len(res['bookings'])} bookings), the allocation"
        f" lock held {watch.held_s:.2f}s"
    )
    assert len(res["bookings"]) == LOT - 1
    assert options_s < 2, options_s
    assert command_s <= 4, command_s
    assert 0 < watch.held_s <= command_s + 0.1, watch.held_s


def _as_ops(conn: psycopg.Connection[Any], tenant: dict[str, Any]) -> None:
    """The rest of this transaction as the API's session would run it: the ops manager at aal2,
    the authenticated role, the API's 8 s."""
    claims = json.dumps({"sub": tenant["staff"], "role": "authenticated", "aal": "aal2"})
    conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
    conn.execute("set local role authenticated")
    conn.execute("set local statement_timeout = '8s'")


@pytest.mark.parametrize(
    ("step", "top", "target"),
    [
        (1_000, 200, 2_600_001),  # multiples of 10 € (10 to 200 €), 26 000,01 €: all 500 items run
        (100, 200, 999_999),  # multiples of 1 € (1 to 200 €), 9 999,99 €: the work bound stops it
    ],
    ids=["rows-all-items", "rows-work-bound"],
)
def test_a_saturating_lot_at_the_cap_runs_its_search_once_within_budget(
    lot: dict[str, Any], step: int, top: int, target: int
) -> None:
    """Review CSR-3 (plan §8.2 CSO2-2, ADR-0014 « M2c-6b-2a review fixes » CS-2/T7): the worst
    inputs of the only-subset search — the row representation, its partial sums saturating under
    their bound (6b-2a's measurement: 1.8 to 2.5 s for the search alone) — at the lot cap. In one
    rolled-back transaction, the lot's 500 payouts re-amounted (their guard off) to small multiples
    and its PmtInf debited by an amount no subset makes; then, as the API's session: the options
    (no subset, so no proposal to preview: one search) refuse batch_ambiguous, and the command,
    which searches before its locks, refuses the parts (no parts of the lot make an amount no
    subset makes) — each within the 2x headroom under the API's 8 s the cap is set from. That the
    options search once when they preview a proposal is pgTAP 037 C's (review CSR-3)."""
    (pmt,) = lot["payouts"].payment_infos
    rng = random.Random(target)
    amounts = [step * rng.randint(1, top) for _ in pmt.transactions]
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        conn.execute("alter table public.bank_transfer disable trigger bank_transfer_guard")
        ids = [
            str(r[0])
            for r in conn.execute(
                "select id from public.bank_transfer where transfer_file_id = %s order by id",
                (lot["file_id"],),
            ).fetchall()
        ]
        assert len(ids) == LOT
        conn.execute(
            """update public.bank_transfer t set amount_minor = a.amount
               from unnest(%s::uuid[], %s::bigint[]) a (id, amount) where t.id = a.id""",
            (ids, amounts),
        )
        conn.execute("alter table public.bank_transfer enable trigger bank_transfer_guard")
        st = _statement(conn, lot, "saturating.xml")
        line = str(
            one(
                conn,
                """insert into public.bank_transaction (organization_id, bank_account_id,
                     statement_id, line_no, dedup_key, direction, amount_minor, currency,
                     booking_date, kind, payment_info_id)
                   values (%s, %s, %s, 1, %s, 'debit', %s, 'EUR', private.paris_today(),
                           'batch_unsplit', %s) returning id""",
                (lot["org"], lot["tenant"]["bank"], st, f"t:{st}:1", target, pmt.pmt_inf_id),
            )
        )
        conn.execute(
            """update public.bank_statement set status = 'imported',
                 from_date = private.paris_today(), to_date = private.paris_today(),
                 opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
                 finished_at = now() where id = %s""",
            (st,),
        )
        _as_ops(conn, lot["tenant"])
        mark = time.monotonic()
        opts = one(conn, "select public.transfer_line_options(%s)", (line,))
        options_s = time.monotonic() - mark
        assert (opts["class"], opts["member_count"], opts["refusal"], opts["proposals"]) == (
            "B",
            LOT,
            "batch_ambiguous",
            [],
        ), opts
        parts = [
            {"kind": "payout", "transfer_id": i, "amount": str(a)}
            for i, a in zip(ids, amounts, strict=True)
        ]
        mark = time.monotonic()
        with pytest.raises(psycopg.Error) as exc:
            conn.execute(
                "select public.book_transfer_line(%s, %s, %s, %s, %s)",
                (str(uuid.uuid4()), line, Jsonb(parts), "x", REASON),
            )
        command_s = time.monotonic() - mark
    print(
        f"\n{LOT}-member saturating lot ({step // 100} € steps, target {target}):"
        f" transfer_line_options {options_s:.2f}s, book_transfer_line {command_s:.2f}s"
        f" ({exc.value.diag.message_primary})"
    )
    assert exc.value.diag.message_primary == "transfer line booking refused: parts_do_not_add_up"
    # the cap's rule (plan §8.2, CSO2-2): 2x headroom under the API's 8 s at the worst input. The
    # options' < 2 s budget holds for an ordinary lot (above); at these inputs the one search alone
    # takes about 2 s on the cloud VM (1.9 to 2.4 s measured), set by the search's work bound, not
    # by the cap (the second input stops at item 151 whatever the cap): ADR-0014 « M2c-6b-2b review
    # fixes », CSR-3, known limit
    assert options_s <= 4, options_s
    assert command_s <= 4, command_s


def test_a_lot_above_the_cap_is_refused_at_once(over: dict[str, Any]) -> None:
    line, _left = _short_line(over)
    mark = time.monotonic()
    opts = dict(api(over["tenant"], "select public.transfer_line_options(%s)", line))
    options_s = time.monotonic() - mark
    print(f"\n{LOT + 1}-member lot: transfer_line_options {options_s:.2f}s (lot_too_large)")
    assert (opts["refusal"], opts["member_count"], opts["members"], opts["proposals"]) == (
        "lot_too_large",
        LOT + 1,
        None,
        [],
    ), opts
    assert options_s < 0.5, options_s


# -- M2c-6b-2b deferred tests ------------------------------------------------------------------

BIG = int(os.environ.get("TRANSFER_LINE_BIG_LOT", "5000"))
DRAFT_ITEMS = int(os.environ.get("TRANSFER_LINE_DRAFT_ITEMS", "50000"))


class _LockWatch:
    """While in its block, a second connection polls pg_locks (every 2 ms) for the servicer's
    allocation lock (`pg_advisory_xact_lock(hashtext('payments:' || org))`, the bigint form) granted
    to anyone; `held_s`: from the first poll that saw it to the last."""

    def __init__(self, org: str) -> None:
        self.org = org
        self.first: float | None = None
        self.last: float | None = None
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._poll)

    def _poll(self) -> None:
        with psycopg.connect(DB, autocommit=True) as conn:
            tag = conn.execute(
                """select ((k >> 32) & 4294967295)::text::oid, (k & 4294967295)::text::oid
                   from (select hashtext('payments:' || %s)::bigint as k) x""",
                (self.org,),
            ).fetchone()
            assert tag is not None
            while not self._stop.is_set():
                held = conn.execute(
                    """select exists (select 1 from pg_locks where locktype = 'advisory'
                         and granted and classid = %s and objid = %s and objsubid = 1)""",
                    tag,
                ).fetchone()
                if held and held[0]:
                    now = time.monotonic()
                    self.first = self.first or now
                    self.last = now
                time.sleep(0.002)

    def __enter__(self) -> _LockWatch:
        self._thread.start()
        time.sleep(0.05)
        return self

    def __exit__(self, *exc: object) -> None:
        time.sleep(0.05)
        self._stop.set()
        self._thread.join(10)

    @property
    def held_s(self) -> float:
        return 0.0 if self.first is None or self.last is None else self.last - self.first


def _line(conn: psycopg.Connection[Any], tenant: dict[str, Any], amount: int, **cols: Any) -> str:
    """A debit on a new imported statement of the tenant's account (in the caller's transaction)."""
    org = str(tenant["servicer"])
    st = one(
        conn,
        """insert into public.bank_statement (organization_id, bank_account_id, currency, format,
             file_name, file_sha256, size_bytes, storage_path)
           values (%s, %s, 'EUR', 'camt053', 's.xml', %s, 1, %s) returning id""",
        (org, tenant["bank"], uuid.uuid4().hex * 2, f"test/{uuid.uuid4()}"),
    )
    conn.execute(
        "update public.bank_statement set status = 'uploaded', uploaded_at = now() where id = %s",
        (st,),
    )
    names = ", ".join(cols)
    marks = ", ".join(["%s"] * len(cols))
    line = one(
        conn,
        f"""insert into public.bank_transaction (organization_id, bank_account_id, statement_id,
              line_no, dedup_key, direction, amount_minor, currency, booking_date, {names})
            values (%s, %s, %s, 1, %s, 'debit', %s, 'EUR', private.paris_today(), {marks})
            returning id""",  # noqa: S608 - the column names are the test's own
        (org, tenant["bank"], st, f"t:{st}:1", amount, *cols.values()),
    )
    conn.execute(
        """update public.bank_statement set status = 'imported',
             from_date = private.paris_today(), to_date = private.paris_today(),
             opening_booked_minor = 0, closing_booked_minor = 0, counts = '{}',
             finished_at = now() where id = %s""",
        (st,),
    )
    return str(line)


def test_options_on_a_5000_member_lot_answer_from_the_count(
    tmp_path_factory: pytest.TempPathFactory,
) -> None:
    """Critic2 CSO2-3: a lot of BIG members (the file of two payouts made through the jobs, its
    PmtInf filled to BIG in a rolled-back transaction): the options, the preview and the command
    refuse lot_too_large from the keyed count — its member count, no member list — and never
    search a subset (private.unique_subset replaced, in the same transaction, by one raising)."""
    tenant, _other, _r1, _r2 = _two_runs()
    f, data = _downloaded(tenant, tmp_path_factory.mktemp("big"))
    ((pmt, members),) = [
        (p.pmt_inf_id, len(p.transactions)) for p in pain001.read(data).payment_infos
    ]
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        iban = one(
            conn,
            "select iban from public.client_payout_account where id = %s",
            (tenant["payout"],),
        )
        conn.execute("alter table public.bank_transfer disable trigger bank_transfer_guard")
        added = BIG - members
        conn.execute(
            """with t as (
                 insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id,
                   currency, amount_minor, payee_name, payee_iban, end_to_end_id,
                   requested_execution_date, status, transfer_file_id, client_organization_id)
                 select %s, 'payout', %s, 'EUR', 1000 + g, 'CLIENT SAS', %s,
                        'RMT' || upper(substr(md5(%s || g::text), 1, 12)), private.paris_today(),
                        'in_file', %s, %s
                 from generate_series(1, %s) g
                 returning id, amount_minor)
               insert into public.transfer_file_item (file_id, seq, transfer_id, organization_id,
                 pmt_inf_id, execution_date)
               select %s, %s + row_number() over (order by t.amount_minor), t.id, %s, %s,
                      private.paris_today()
               from t""",
            (tenant["servicer"], tenant["bank"], iban, uuid.uuid4().hex, f["id"],
             tenant["client"], added, f["id"], members, tenant["servicer"], pmt),
        )  # fmt: skip
        conn.execute(
            """create or replace function private.unique_subset(p_amounts bigint[], p_target bigint)
               returns integer[] language plpgsql set search_path = '' as $$
               begin raise exception 'the subset searched'; end $$"""
        )
        line = _line(conn, tenant, 123_456, kind="batch_unsplit", payment_info_id=pmt)
        transfer = one(
            conn,
            "select transfer_id from public.transfer_file_item where file_id = %s and seq = 1",
            (f["id"],),
        )
        _as_ops(conn, tenant)
        mark = time.monotonic()
        opts = one(conn, "select public.transfer_line_options(%s)", (line,))
        options_s = time.monotonic() - mark
        parts = Jsonb([{"kind": "payout", "transfer_id": str(transfer), "amount": "123456"}])
        preview = one(conn, "select public.transfer_line_preview(%s, %s)", (line, parts))
        mark = time.monotonic()
        with pytest.raises(psycopg.Error) as exc:
            conn.execute(
                "select public.book_transfer_line(%s, %s, %s, %s, %s)",
                (str(uuid.uuid4()), line, parts, "x", REASON),
            )
        command_s = time.monotonic() - mark
    print(
        f"\n{BIG}-member lot: transfer_line_options {options_s:.3f}s, book_transfer_line"
        f" {command_s:.3f}s (lot_too_large)"
    )
    assert (opts["class"], opts["refusal"], opts["member_count"], opts["members"]) == (
        "B",
        "lot_too_large",
        BIG,
        None,
    ), opts
    assert opts["proposals"] == [] and (preview["ok"], preview["why"]) == (False, "lot_too_large")
    assert exc.value.diag.message_primary == "transfer line booking refused: lot_too_large"
    assert options_s < 0.5, options_s
    assert command_s < 0.5, command_s


@pytest.fixture(scope="module")
def draft50k() -> dict[str, Any]:
    """A client with DRAFT_ITEMS advances posted set-based (each a pending item of its queue), its
    draft requested by ops (the command reserves them all), and a debit of 1 234,00 € to its payout
    IBAN naming nothing of ours (S13), committed."""
    tenant = remittance_tenant()
    _own_account(tenant)
    marks: dict[str, float] = {}
    mark = time.monotonic()
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("select private.ledger_post_set_begin()")
        conn.execute(
            """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type,
                 effective_date, idempotency_key, client_organization_id, source_type, source_id,
                 reason)
               select g, %s, 'client_advance', private.paris_today(),
                      'scale-adv:' || gen_random_uuid(),
                      %s, 'client_advance', gen_random_uuid()::text, 'Avance (test d''échelle)'
               from generate_series(1, %s) g""",
            (tenant["servicer"], tenant["client"], DRAFT_ITEMS),
        )
        conn.execute(
            """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
               select g, v.line_no, v.book, v.sign * 100, 'EUR'
               from generate_series(1, %s) g
               cross join (values (1, 'due_to_servicer', 1), (2, 'client_payable', -1),
                                  (3, 'client_advance_receivable', 1),
                                  (4, 'due_from_client_funds', -1)) v (line_no, book, sign)""",
            (DRAFT_ITEMS,),
        )
        conn.execute("select count(*) from private.ledger_post_set()")
    marks["post"] = time.monotonic() - mark
    mark = time.monotonic()
    draft = staff(tenant, "select public.request_remittance_run(%s, %s, 'EUR')",
                  str(uuid.uuid4()), tenant["client"])["run_id"]  # fmt: skip
    marks["request"] = time.monotonic() - mark
    with psycopg.connect(DB) as conn, conn.transaction():
        iban = one(
            conn,
            "select iban from public.client_payout_account where id = %s",
            (tenant["payout"],),
        )
        line = _line(conn, tenant, 123_400, kind="other_debit", counterparty_iban=iban)
    assert run_row(str(draft))["item_count"] == DRAFT_ITEMS
    return {"tenant": tenant, "draft": str(draft), "line": line, "marks": marks}


def test_the_requeue_of_a_50000_item_draft_holds_the_allocation_lock_briefly(
    draft50k: dict[str, Any],
) -> None:
    """Plan §8.2 « Scale »: the command booking the client's unplanned payout re-prepares its draft
    of DRAFT_ITEMS reserved items (the new rows reserved, the job queued under a new token; the
    draft's lines are not cleared here) within its 4 s, the allocation lock held under 1 s."""
    tenant, line, draft = draft50k["tenant"], draft50k["line"], draft50k["draft"]
    mark = time.monotonic()
    opts = dict(api(tenant, "select public.transfer_line_options(%s)", line))
    options_s = time.monotonic() - mark
    (proposal,) = opts["proposals"]
    assert [d["run_id"] for d in proposal["preview"]["drafts"]] == [draft]
    watch = _LockWatch(str(tenant["servicer"]))
    with watch:
        mark = time.monotonic()
        res = dict(
            api(
                tenant,
                "select public.book_transfer_line(%s, %s, %s, %s, %s)",
                str(uuid.uuid4()),
                line,
                Jsonb(proposal["request"]),
                proposal["preview"]["expected_text"],
                REASON,
            )
        )
        command_s = time.monotonic() - mark
    head = run_row(draft)
    print(
        f"\n{DRAFT_ITEMS}-item draft requeued: fixture post {draft50k['marks']['post']:.1f}s,"
        f" request {draft50k['marks']['request']:.2f}s; transfer_line_options {options_s:.2f}s,"
        f" book_transfer_line {command_s:.2f}s, the allocation lock held {watch.held_s:.2f}s"
    )
    assert res["drafts_requeued"] == [draft]
    assert (head["job"], head["item_count"], head["prepared_at"]) == (
        "prepare",
        DRAFT_ITEMS + 2,
        None,
    )
    assert command_s <= 4, command_s
    assert 0 < watch.held_s < 1, watch.held_s
    with psycopg.connect(DB) as conn:
        # the queued prepare jobs of this draft taken off the queue: no later test pays for them
        conn.execute(
            """select pgmq.delete('remittances', m.msg_id) from pgmq.q_remittances m
               where m.message ->> 'run_id' = %s""",
            (draft,),
        )
