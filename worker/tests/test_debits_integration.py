"""M2b-6 through the database (needs `make up`): statements with debits imported through the
payments queue. The design's worked example (§8.2): E4 the refund of P2's overpayment (request,
then the bank's RFD debit linked and booked), variant B the bank return of P1 (its allocation
reversed at the return date, cash_out, `returned`, final void receipt, the client told). A refund
that comes back unpaid; a partial return linked by ops and the rest allocated again from the return
date; lines the job leaves to ops; a payment the debtor made to the client directly; CSV suspected
duplicates released or confirmed; the nightly checks finding a planted inconsistency."""

import uuid
from datetime import date
from typing import Any

import psycopg
import pytest
from allocation_helpers import (
    File,
    Item,
    allocations,
    balances,
    client_money,
    create_file,
    credit,
    evidence,
    state,
    statement,
)
from debit_helpers import (
    api,
    bounce_entry,
    checks,
    closing,
    entries_of,
    fee_entry,
    import_entries,
    line_id,
    link_of,
    notifications,
    receipt_kinds,
    refund_entry,
    refund_request,
    return_entry,
    review_of,
    violations,
)
from integration_helpers import DB, one, storage
from psycopg.types.json import Jsonb
from statement_helpers import bank_tenant, drain, upload

from collectoo_worker.jobs.payments import make_handler, record_dead_job
from collectoo_worker.runtime.queue import QueueConsumer

pytestmark = pytest.mark.integration
DAY = date(2026, 10, 12)
REFUND_DAY = date(2026, 10, 21)
RETURN_DAY = date(2026, 11, 3)


def _files(tenant: dict[str, Any]) -> tuple[File, File]:
    m = create_file(
        tenant,
        File(
            f"M-{uuid.uuid4().hex[:6]}",
            "b2b",
            "Martin-Durand SARL",
            [
                Item("F-101", {"principal": 150_000}, date(2026, 6, 10)),
                Item("F-102", {"principal": 80_000}, date(2026, 7, 15)),
            ],
        ),
    )
    lilas = create_file(
        tenant,
        File(
            f"L-{uuid.uuid4().hex[:6]}",
            "b2b",
            "Lilas SAS",
            [Item("F-201", {"principal": 512_000}, date(2026, 8, 1))],
        ),
    )
    return m, lilas


def _e2e(payment: str) -> str:
    with psycopg.connect(DB) as conn:
        return str(one(conn, "select end_to_end_id from public.payment where id = %s", (payment,)))


def _bank_check(statement_id: str) -> int:
    with psycopg.connect(DB) as conn:
        check = one(
            conn, "select bank_check from public.bank_statement where id = %s", (statement_id,)
        )
    return int(check["difference_minor"])


def _refund(refund_id: str) -> tuple[str, date | None]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select status, executed_on from public.refund_request where id = %s", (refund_id,)
        ).fetchone()
    assert row is not None
    return row[0], row[1]


def test_refund_then_bank_return_of_the_worked_example() -> None:
    tenant = bank_tenant()
    store = storage()
    m, lilas = _files(tenant)
    prefix = f"WX{uuid.uuid4().hex[:4]}"
    ids = statement(
        tenant,
        store,
        [credit(200_000, rf=m.rf), credit(520_000, rf=lilas.rf)],
        prefix,
        DAY,
        receipts=True,
    )
    p1, p2 = ids[f"{prefix}000000000001"], ids[f"{prefix}000000000002"]
    s1 = next(iter(_statement_ids(tenant)))
    assert state(p1) == ("allocated", None)
    assert state(p2) == ("partially_allocated", "overpayment")  # 8 000 left for the payer (#8)

    # E4: ops ask for the refund of the overpayment; nothing is booked until the bank's debit
    # shows it
    asked = refund_request(tenant, p2, 8_000, "overpayment")
    assert asked["end_to_end_id"].startswith("RFD")
    assert state(p2) == ("refund_pending", None)
    s2 = import_entries(
        tenant,
        store,
        [refund_entry(8_000, asked["end_to_end_id"], f"R{prefix}", REFUND_DAY)],
        day=REFUND_DAY,
        opening=closing(s1),
        receipts=True,
    )
    rline = line_id(tenant, f"R{prefix}")
    assert link_of(rline) == ("refund", p2, asked["refund_request_id"], "auto")
    assert _refund(asked["refund_request_id"]) == ("executed", REFUND_DAY)
    assert state(p2) == ("allocated", None)
    assert entries_of(p2)[-1] == ("cash_out", None, REFUND_DAY, 8_000)
    assert receipt_kinds(p2) == ["original", "update"]  # « Montant restitué »
    assert _bank_check(s2) == 0

    # Variant B: the bank takes P1 back on 11-03; its allocation is reversed on the return date
    before = balances(m)
    s3 = import_entries(
        tenant,
        store,
        [return_entry(200_000, _e2e(p1), f"T{prefix}", RETURN_DAY)],
        day=RETURN_DAY,
        opening=closing(s2),
        receipts=True,
    )
    tline = line_id(tenant, f"T{prefix}")
    assert link_of(tline) == ("return", p1, None, "auto")
    assert state(p1) == ("returned", None)
    assert entries_of(p1) == [
        ("allocation", None, DAY, 200_000),
        (
            "reversal",
            "allocation",
            RETURN_DAY,
            -200_000,
        ),  # the return date, never back-dated (§2 #3)
        ("cash_out", None, RETURN_DAY, 200_000),
    ]
    assert allocations(p1) == []
    after = balances(m)
    assert (
        after[("F-101", "principal")] == before[("F-101", "principal")] + 150_000
    )  # the debt reopens
    assert after[("F-102", "principal")] == before[("F-102", "principal")] + 50_000
    # one transaction writes both return notifications (same time): compared as a set
    assert sorted(notifications(p1), key=str) == sorted(
        [
            ("payment_allocated", None),
            ("payment_allocation_reversed", "bank_return"),
            ("payment_returned", "bank_return"),
        ],
        key=str,
    )
    assert receipt_kinds(p1) == ["original", "void"]  # final
    assert _bank_check(s3) == 0
    # client money closed; the bank account's cash = what is left of its payments
    money = client_money(tenant)
    assert sum(money.values()) == 0
    assert money["client_money_cash"] == 720_000 - 8_000 - 200_000 == closing(s3)
    run = checks(tenant)
    assert violations(run["run_id"]) == []

    # Statements imported again create nothing; the returned payment cannot be allocated again
    drain(store, receipts=True)
    assert receipt_kinds(p1) == ["original", "void"]
    with pytest.raises(psycopg.errors.CheckViolation):
        api(
            tenant,
            "select public.allocate_payment(%s, %s, null, null, null, 'x')",
            str(uuid.uuid4()),
            p1,
        )


def _statement_ids(tenant: dict[str, Any]) -> list[str]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            "select id::text from public.bank_statement where bank_account_id = %s"
            " order by created_at",
            (tenant["bank"],),
        ).fetchall()
    return [r[0] for r in rows]


def test_a_refund_that_comes_back_unpaid_puts_the_money_back_on_the_payment() -> None:
    tenant = bank_tenant()
    store = storage()
    _m, lilas = _files(tenant)
    prefix = f"BX{uuid.uuid4().hex[:4]}"
    ids = statement(tenant, store, [credit(520_000, rf=lilas.rf)], prefix, DAY)
    p = ids[f"{prefix}000000000001"]
    s1 = _statement_ids(tenant)[0]
    asked = refund_request(tenant, p, 8_000, "overpayment")
    s2 = import_entries(
        tenant,
        store,
        [refund_entry(8_000, asked["end_to_end_id"], f"R{prefix}", REFUND_DAY)],
        day=REFUND_DAY,
        opening=closing(s1),
    )
    assert state(p) == ("allocated", None)
    back = date(2026, 10, 23)
    import_entries(
        tenant,
        store,
        [bounce_entry(8_000, asked["end_to_end_id"], f"B{prefix}", back)],
        day=back,
        opening=closing(s2),
    )
    assert link_of(line_id(tenant, f"B{prefix}")) == (
        "refund_returned",
        p,
        asked["refund_request_id"],
        "auto",
    )
    assert _refund(asked["refund_request_id"])[0] == "bounced"
    # back on its file from its facts now, gated again by the allocation job: the file owes
    # nothing more, so the 8 000 waits for ops again (founder #8)
    assert state(p) == ("partially_allocated", "nothing_due")
    assert entries_of(p)[-2:] == [
        ("cash_out", None, REFUND_DAY, 8_000),
        ("reversal", "cash_out", back, -8_000),
    ]
    assert sum(client_money(tenant).values()) == 0


def test_a_partial_return_is_left_to_ops_then_the_rest_is_allocated_from_the_return_date() -> None:
    tenant = bank_tenant()
    store = storage()
    a = create_file(
        tenant,
        File(
            f"P-{uuid.uuid4().hex[:6]}",
            "b2b",
            "Partiel SA",
            [
                Item("F-1", {"principal": 30_000}, date(2026, 7, 1)),
                Item("F-2", {"principal": 20_000}, date(2026, 8, 1)),
            ],
        ),
    )
    prefix = f"PX{uuid.uuid4().hex[:4]}"
    ids = statement(tenant, store, [credit(50_000, rf=a.rf)], prefix, DAY)
    p = ids[f"{prefix}000000000001"]
    s1 = _statement_ids(tenant)[0]
    import_entries(
        tenant,
        store,
        [return_entry(20_000, _e2e(p), f"T{prefix}", RETURN_DAY)],
        day=RETURN_DAY,
        opening=closing(s1),
    )
    line = line_id(tenant, f"T{prefix}")
    assert link_of(line) is None and review_of(line) == "partial_return"
    assert state(p) == ("allocated", None)
    # ops link it, with what is left of the payment as the page showed it (compare and set)
    with pytest.raises(psycopg.errors.CheckViolation, match="payment_changed"):
        api(
            tenant,
            "select public.link_debit(%s, %s, 'return', %s, null, '49999', 'retour partiel')",
            str(uuid.uuid4()),
            line,
            p,
        )
    api(
        tenant,
        "select public.link_debit(%s, %s, 'return', %s, null, '50000', 'retour partiel')",
        str(uuid.uuid4()),
        line,
        p,
    )
    assert link_of(line) == ("return", p, None, "ops")
    assert review_of(line) is None
    assert state(p) == ("matched", "partial_return")
    assert entries_of(p)[1:] == [
        ("reversal", "allocation", RETURN_DAY, -50_000),
        ("cash_out", None, RETURN_DAY, 20_000),
    ]
    # « Imputer »: the 30 000 left is allocated again, from the return date (I4: it was allocated
    # until then)
    api(
        tenant,
        "select public.allocate_payment(%s, %s, 'partial_return', null, null, 'débiteur confirme')",
        str(uuid.uuid4()),
        p,
    )
    drain(store)
    assert state(p) == ("allocated", None)
    assert entries_of(p)[-1] == ("allocation", None, RETURN_DAY, 30_000)
    assert allocations(p) == [("F-1", "principal", 30_000)]
    assert sum(client_money(tenant).values()) == 0
    assert violations(checks(tenant)["run_id"]) == []


def test_lines_the_job_cannot_decide_wait_for_ops() -> None:
    tenant = bank_tenant()
    store = storage()
    m, _ = _files(tenant)
    prefix = f"AX{uuid.uuid4().hex[:4]}"
    ids = statement(tenant, store, [credit(10_000, rf=m.rf)], prefix, DAY)
    p = ids[f"{prefix}000000000001"]
    s1 = _statement_ids(tenant)[0]
    entries = [
        return_entry(4_000, "E2E-INCONNU", f"U{prefix}", RETURN_DAY),  # names no payment
        refund_entry(1_500, "RFD000000000000", f"F{prefix}", RETURN_DAY),  # names no request
        fee_entry(290, f"G{prefix}", RETURN_DAY),  # a fee: an explained gap (#20)
    ]
    s2 = import_entries(tenant, store, entries, day=RETURN_DAY, opening=closing(s1))
    unknown, rfd = (line_id(tenant, f"{k}{prefix}") for k in "UF")
    fee = line_id(tenant, f"NG{prefix}")  # a fee has no detail: the entry's reference
    assert (review_of(unknown), review_of(rfd), review_of(fee)) == (
        "no_candidate",
        "no_candidate",
        None,
    )
    assert state(p) == ("allocated", None)
    # the bank check counts the open lines as explained gaps until they are linked
    assert _bank_check(s2) == 0
    # money that went out under our RFD id is booked, never only explained: it waits in « À
    # classer » (and the nightly ageing alert) until ops link it to a refund
    with pytest.raises(psycopg.errors.CheckViolation, match="not_explainable"):
        api(
            tenant,
            "select public.link_debit(%s, %s, 'explained', null, null, null,"
            " 'frais repris par la banque')",
            str(uuid.uuid4()),
            rfd,
        )
    assert link_of(rfd) is None and review_of(rfd) == "no_candidate"
    # ops link the unknown return to the payment (a bank that drops the end-to-end id)
    api(
        tenant,
        "select public.link_debit(%s, %s, 'return', %s, null, '10000', 'retour sans référence')",
        str(uuid.uuid4()),
        unknown,
        p,
    )
    assert state(p) == ("matched", "partial_return")  # 4 000 of 10 000 taken back
    with pytest.raises(psycopg.errors.CheckViolation, match="already_linked"):
        api(
            tenant,
            "select public.link_debit(%s, %s, 'explained', null, null, null, 'x')",
            str(uuid.uuid4()),
            unknown,
        )
    run = checks(tenant)
    assert violations(run["run_id"]) == []


def test_a_payment_made_to_the_client_directly_lowers_the_debt_in_the_legal_order() -> None:
    tenant = bank_tenant()
    store = storage()
    loan = create_file(
        tenant,
        File(
            f"D-{uuid.uuid4().hex[:6]}",
            "b2b",
            "Direct SA",
            [
                Item("F-1", {"principal": 30_000}, date(2026, 7, 1)),
                Item("F-2", {"principal": 20_000}, date(2026, 8, 1)),
            ],
        ),
    )
    doc = evidence(tenant, loan.id)
    f2 = loan.item("F-2").id
    with psycopg.connect(DB) as conn:
        assert (
            one(
                conn,
                "select count(*) from public.ledger_entry where account_id = %s"
                " and source_type = 'direct_payment'",
                (loan.id,),
            )
            == 0
        )
    # the client's statement: 25 000 paid on 10-20 for F-2 (designated first), the rest in the
    # legal order
    out = api(
        tenant,
        "select public.record_direct_payment(%s, %s, %s::uuid[], '25000', '2026-10-20', %s,"
        " 'relevé client')",
        str(uuid.uuid4()),
        loan.id,
        [f2],
        doc,
    )
    drain(store)
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select status, entry_id::text from public.direct_payment where id = %s",
            (out["direct_payment_id"],),
        ).fetchone()
        assert row is not None and row[0] == "posted"
        lines = conn.execute(
            """select la.book, i.ref, lp.amount_minor from public.ledger_posting lp
               join public.ledger_account la on la.id = lp.ledger_account_id
               left join public.claim_item i on i.id = la.claim_item_id
               where lp.entry_id = %s order by lp.line_no""",
            (row[1],),
        ).fetchall()
        etype = one(
            conn,
            "select entry_type || ':' || effective_date from public.ledger_entry where id = %s",
            (row[1],),
        )
    assert etype == "adjustment:2026-10-20"
    assert [(r[0], r[1], int(r[2])) for r in lines] == [
        ("debtor_receivable", "F-2", -20_000),
        ("debtor_receivable", "F-1", -5_000),
        ("owner_claim", None, 25_000),
    ]
    assert client_money(tenant) == {}  # no client money moved
    # more than is due is refused (the client must refund its debtor, not us)
    late = api(
        tenant,
        "select public.record_direct_payment(%s, %s, '{}'::uuid[], '30000', '2026-10-21', %s,"
        " 'relevé client')",
        str(uuid.uuid4()),
        loan.id,
        doc,
    )
    drain(store)
    with psycopg.connect(DB) as conn:
        assert (
            one(
                conn,
                "select refusal_code from public.direct_payment where id = %s",
                (late["direct_payment_id"],),
            )
            == "more_than_due"
        )


def _csv(rows: list[tuple[str, str, str, str]]) -> bytes:
    head = "Date opération;Libellé;Débit;Crédit"
    return ("\r\n".join([head, *(";".join(r) for r in rows)]) + "\r\n").encode("cp1252")


def test_csv_suspected_duplicates_are_released_or_confirmed() -> None:
    tenant = bank_tenant("csv")
    store = storage()
    upload(
        tenant,
        store,
        _csv(
            [
                ("05/10/2026", "VIR SEPA DUPONT JEAN LOYER", "", "150,00"),
                ("05/10/2026", "VIR SEPA MARTIN PAUL LOYER", "", "80,00"),
            ]
        ),
        "a.csv",
    )
    drain(store)
    before = client_money(tenant)
    upload(
        tenant,
        store,
        _csv(
            [
                ("05/10/2026", "VIR SEPA DUPONT JEAN LOYER OCT", "", "150,00"),
                ("05/10/2026", "VIR SEPA MARTIN PAUL LOYER OCT", "", "80,00"),
            ]
        ),
        "b.csv",
    )
    drain(store)
    with psycopg.connect(DB) as conn:
        held: dict[int, str] = dict(
            conn.execute(
                """select amount_minor, id::text from public.bank_transaction
                   where bank_account_id = %s and kind = 'suspected_duplicate'""",
                (tenant["bank"],),
            ).fetchall()
        )
    assert set(held) == {15_000, 8_000}
    assert client_money(tenant) == before  # held: no payment, no cash
    # ops: the 150,00 is a second rent payment (released: payment + cash_in of its day); the 80,00
    # a duplicate
    out = api(
        tenant,
        "select public.resolve_duplicate(%s, %s, false, 'deux loyers distincts')",
        str(uuid.uuid4()),
        held[15_000],
    )
    assert out["decision"] == "released" and out["kind"] == "debtor_credit"
    api(
        tenant,
        "select public.resolve_duplicate(%s, %s, true, 'même opération')",
        str(uuid.uuid4()),
        held[8_000],
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="already decided"):
        api(
            tenant,
            "select public.resolve_duplicate(%s, %s, true, 'x')",
            str(uuid.uuid4()),
            held[8_000],
        )
    drain(store)
    assert client_money(tenant)["client_money_cash"] == before["client_money_cash"] + 15_000
    assert (
        state(out["payment_id"])[0] == "unmatched"
    )  # matched by the job (no file here: the queue)
    run = checks(tenant)
    assert violations(run["run_id"]) == []  # I11 per statement day counts the release's cash_in


def test_the_nightly_checks_find_a_planted_inconsistency() -> None:
    tenant = bank_tenant()
    store = storage()
    m, _ = _files(tenant)
    prefix = f"IX{uuid.uuid4().hex[:4]}"
    ids = statement(
        tenant, store, [credit(10_000, rf=m.rf), credit(777, text="INCONNU")], prefix, DAY
    )
    p, unknown = ids[f"{prefix}000000000001"], ids[f"{prefix}000000000002"]
    clean = checks(tenant)
    assert violations(clean["run_id"]) == []
    with psycopg.connect(DB) as conn, conn.transaction():
        # a status that does not say what the ledger does (written behind the commands' back)
        conn.execute(
            "update public.payment set status = 'allocated', review_reason = null where id = %s",
            (unknown,),
        )
    run = checks(tenant)
    assert violations(run["run_id"]) == [("payment_position", unknown)]
    assert run["by_code"] == {"payment_position": 1}
    with psycopg.connect(DB) as conn:
        stored = one(
            conn, "select violations from public.payment_check_run where id = %s", (run["run_id"],)
        )
    assert stored == 1
    # the job, as pg_cron queues it, writes the same run
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select pgmq.send('payments', %s)",
            (Jsonb({"type": "invariants", "organization_id": str(tenant["servicer"])}),),
        )
    drain(store)
    with psycopg.connect(DB) as conn:
        latest = one(
            conn,
            "select violations from public.payment_check_run where organization_id = %s"
            " order by started_at desc limit 1",
            (tenant["servicer"],),
        )
    assert latest == 1
    assert state(p) == ("allocated", None)


def _latest_alert_ids(tenant: dict[str, Any], code: str) -> list[str]:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select r.details -> 'ids' from public.payment_check_result r
               join public.payment_check_run x on x.id = r.run_id
               where x.organization_id = %s and r.code = %s
               order by x.started_at desc limit 1""",
            (tenant["servicer"], code),
        ).fetchone()
    return [] if row is None else [str(i) for i in row[0]]


def test_a_refund_that_comes_back_to_a_returned_payment_waits_for_ops_and_the_run_goes_on() -> None:
    """Review fix (money #0, security #1): P2's overpayment refunded, then the bank takes the rest
    of P2 back, then the refund comes back unpaid. Where that money goes is not decided (open
    question): the line is never booked automatically, it waits for ops — and the other lines of
    the same run (P1's return) are posted. Before the fix the run raised on the returned payment,
    was retried, dead-lettered, and every later run failed the same way."""
    tenant = bank_tenant()
    store = storage()
    m, lilas = _files(tenant)
    prefix = f"QX{uuid.uuid4().hex[:4]}"
    credits = [credit(200_000, rf=m.rf), credit(520_000, rf=lilas.rf)]
    ids = statement(tenant, store, credits, prefix, DAY)
    p1, p2 = ids[f"{prefix}000000000001"], ids[f"{prefix}000000000002"]
    s1 = _statement_ids(tenant)[0]
    asked = refund_request(tenant, p2, 8_000, "overpayment")
    s2 = import_entries(
        tenant,
        store,
        [refund_entry(8_000, asked["end_to_end_id"], f"R{prefix}", REFUND_DAY)],
        day=REFUND_DAY,
        opening=closing(s1),
    )
    assert state(p2) == ("allocated", None)
    taken = date(2026, 10, 25)
    s3 = import_entries(
        tenant,
        store,
        [return_entry(512_000, _e2e(p2), f"T{prefix}", taken)],  # what is left of P2
        day=taken,
        opening=closing(s2),
    )
    assert state(p2) == ("returned", None)
    back = date(2026, 10, 27)
    import_entries(
        tenant,
        store,
        [
            bounce_entry(8_000, asked["end_to_end_id"], f"B{prefix}", back),
            return_entry(200_000, _e2e(p1), f"U{prefix}", back),
        ],
        day=back,
        opening=closing(s3),
    )
    bounce, p1_return = line_id(tenant, f"B{prefix}"), line_id(tenant, f"U{prefix}")
    assert link_of(bounce) is None and review_of(bounce) == "payment_returned"
    assert link_of(p1_return) == ("return", p1, None, "auto")  # the run went on
    assert state(p1) == ("returned", None)
    assert state(p2) == ("returned", None)  # nothing booked on it
    assert _refund(asked["refund_request_id"])[0] == "executed"
    # ops cannot book it on the returned payment either (a clear refusal, not a ledger error)
    with pytest.raises(psycopg.errors.CheckViolation, match="payment_returned"):
        api(
            tenant,
            "select public.link_debit(%s, %s, 'refund_returned', null, %s, null, 'retour')",
            str(uuid.uuid4()),
            bounce,
            asked["refund_request_id"],
        )
    # the books hold; the 8 000 that came back stays visible to the nightly checks
    assert sum(client_money(tenant).values()) == 0
    run = checks(tenant)
    assert violations(run["run_id"]) == []
    assert bounce in _latest_alert_ids(tenant, "debit_unclassified")


def test_a_return_dated_before_a_later_linked_return_waits_for_ops_and_the_run_goes_on() -> None:
    """Review fix (money #1, performance #0): two partial returns of one payment; ops link the
    later-dated one first (its allocation reversed on that date). The earlier-dated one would take
    money out of the payment on a day it was still allocated (I4, LG007): it waits for ops with a
    clear reason, and the other lines of the run (P1's return) are posted. Before the fix the run
    raised LG007, was retried, dead-lettered, and every later run failed the same way."""
    tenant = bank_tenant()
    store = storage()
    m, _ = _files(tenant)
    a = create_file(
        tenant,
        File(
            f"E-{uuid.uuid4().hex[:6]}",
            "b2b",
            "Ecart SA",
            [Item("F-1", {"principal": 50_000}, date(2026, 7, 1))],
        ),
    )
    prefix = f"OX{uuid.uuid4().hex[:4]}"
    ids = statement(tenant, store, [credit(200_000, rf=m.rf), credit(50_000, rf=a.rf)], prefix, DAY)
    p1, p = ids[f"{prefix}000000000001"], ids[f"{prefix}000000000002"]
    s1 = _statement_ids(tenant)[0]
    first, second = date(2026, 11, 1), date(2026, 11, 2)
    s2 = import_entries(
        tenant,
        store,
        [return_entry(30_000, _e2e(p), f"T{prefix}", first)],
        day=first,
        opening=closing(s1),
    )
    s3 = import_entries(
        tenant,
        store,
        [return_entry(20_000, _e2e(p), f"V{prefix}", second)],
        day=second,
        opening=closing(s2),
    )
    early, late = line_id(tenant, f"T{prefix}"), line_id(tenant, f"V{prefix}")
    assert review_of(early) == review_of(late) == "partial_return"
    api(
        tenant,
        "select public.link_debit(%s, %s, 'return', %s, null, '50000', 'retour partiel')",
        str(uuid.uuid4()),
        late,
        p,
    )
    assert state(p) == ("matched", "partial_return")  # 30 000 left: the early line's amount
    later = date(2026, 11, 4)
    import_entries(
        tenant,
        store,
        [return_entry(200_000, _e2e(p1), f"U{prefix}", later)],
        day=later,
        opening=closing(s3),
    )
    assert link_of(early) is None and review_of(early) == "before_previous_return"
    assert link_of(line_id(tenant, f"U{prefix}")) == ("return", p1, None, "auto")
    assert state(p1) == ("returned", None)
    with pytest.raises(psycopg.errors.CheckViolation, match="before_previous_return"):
        api(
            tenant,
            "select public.link_debit(%s, %s, 'return', %s, null, '30000', 'retour partiel')",
            str(uuid.uuid4()),
            early,
            p,
        )
    assert state(p) == ("matched", "partial_return")
    assert sum(client_money(tenant).values()) == 0
    assert violations(checks(tenant)["run_id"]) == []


def test_a_direct_payment_whose_job_dies_is_refused_not_left_in_progress() -> None:
    """Review fix (tests-ux #2): a dead-lettered direct-payment job records its failure on the
    request (refused, `failed`): the page stops showing « En cours » for good."""
    tenant = bank_tenant()
    store = storage()
    loan = create_file(
        tenant,
        File(
            f"G-{uuid.uuid4().hex[:6]}",
            "b2b",
            "Echec SA",
            [Item("F-1", {"principal": 30_000}, date(2026, 7, 1))],
        ),
    )
    doc = evidence(tenant, loan.id)
    out = api(
        tenant,
        "select public.record_direct_payment(%s, %s, '{}'::uuid[], '10000', '2026-10-20', %s,"
        " 'relevé client')",
        str(uuid.uuid4()),
        loan.id,
        doc,
    )
    ident = str(out["direct_payment_id"])
    handle = make_handler(store)

    def failing(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        if payload.get("direct_payment_id") == ident:
            raise RuntimeError("the worker fails on this job")
        handle(payload, conn)

    # retried once at once, then dead-lettered (the other messages handled as usual)
    consumer = QueueConsumer(
        DB, "payments", failing, on_dead=record_dead_job, max_attempts=1, backoff_base_s=0
    )
    while consumer.poll_once():
        pass
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select status, refusal_code from public.direct_payment where id = %s", (ident,)
        ).fetchone()
    assert row == ("refused", "failed")


def test_a_direct_payment_the_ledger_refuses_is_refused_failed_at_once() -> None:
    """Review fix (tests-ux #2): a plan the ledger refuses (planted here on this file's entries)
    would fail the same way on every retry: the job refuses the request `failed` at once."""
    tenant = bank_tenant()
    store = storage()
    loan = create_file(
        tenant,
        File(
            f"H-{uuid.uuid4().hex[:6]}",
            "b2b",
            "Refus SA",
            [Item("F-1", {"principal": 30_000}, date(2026, 7, 1))],
        ),
    )
    doc = evidence(tenant, loan.id)
    name = f"test_refuse_{uuid.uuid4().hex[:8]}"
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            f"""create function public.{name}() returns trigger language plpgsql as $$
                begin raise exception 'ledger: planted refusal' using errcode = 'LG007'; end $$"""
        )
        conn.execute(
            f"""create trigger {name} before insert on public.ledger_entry for each row
                when (new.account_id = '{loan.id}' and new.source_type = 'direct_payment')
                execute function public.{name}()"""
        )
    try:
        out = api(
            tenant,
            "select public.record_direct_payment(%s, %s, '{}'::uuid[], '10000', '2026-10-20', %s,"
            " 'relevé client')",
            str(uuid.uuid4()),
            loan.id,
            doc,
        )
        drain(store)
    finally:
        with psycopg.connect(DB) as conn, conn.transaction():
            conn.execute(f"drop trigger {name} on public.ledger_entry")
            conn.execute(f"drop function public.{name}()")
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            "select status, refusal_code, entry_id from public.direct_payment where id = %s",
            (out["direct_payment_id"],),
        ).fetchone()
    assert row == ("refused", "failed", None)
