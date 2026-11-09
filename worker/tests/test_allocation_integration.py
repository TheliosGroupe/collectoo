"""M2-09 allocation through the database (needs `make up`): statement import -> match -> allocation,
the ledger read back against the design's worked example (§8.2), and the ops actions: credit note,
reversal and re-allocation, overpayment used for another file of the same debtor, held payment
released on the judge's authorisation, forward of a recalled file's payment. Client notifications
(M2-11): one per allocation, reversal and forward entry, one per held payment."""

import threading
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
    entry_lines,
    evidence,
    ops,
    state,
    statement,
)
from integration_helpers import DB, as_user, one, storage
from statement_helpers import bank_tenant
from statement_helpers import drain as drain_payments

from collectoo_worker.jobs.allocation import run_allocate
from collectoo_worker.synth.reconciliation import line_ref

pytestmark = pytest.mark.integration
DAY = date(2026, 10, 12)


def _example(tenant: dict[str, Any]) -> tuple[File, File]:
    m42 = create_file(
        tenant,
        File(
            f"M-0042-{uuid.uuid4().hex[:6]}",
            "b2b",
            "Martin-Durand SARL",
            [
                Item("F-101", {"principal": 150_000}, date(2026, 6, 10)),
                Item("F-102", {"principal": 80_000}, date(2026, 7, 15)),
                Item("F-103", {"principal": 40_000}, date(2026, 8, 20)),
                Item("F-104", {"principal": 30_000}, date(2026, 12, 15)),
                Item("AV-105", {"principal": -20_000}, None, kind="credit_note"),
            ],
        ),
    )
    l9 = create_file(
        tenant,
        File(
            f"L-9-{uuid.uuid4().hex[:6]}",
            "consumer",
            "Lilas Dupont",
            [
                Item(
                    "PRET-9",
                    {"accrued_interest": 12_000, "principal": 500_000, "other_balances": 3_000},
                    None,
                    kind="loan_principal",
                )
            ],
        ),
    )
    return m42, l9


def _rf_in_text(rf: str) -> str:
    return " ".join(rf[i : i + 4] for i in range(0, len(rf), 4)).lower()


def _notifications(payment: str) -> list[tuple[str, str | None]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select n.kind, e.entry_type from public.client_notification n
               left join public.ledger_entry e on e.id = n.ledger_entry_id
               where n.payment_id = %s order by n.created_at, n.id""",
            (payment,),
        ).fetchall()
    return [(r[0], r[1]) for r in rows]


def _live_entries(payment: str) -> list[str]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select e.id::text from public.ledger_entry e
               where e.payment_id = %s and e.entry_type = 'allocation'
                 and not exists (select 1 from public.ledger_entry r where r.reverses_entry_id = e.id)
               order by e.id""",
            (payment,),
        ).fetchall()
    return [r[0] for r in rows]


def _proposal(tenant: dict[str, Any], account: str) -> dict[str, Any]:
    detail = ops(tenant, "select public.account_detail(%s)", account)
    assert detail["proposal"] is not None
    return dict(detail["proposal"])


def test_the_worked_example_end_to_end() -> None:  # noqa: PLR0915 - one story, step by step
    """§8.2: the credit note is proposed and holds P1 until ops apply it; P1 then pays F-103 (named),
    F-101 and part of F-102; P2 pays L-9's interest then principal, the consumer's unclassified
    amount is held back and 80,00 € stay over (never passed to the client); P3 waits for ops."""
    tenant = bank_tenant()
    m42, l9 = _example(tenant)
    store = storage()
    ids = statement(
        tenant,
        store,
        [
            credit(200_000, f"VIR MARTIN-DURAND REGLT F-103 {_rf_in_text(m42.rf)}"),
            credit(520_000, "ECHEANCE PRET", rf=l9.rf),
            credit(7_500, "REMBOURSEMENT", name="INCONNU"),
        ],
        "WX",
        DAY,
    )
    p1, p2, p3 = (ids[line_ref("WX", k)] for k in (1, 2, 3))

    # P1: matched by the RF in its text, F-103 named; the credit note must be applied first (1347)
    assert state(p1) == ("matched", "credit_note_to_apply")
    assert allocations(p1) == []
    # P2: interest first (1343-1), then principal; other_balances held (consumer, founder #6)
    assert state(p2) == ("partially_allocated", "overpayment")
    assert allocations(p2) == [
        ("PRET-9", "accrued_interest", 12_000),
        ("PRET-9", "principal", 500_000),
    ]
    (e3,) = _live_entries(p2)
    lines = entry_lines(e3)
    assert lines[:2] == [("unallocated_payment", None, None, 512_000), ("client_payable", None, None, -512_000)]
    assert sorted(x for x in lines[2:] if x[0] == "owner_claim") == [
        ("owner_claim", None, "accrued_interest", 12_000),
        ("owner_claim", None, "principal", 500_000),
    ]
    assert state(p3) == ("unmatched", "no_match")

    # E0: the proposal (AV-105 on F-101, the oldest due invoice, dated at the cut-off), one ops tap
    proposal = _proposal(tenant, m42.id)
    assert proposal["credit_ref"] == "AV-105"
    assert proposal["netting_date"] == "2026-09-30"
    assert [(t["item_ref"], t["amount_minor"]) for t in proposal["targets"]] == [("F-101", "20000")]
    ops(tenant, "select public.apply_credit_note(%s, %s, %s)", str(uuid.uuid4()), m42.id,
        proposal["proposal_key"])  # fmt: skip
    assert balances(m42)[("AV-105", "principal")] == 0
    assert balances(m42)[("F-101", "principal")] == 130_000
    drain_payments(store)  # P1 is ready again: allocated

    # E2: designated F-103 first, then due invoices oldest first; F-104 is not due and not reached
    assert state(p1) == ("allocated", None)
    assert allocations(p1) == [
        ("F-103", "principal", 40_000),
        ("F-101", "principal", 130_000),
        ("F-102", "principal", 30_000),
    ]
    (e2,) = _live_entries(p1)
    assert entry_lines(e2) == [
        ("unallocated_payment", None, None, 200_000),
        ("client_payable", None, None, -200_000),
        ("debtor_receivable", "F-103", "principal", -40_000),
        ("debtor_receivable", "F-101", "principal", -130_000),
        ("debtor_receivable", "F-102", "principal", -30_000),
        ("owner_claim", None, "principal", 200_000),
    ]
    b = balances(m42)
    assert (b[("F-102", "principal")], b[("F-104", "principal")]) == (50_000, 30_000)

    # Client money (I8): cash = what is left to allocate + what is owed to the client
    money = client_money(tenant)
    assert money["client_money_cash"] == 727_500
    assert money["unallocated_payment"] == -15_500  # U(P2) 8 000 + U(P3) 7 500
    assert money["client_payable"] == -712_000
    assert sum(money.values()) == 0

    # M2-11: one notification per allocation entry, none for the unmatched payment
    assert _notifications(p1) == [("payment_allocated", "allocation")]
    assert _notifications(p2) == [("payment_allocated", "allocation")]
    assert _notifications(p3) == []
    with psycopg.connect(DB) as conn:
        plans = conn.execute(
            """select engine_version, length(inputs_hash), designation is not null
               from private.allocation_plan where payment_id = any(%s::uuid[]) order by payment_id""",
            ([p1, p2],),
        ).fetchall()
    assert sorted(plans) == [("alloc-1", 64, False), ("alloc-1", 64, True)]

    # Idempotent: another run allocates nothing more
    with psycopg.connect(DB) as conn, conn.transaction():
        assert run_allocate(conn, {"organization_id": str(tenant["servicer"])}) == {"payments": 0}
    drain_payments(store)
    assert len(_live_entries(p1)) == 1


def test_a_reversed_allocation_waits_for_ops_and_reallocates_the_same_way() -> None:
    """A mistaken allocation is reversed at its date (receivables restored, client told); the payment
    waits (allocation_reversed); sent to allocation again, nothing having changed, it gives the same
    lines (founder #16: M3 re-runs allocations by date the same way)."""
    tenant = bank_tenant()
    f = create_file(
        tenant,
        File(
            f"M-{uuid.uuid4().hex[:6]}",
            "b2b",
            "Rivière SA",
            [
                Item("R-1", {"principal": 30_000}, date(2026, 8, 1)),
                Item("R-2", {"principal": 30_000}, date(2026, 8, 1)),  # same date: pro rata
                Item("R-3", {"principal": 40_000}, date(2026, 9, 1)),
            ],
        ),
    )
    store = storage()
    ids = statement(tenant, store, [credit(10_001, "REGLT", rf=f.rf)], "RV", DAY)
    p = ids[line_ref("RV", 1)]
    first = allocations(p)
    assert first == [("R-1", "principal", 5_001), ("R-2", "principal", 5_000)]  # leftover cent by id
    before = balances(f)
    entries = _live_entries(p)

    with pytest.raises(psycopg.errors.CheckViolation, match="allocation changed"):
        ops(tenant, "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
            str(uuid.uuid4()), p, f.id, [str(uuid.uuid4())], "erreur")  # fmt: skip
    key = str(uuid.uuid4())
    result = ops(tenant, "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
                 key, p, f.id, entries, "mauvaise imputation")  # fmt: skip
    again = ops(tenant, "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
                key, p, f.id, entries, "mauvaise imputation")  # fmt: skip
    assert again == result  # the same request replays its result
    assert state(p) == ("matched", "allocation_reversed")
    assert balances(f)[("R-1", "principal")] == 30_000
    assert _live_entries(p) == []
    assert _notifications(p) == [
        ("payment_allocated", "allocation"),
        ("payment_allocation_reversed", "reversal"),
    ]
    drain_payments(store)
    assert state(p) == ("matched", "allocation_reversed")  # never re-allocated by itself

    ops(tenant, "select public.allocate_payment(%s, %s, %s, null, null, %s)",
        str(uuid.uuid4()), p, "allocation_reversed", "désignation vérifiée")  # fmt: skip
    drain_payments(store)
    assert state(p) == ("allocated", None)
    assert allocations(p) == first
    assert balances(f) == before


def test_an_overpayment_stays_unallocated_or_pays_another_file_of_the_same_debtor() -> None:
    """Founder #8: what is over stays in 4710 for the payment (never forwarded); on the debtor's
    written request it pays another file of his, filed as evidence."""
    tenant = bank_tenant()
    a = create_file(
        tenant,
        File(f"A-{uuid.uuid4().hex[:6]}", "b2b", "Debiteur Commun SAS",
             [Item("A-1", {"principal": 10_000}, date(2026, 8, 1))]),
    )  # fmt: skip
    b = create_file(
        tenant,
        File(f"B-{uuid.uuid4().hex[:6]}", "b2b", "Debiteur Commun SAS",
             [Item("B-1", {"principal": 50_000}, date(2026, 8, 15))]),
        party_of=a,
    )  # fmt: skip
    other = create_file(
        tenant,
        File(f"C-{uuid.uuid4().hex[:6]}", "b2b", "Autre SAS",
             [Item("C-1", {"principal": 50_000}, date(2026, 8, 15))]),
    )  # fmt: skip
    store = storage()
    p = statement(tenant, store, [credit(25_000, "REGLT", rf=a.rf)], "OV", DAY)[line_ref("OV", 1)]
    assert state(p) == ("partially_allocated", "overpayment")
    assert allocations(p) == [("A-1", "principal", 10_000)]
    with pytest.raises(psycopg.errors.CheckViolation, match="nothing was allocated"):
        ops(tenant, "select public.forward_payment(%s, %s, null, %s, null, %s)",
            str(uuid.uuid4()), p, "15000", "au client")  # fmt: skip
    request = evidence(tenant, a.id)
    with pytest.raises(psycopg.errors.CheckViolation, match="same debtor"):
        ops(tenant, "select public.allocate_payment(%s, %s, 'overpayment', %s, %s, %s)",
            str(uuid.uuid4()), p, other.id, request, "courrier du débiteur")  # fmt: skip
    with pytest.raises(psycopg.errors.CheckViolation, match="written request"):
        ops(tenant, "select public.allocate_payment(%s, %s, 'overpayment', %s, null, %s)",
            str(uuid.uuid4()), p, b.id, "courrier du débiteur")  # fmt: skip
    ops(tenant, "select public.allocate_payment(%s, %s, 'overpayment', %s, %s, %s)",
        str(uuid.uuid4()), p, b.id, request, "courrier du débiteur du 13/10")  # fmt: skip
    drain_payments(store)
    assert state(p) == ("allocated", None)
    assert allocations(p) == [("A-1", "principal", 10_000), ("B-1", "principal", 15_000)]
    assert [k for k, _ in _notifications(p)] == ["payment_allocated", "payment_allocated"]


def test_a_held_payment_tells_the_client_and_is_allocated_on_the_judges_authorisation() -> None:
    tenant = bank_tenant()
    f = create_file(
        tenant,
        File(f"S-{uuid.uuid4().hex[:6]}", "consumer", "Jean Surendetté",
             [Item("PRET-S", {"principal": 80_000}, None, kind="loan_principal")]),
    )  # fmt: skip
    proof = evidence(tenant, f.id)
    ops(tenant, "select public.place_account_hold(%s, %s, 'surendettement', 'C. conso L722-5', %s, %s)",
        str(uuid.uuid4()), f.id, proof, "recevabilité")  # fmt: skip
    store = storage()
    p = statement(tenant, store, [credit(20_000, "ECHEANCE", rf=f.rf)], "HD", DAY)[line_ref("HD", 1)]
    assert state(p) == ("matched", "hold_blocks_allocation")
    assert _notifications(p) == [("payment_held", None)]
    with pytest.raises(psycopg.errors.CheckViolation, match="authorisation is required"):
        ops(tenant, "select public.release_hold_payment(%s, %s, null, %s)",
            str(uuid.uuid4()), p, "autorisation")  # fmt: skip
    authorisation = evidence(tenant, f.id)
    ops(tenant, "select public.release_hold_payment(%s, %s, %s, %s)",
        str(uuid.uuid4()), p, authorisation, "autorisation du JCP du 10/10")  # fmt: skip
    drain_payments(store)
    assert state(p) == ("allocated", None)
    assert allocations(p) == [("PRET-S", "principal", 20_000)]
    assert [k for k, _ in _notifications(p)] == ["payment_held", "payment_allocated"]
    # the hold stays: the next payment is held again (one notification per payment and file)
    q = statement(tenant, store, [credit(5_000, "ECHEANCE", rf=f.rf)], "HE", DAY)[line_ref("HE", 1)]
    assert state(q) == ("matched", "hold_blocks_allocation")


def test_a_payment_on_a_recalled_file_is_forwarded_to_the_client() -> None:
    tenant = bank_tenant()
    f = create_file(
        tenant,
        File(f"R-{uuid.uuid4().hex[:6]}", "b2b", "Rappel SA",
             [Item("X-1", {"principal": 10_000}, date(2026, 8, 1))], status="closed_recalled"),
    )  # fmt: skip
    store = storage()
    p = statement(tenant, store, [credit(4_000, "REGLT", rf=f.rf)], "FW", DAY)[line_ref("FW", 1)]
    assert state(p) == ("matched", "account_closed")
    with pytest.raises(psycopg.errors.CheckViolation, match="amount changed"):
        ops(tenant, "select public.forward_payment(%s, %s, null, %s, null, %s)",
            str(uuid.uuid4()), p, "3999", "dossier rappelé")  # fmt: skip
    ops(tenant, "select public.forward_payment(%s, %s, null, %s, null, %s)",
        str(uuid.uuid4()), p, "4000", "dossier rappelé par le client")  # fmt: skip
    assert state(p) == ("allocated", None)
    assert _notifications(p) == [("payment_forwarded", "forward")]
    assert balances(f)[("X-1", "principal")] == 10_000  # the debt is not touched
    with psycopg.connect(DB) as conn:
        payable = one(
            conn,
            """select sum(lp.amount_minor) from public.ledger_entry e
               join public.ledger_posting lp on lp.entry_id = e.id
               join public.ledger_account la on la.id = lp.ledger_account_id
               where e.payment_id = %s and la.book = 'client_payable'""",
            (p,),
        )
    assert payable == -4_000


def test_commands_wait_for_a_running_allocation_at_most_two_seconds() -> None:
    """The allocation lock (design §5.2): a reversal while an allocation of the servicer runs waits,
    then asks to retry (lock_timeout), never posting beside it."""
    tenant = bank_tenant()
    f = create_file(
        tenant,
        File(f"L-{uuid.uuid4().hex[:6]}", "b2b", "Verrou SA",
             [Item("V-1", {"principal": 10_000}, date(2026, 8, 1))]),
    )  # fmt: skip
    store = storage()
    p = statement(tenant, store, [credit(1_000, "REGLT", rf=f.rf)], "LK", DAY)[line_ref("LK", 1)]
    entries = _live_entries(p)
    errors: list[BaseException] = []
    with psycopg.connect(DB) as job, job.transaction():
        job.execute("select pg_advisory_xact_lock(hashtext('payments:' || %s))", (str(tenant["servicer"]),))

        def reverse() -> None:
            try:
                with psycopg.connect(DB) as conn, conn.transaction():
                    as_user(conn, tenant["staff"], "aal2")
                    conn.execute(
                        "select public.reverse_allocation(%s, %s, %s, %s::uuid[], %s)",
                        (str(uuid.uuid4()), p, f.id, entries, "erreur"),
                    )
            except BaseException as exc:  # reported below
                errors.append(exc)

        thread = threading.Thread(target=reverse)
        thread.start()
        thread.join(10)
    assert len(errors) == 1 and isinstance(errors[0], psycopg.errors.LockNotAvailable)
    assert _live_entries(p) == entries
