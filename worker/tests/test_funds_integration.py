"""M2c-1 through the database (needs `make up`): our own transfers classified at import the same way
in Python and SQL (parity on random lines), and a camt.053 statement of the dedicated account
imported through the payments queue — the bank's charge and the top-up we ordered (TOP id) booked
by the debit job, a credit from our own account and a plain debit booked by ops, our transfer out
explained — after which 5120 is the bank's closing balance less the one line explained, and the
nightly checks find nothing (I8', I12, I13, I14, I19). Design docs/design/m2c-remittances.md
§5, §12, §15, §18; acceptance « 5120 = bank after fees and top-ups ». Then the review fixes: a
credit from our own account released by ops as a debtor's payment the servicer relayed (a payment
to assign, its cash_in, nothing left unposted, no violation); one decision per bank line when two
sessions decide it at once (the line's lock: the second waits, then is refused); a top-up ordered
while its own account is being closed waits for the close and is refused."""

import json
import random
import threading
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import date
from typing import Any

import psycopg
import pytest
from debit_helpers import API_DB, api, checks, import_entries, line_id, review_of, violations
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


def _statement(tenant: dict[str, Any], own_iban: str, tag: str) -> int:
    """A statement of the dedicated account: a debtor's payment, a credit from our own account (no
    TOP id: a debtor's payment the servicer relayed), two plain debits, a second own credit; the
    payments queue drained. Returns the closing balance."""
    debtor = iban_fr(random.Random(tag))

    def credit(n: int, amount: int, iban: str, text: str) -> Entry:
        tx = Tx(amount, ref=f"A{n}{tag}", end_to_end_id=f"E{n}-{tag}", iban=iban, ustrd=(text,))
        return Entry(amount, True, DAY, DAY, ref=f"N{n}{tag}", txs=(tx,))

    def debit(n: int, amount: int) -> Entry:
        tx = Tx(amount, ref=f"A{n}{tag}", end_to_end_id=f"E{n}-{tag}", name="PRESTATAIRE")
        return Entry(amount, False, DAY, DAY, ref=f"N{n}{tag}", code="PMNT/ICDT/ESCT", txs=(tx,))

    entries = [
        credit(1, 100_000, debtor, "FACTURE F-1"),
        credit(2, 25_000, own_iban, "REGLEMENT DURAND DOSSIER D-77"),
        debit(3, 40),
        debit(4, 60),
        credit(5, 7_000, own_iban, "VERSEMENT"),
    ]
    import_entries(tenant, storage(), entries, day=DAY, opening=0)
    return 100_000 + 25_000 - 40 - 60 + 7_000


def test_an_own_credit_released_as_a_relayed_debtor_payment() -> None:
    tenant = bank_tenant()
    _own, own_iban = _own_account(tenant)
    tag = uuid.uuid4().hex[:6].upper()
    closing = _statement(tenant, own_iban, tag)
    relay = line_id(tenant, f"A2{tag}")
    assert review_of(relay) == "top_up_not_found"  # the job never takes it for a debtor payment

    key = str(uuid.uuid4())
    reason = "M. Durand a payé le cabinet sur son compte ; reversé sur le compte dédié"
    out = api(tenant, "select public.release_own_credit(%s, %s, %s)", key, relay, reason)
    assert set(out) == {"payment_id", "status"}
    assert out["status"] == "unmatched"
    assert api(tenant, "select public.release_own_credit(%s, %s, %s)", key, relay, reason) == out
    with psycopg.connect(DB) as conn:
        payment = conn.execute(
            """select status, review_reason, payer_name, payer_iban, amount_minor, booking_date,
                      remittance_text
               from public.payment where id = %s and bank_transaction_id = %s""",
            (out["payment_id"], relay),
        ).fetchone()
    assert payment == (
        "unmatched",
        "no_match",
        "Versement relayé par le cabinet",
        None,
        25_000,
        DAY,
        "REGLEMENT DURAND DOSSIER D-77",
    )
    assert review_of(relay) is None

    # the other lines decided by ops; the queue drained: nothing changes the released payment
    for line, kind, why in (
        (line_id(tenant, f"A3{tag}"), "fee", "frais de tenue de compte"),
        (line_id(tenant, f"A4{tag}"), "fee", "commission d'intervention"),
        (line_id(tenant, f"A5{tag}"), "own_credit", "approvisionnement du compte dédié"),
    ):
        api(
            tenant,
            "select public.link_debit(%s, %s, %s, null, null, null, %s)",
            str(uuid.uuid4()),
            line,
            kind,
            why,
        )
    drain(storage())
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.payment where id = %s", (out["payment_id"],))
        unposted = conn.execute(
            "select minor, lines from private.bank_unposted(%s, %s)", (tenant["bank"], DAY)
        ).fetchone()
    assert status == "unmatched"  # waits in « Paiements à traiter » for ops to assign it
    assert unposted == (0, 0)  # every line is in the ledger
    assert _cash(tenant["bank"]) == closing  # 5120 = the bank (I9)
    run = checks(tenant)
    assert violations(str(run["run_id"])) == []  # I11 (its cash_in), I19, I8', I12, I13, I14


def _session(user: str) -> psycopg.Connection[Any]:
    """An API session (authenticator, then the authenticated role at aal2) with its transaction
    left open: the caller commits."""
    conn = psycopg.connect(API_DB)
    claims = json.dumps({"sub": user, "role": "authenticated", "aal": "aal2"})
    conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
    conn.execute("set local role authenticated")
    conn.execute("set local statement_timeout = '8s'")
    return conn


@contextmanager
def _second_session(user: str, sql: str, params: tuple[Any, ...]) -> Iterator[dict[str, Any]]:
    """Runs `sql` in another session (a thread) while the block runs; yields what it reports: its
    backend pid once connected, then `error` (the message it was refused with, or None)."""
    out: dict[str, Any] = {}
    ready = threading.Event()

    def run() -> None:
        try:
            with _session(user) as conn:
                out["pid"] = conn.info.backend_pid
                ready.set()
                conn.execute(sql, params)
                conn.commit()
            out["error"] = None
        except psycopg.Error as exc:
            out["error"] = exc.diag.message_primary
        finally:
            ready.set()

    thread = threading.Thread(target=run)
    thread.start()
    assert ready.wait(10)
    try:
        yield out
    finally:
        thread.join(15)
    assert not thread.is_alive()


def _waits_for_a_lock(pid: int) -> bool:
    """True once the session waits on a lock (polled for 1.5 s at most: the commands wait 2 s)."""
    with psycopg.connect(DB, autocommit=True) as conn:
        for _ in range(150):
            row = conn.execute(
                "select wait_event_type from pg_stat_activity where pid = %s", (pid,)
            ).fetchone()
            if row is not None and row[0] == "Lock":
                return True
            time.sleep(0.01)
    return False


def _decisions(line: str) -> list[str]:
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select 'link:' || kind from public.bank_debit_link where bank_transaction_id = %s
               union all
               select 'booking:' || kind from public.bank_line_booking
               where bank_transaction_id = %s
               union all
               select 'release' from public.bank_own_credit_release
               where bank_transaction_id = %s""",
            (line, line, line),
        ).fetchall()
    return sorted(str(r[0]) for r in rows)


LINK = "select public.link_debit(%s, %s, %s, null, null, null, %s)"
RELEASE = "select public.release_own_credit(%s, %s, %s)"
LINKED = "bank booking refused: already_linked"
BOOKED = "bank booking refused: already_booked"
LINE_BOOKED = "debit link refused: already_booked"
RELEASED = "own credit release refused: already_booked"
STEPS = [
    (("link", "explained"), ("link", "fee"), LINKED, "link:explained"),
    (("link", "fee"), ("link", "explained"), LINE_BOOKED, "booking:fee"),
    (("release", ""), ("link", "own_credit"), BOOKED, "release"),
    (("link", "own_credit"), ("release", ""), RELEASED, "booking:top_up"),
]


@pytest.mark.parametrize(("first", "second", "refused", "decided"), STEPS)
def test_a_bank_line_is_decided_once_when_two_sessions_decide_it_at_once(
    first: tuple[str, str], second: tuple[str, str], refused: str, decided: str
) -> None:
    """Review fix (money #0, security #0): an M2b link and a booking in the funds (or an own credit
    released) take the same lock, the line's row: the second session waits for the first, then
    reads its decision and is refused. Before, both committed (a line linked as a refund and booked
    as a fee took 5120 down twice)."""
    tenant = bank_tenant()
    _own, own_iban = _own_account(tenant)
    tag = uuid.uuid4().hex[:6].upper()
    _statement(tenant, own_iban, tag)
    line = line_id(tenant, f"A3{tag}" if first[1] in ("explained", "fee") else f"A2{tag}")

    def call(step: tuple[str, str]) -> tuple[str, tuple[Any, ...]]:
        if step[0] == "release":
            return RELEASE, (str(uuid.uuid4()), line, "un paiement relayé")
        return LINK, (str(uuid.uuid4()), line, step[1], "décision d'ops")

    sql_a, params_a = call(first)
    sql_b, params_b = call(second)
    a = _session(tenant["staff"])
    try:
        a.execute(sql_a, params_a)  # decided, not committed yet
        with _second_session(tenant["staff"], sql_b, params_b) as b:
            waited = _waits_for_a_lock(int(b["pid"]))
            a.commit()
    finally:
        a.close()
    assert waited, "the second session did not wait for the line's lock"
    assert b["error"] == refused
    assert _decisions(line) == [decided]


def test_a_top_up_ordered_while_its_own_account_closes_waits_and_is_refused() -> None:
    """Review fix (security #1): request_top_up locks both accounts before checking them, so a
    close of the own account in flight is waited for and seen (the order is refused), never
    committed with a top-up in flight from a closed account."""
    tenant = bank_tenant()
    own, _iban = _own_account(tenant)
    admin = uuid.uuid4()
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "insert into auth.users (id, email, aud, role)"
            " values (%s, %s, 'authenticated', 'authenticated')",
            (admin, f"{admin}@s.test"),
        )
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'admin')",
            (admin, tenant["servicer"]),
        )
    a = _session(str(admin))
    try:
        a.execute(
            "select public.close_bank_account(%s, %s, %s)",
            (str(uuid.uuid4()), own, "compte clôturé"),
        )
        with _second_session(
            tenant["staff"],
            "select public.request_top_up(%s, %s, %s, '1000', 'couvrir les frais')",
            (str(uuid.uuid4()), own, tenant["bank"]),
        ) as b:
            waited = _waits_for_a_lock(int(b["pid"]))
            a.commit()
    finally:
        a.close()
    assert waited
    assert b["error"] == (
        "top-up: from an active own account to an active client_funds account in the same currency"
    )
    with psycopg.connect(DB) as conn:
        orders = one(
            conn,
            "select count(*) from public.bank_transfer where debtor_bank_account_id = %s",
            (own,),
        )
    assert orders == 0
