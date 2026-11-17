"""M2c-6b-2b at the lot cap (plan docs/design/m2c-6b-2-plan.md §8.2 « Scale », critic CSO-3, critic2
CSO2-2, CSO2-3; needs `make up`): a file of LOT payouts (500, `private.transfer_line_lot_cap()`)
generated, written and downloaded through the jobs; its PmtInf debited as one batch line short of
one member (class B, the only subset over every member). As an aal2 API session within the API's
8 s statement timeout: « transfer_line_options » proposes the subset, then « book_transfer_line »
books it — each timed against the plan's budget (options < 2 s, command ≤ 4 s) and written up in
docs/benchmarks/remittances.md. The same line one member longer than the cap is refused
lot_too_large at once (before any subset is searched), with its member count and no member
list. First, in a rolled-back transaction, the same booking read from pg_stat_xact_user_tables (CI
scale fix): every table read once per member read by key, whatever the statistics."""

from __future__ import annotations

import json
import os
import random
import time
import uuid
from typing import Any

import psycopg
import pytest
from debit_helpers import api
from integration_helpers import DB, one
from psycopg.types.json import Jsonb
from test_debit_bookings_scale_integration import _file_payouts, _statement

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
    print(
        f"\n{LOT}-member lot short of one: transfer_line_options {options_s:.2f}s,"
        f" book_transfer_line {command_s:.2f}s ({len(res['bookings'])} bookings)"
    )
    assert len(res["bookings"]) == LOT - 1
    assert options_s < 2, options_s
    assert command_s <= 4, command_s


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
