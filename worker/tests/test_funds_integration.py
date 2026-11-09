"""M2c-1 through the database (needs `make up`): our own transfers classified at import the same way
in Python and SQL (parity on random lines), and a camt.053 statement of the dedicated account
imported through the payments queue — the bank's charge and the top-up we ordered (TOP id) booked
by the debit job, a credit from our own account and a plain debit booked by ops, our transfer out
explained — after which 5120 is the bank's closing balance less the one line explained, and the
nightly checks find nothing (I8', I12, I13, I14, I19). Design docs/design/m2c-remittances.md
§5, §12, §15, §18; acceptance « 5120 = bank after fees and top-ups »."""

import random
import uuid
from datetime import date
from typing import Any

import psycopg
import pytest
from debit_helpers import api, checks, import_entries, line_id, review_of, violations
from hypothesis import given, settings
from hypothesis import strategies as st
from integration_helpers import DB, one, storage
from statement_helpers import bank_tenant, drain

from collectoo_worker.payments.statement import KnownIbans, refine_kind
from collectoo_worker.synth.camt053 import Entry, Tx
from collectoo_worker.synth.ids import iban_fr

pytestmark = pytest.mark.integration
DAY = date(2026, 11, 6)
OWN = "FR7030001007940000000002002"
CLIENT = "FR0930001007940000000003003"
IBANS = KnownIbans(own=frozenset({OWN}), clients=frozenset({CLIENT}))
KINDS = (
    "debtor_credit",
    "return",
    "refund_out",
    "other_debit",
    "batch_unsplit",
    "transfer_out",
    "own_transfer_in",
    "client_transfer_in",
)


@pytest.fixture(scope="module")
def parity_conn() -> Any:
    with psycopg.connect(DB) as conn:
        yield conn


@settings(max_examples=300, deadline=None)
@given(
    kind=st.sampled_from(KINDS),
    direction=st.sampled_from(["credit", "debit"]),
    e2e=st.one_of(
        st.none(),
        st.from_regex(r"(TOP|RMT|SWP|RFD|E2E|top)[0-9A-Fa-f]{10,13}", fullmatch=True),
        st.text(
            st.characters(blacklist_characters="\x00", blacklist_categories=["Cs"]), max_size=20
        ),
    ),
    iban=st.one_of(st.none(), st.sampled_from([OWN, CLIENT, "FR7630004000031234567890143"])),
)
def test_python_and_sql_classify_our_own_transfers_alike(
    parity_conn: psycopg.Connection[Any],
    kind: str,
    direction: str,
    e2e: str | None,
    iban: str | None,
) -> None:
    row = parity_conn.execute(
        "select private.bank_line_refined_kind(%s, %s, %s, %s, %s, %s)",
        (kind, direction, e2e, iban, sorted(IBANS.own), sorted(IBANS.clients)),
    ).fetchone()
    assert row is not None
    assert row[0] == refine_kind(kind, direction, e2e, iban, IBANS)


def _own_account(tenant: dict[str, Any]) -> tuple[str, str]:
    iban = iban_fr(random.Random(f"own-{tenant['servicer']}"))
    with psycopg.connect(DB) as conn, conn.transaction():
        own = one(
            conn,
            """insert into public.bank_account (organization_id, purpose, iban, currency, label,
                 opened_on) values (%s, 'own', %s, 'EUR', 'Compte propre', '2026-01-01')
               returning id""",
            (tenant["servicer"], iban),
        )
    return str(own), iban


def _cash(bank: str) -> int:
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_account la
               join public.ledger_posting p on p.ledger_account_id = la.id
               where la.bank_account_id = %s and la.book = 'client_money_cash'""",
            (bank,),
        ).fetchone()
    assert row is not None
    return int(row[0])


def _bookings(line: str) -> list[tuple[str, str, int]]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select k.kind, e.entry_type, k.amount_minor from public.bank_line_booking k
               join public.ledger_entry e on e.id = k.entry_id
               where k.bank_transaction_id = %s order by k.seq""",
            (line,),
        ).fetchall()
    return [(r[0], r[1], int(r[2])) for r in rows]


def test_5120_is_the_bank_after_fees_and_top_ups() -> None:
    store = storage()
    tenant = bank_tenant()
    own, own_iban = _own_account(tenant)
    top = api(
        tenant,
        "select public.request_top_up(%s, %s, %s, '20000', 'couvrir les frais du compte dédié')",
        str(uuid.uuid4()),
        own,
        tenant["bank"],
    )
    assert top["payee_iban"] == tenant["iban"] and top["end_to_end_id"].startswith("TOP")
    tag = uuid.uuid4().hex[:6].upper()
    debtor = iban_fr(random.Random(tag))

    def credit(n: int, amount: int, e2e: str, iban: str, name: str | None = None) -> Entry:
        tx = Tx(amount, ref=f"A{n}{tag}", end_to_end_id=e2e, iban=iban, name=name)
        return Entry(amount, True, DAY, DAY, ref=f"N{n}{tag}", txs=(tx,))

    def debit(n: int, amount: int, e2e: str, name: str, pmtinf: str | None = None) -> Entry:
        tx = Tx(amount, ref=f"A{n}{tag}", end_to_end_id=e2e, name=name)
        return Entry(
            amount, False, DAY, DAY, ref=f"N{n}{tag}", code="PMNT/ICDT/ESCT", txs=(tx,),
            payment_info_id=pmtinf,
        )  # fmt: skip

    entries = [
        credit(1, 100_000, f"E2E-{tag}", debtor, "DURAND"),  # a debtor's payment
        credit(2, 20_000, top["end_to_end_id"], own_iban),  # the top-up we ordered (TOP id)
        Entry(150, False, DAY, DAY, ref=f"A3{tag}", code="ACMT/MDOP/CHRG", info="FRAIS"),
        credit(4, 3_000, f"OWN-{tag}", own_iban),  # from our own account, no order
        debit(5, 50, f"FRS-{tag}", "PRESTATAIRE"),  # a debit ops call a fee
        debit(6, 700, "RMT0123456789AB", "MARTIN SAS", f"PI-{tag}"),  # our transfer out
    ]
    statement = import_entries(tenant, store, entries, day=DAY, opening=0)
    closing = 100_000 + 20_000 - 150 + 3_000 - 50 - 700

    # the debit job (queued by the import) booked the charge and the ordered top-up
    charge, top_line = line_id(tenant, f"A3{tag}"), line_id(tenant, f"A2{tag}")
    assert _bookings(charge) == [("fee", "bank_fee", 150)]
    assert _bookings(top_line) == [("top_up", "servicer_top_up", 20_000)]
    with psycopg.connect(DB) as conn:
        status = one(
            conn, "select status from public.bank_transfer where id = %s", (top["transfer_id"],)
        )
        payments = conn.execute(
            "select count(*), sum(amount_minor) from public.payment where bank_account_id = %s",
            (tenant["bank"],),
        ).fetchone()
    assert status == "booked"
    assert payments == (1, 100_000)  # our own credits are never debtor payments
    own_credit, plain, ours = (line_id(tenant, f"A{n}{tag}") for n in (4, 5, 6))
    assert review_of(own_credit) == "top_up_not_found"
    assert review_of(ours) == "own_transfer_out"
    assert review_of(plain) is None  # an other debit waits in « Frais » without a review

    # ops: the credit from the own account is a top-up, the plain debit a fee, ours explained
    for line, kind, why in (
        (own_credit, "own_credit", "virement du compte propre"),
        (plain, "fee", "frais de tenue de compte"),
        (ours, "explained", "virement manuel, comptabilisé avec les reversements (M2c-6)"),
    ):
        api(
            tenant,
            "select public.link_debit(%s, %s, %s, null, null, null, %s)",
            str(uuid.uuid4()),
            line,
            kind,
            why,
        )
    assert _bookings(own_credit) == [("top_up", "servicer_top_up", 3_000)]
    assert _bookings(plain) == [("fee", "bank_fee", 50)]

    # 5120 = the bank's closing balance less the line explained, not booked (I9): fees, top-ups
    with psycopg.connect(DB) as conn:
        unposted = conn.execute(
            "select minor, lines from private.bank_unposted(%s, %s)", (tenant["bank"], DAY)
        ).fetchone()
    assert unposted == (-700, 1)
    assert _cash(tenant["bank"]) == closing + 700
    assert _cash(tenant["bank"]) + unposted[0] == closing

    # the queue left nothing behind; the nightly checks find no violation
    drain(store)
    run = checks(tenant)
    assert violations(str(run["run_id"])) == []
    with psycopg.connect(DB) as conn:
        servicer_fund = one(
            conn,
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_account la
               join public.ledger_book b on b.code = la.book and b.money_of = 'servicer'
               join public.ledger_posting p on p.ledger_account_id = la.id
               where la.organization_id = %s""",
            (tenant["servicer"],),
        )
        own_cash = one(
            conn,
            """select coalesce(sum(p.amount_minor), 0) from public.ledger_account la
               join public.ledger_posting p on p.ledger_account_id = la.id
               where la.bank_account_id = %s and la.book = 'own_cash'""",
            (own,),
        )
        pmtinf = one(
            conn, "select payment_info_id from public.bank_transaction where id = %s", (ours,)
        )
    assert servicer_fund == 0
    assert own_cash == -23_000  # what the own account put in (5122 is not its bank balance)
    assert pmtinf == f"PI-{tag}"
    del statement
