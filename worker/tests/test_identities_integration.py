"""M2c-2 through the database (needs `make up`): a client's payout IBAN with its RIB, proposed by
ops and confirmed by a second person (the client's administrator at aal2, founder #10), through the
commands as the API runs them; a credit from that IBAN on the dedicated account is then the
client's money (`client_transfer_in`, design §12) — read so by the parser and by the import — and
never a debtor payment, while the same credit before the confirmation was one. Design
docs/design/m2c-remittances.md §6.1, §12, §16."""

import hashlib
import json
import random
import uuid
from datetime import date
from typing import Any

import psycopg
import pytest
from debit_helpers import API_DB, import_entries, line_id, review_of
from integration_helpers import DB, one, storage
from statement_helpers import bank_tenant

from collectoo_worker.synth.camt053 import Entry, Tx
from collectoo_worker.synth.ids import iban_fr

pytestmark = pytest.mark.integration
DAY = date(2026, 11, 6)


def _as(user: str, sql: str, *params: Any, aal: str = "aal2") -> Any:
    """A command as `user`, in a session like the API's (authenticated role, JWT claims)."""
    with psycopg.connect(API_DB) as conn, conn.transaction():
        claims = json.dumps({"sub": user, "role": "authenticated", "aal": aal})
        conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
        conn.execute("set local role authenticated")
        row = conn.execute(sql, params).fetchone()
    return row[0] if row else None


def _payments(tenant: dict[str, Any]) -> int:
    with psycopg.connect(DB) as conn:
        return int(
            one(
                conn,
                "select count(*) from public.payment where bank_account_id = %s",
                (tenant["bank"],),
            )
        )


def _kind(line: str) -> str:
    with psycopg.connect(DB) as conn:
        return str(one(conn, "select kind from public.bank_transaction where id = %s", (line,)))


def test_a_confirmed_payout_iban_makes_its_credits_the_clients_money() -> None:
    store = storage()
    tenant = bank_tenant()
    client_iban = iban_fr(random.Random(f"client-{tenant['client']}"))
    tag = uuid.uuid4().hex[:6].upper()

    def credit(n: int, amount: int) -> Entry:
        tx = Tx(amount, ref=f"A{n}{tag}", end_to_end_id=f"E{n}-{tag}", iban=client_iban, name="C")
        return Entry(amount, True, DAY, DAY, ref=f"N{n}{tag}", txs=(tx,))

    # before any confirmation, a credit from that IBAN is read as a debtor's payment
    import_entries(tenant, store, [credit(1, 5_000)], day=DAY, opening=0)
    assert _kind(line_id(tenant, f"A1{tag}")) == "debtor_credit"
    assert _payments(tenant) == 1

    # ops upload the client's RIB at its key and register it, then propose the IBAN
    rib = f"%PDF-1.4 RIB synthétique {tag}".encode()
    doc_id = uuid.uuid4()
    key = f"client/{tenant['servicer']}/{tenant['client']}/{doc_id}.pdf"
    store.upload("documents", key, rib, "application/pdf")
    document = _as(
        tenant["staff"],
        "select public.register_client_document(%s, %s, 'payout_rib', %s, 'RIB.pdf', %s,"
        " 'application/pdf')",
        str(uuid.uuid4()),
        tenant["client"],
        key,
        hashlib.sha256(rib).hexdigest(),
    )
    proposal = _as(
        tenant["staff"],
        "select public.propose_payout_account(%s, %s, 'EUR', %s, 'C SAS', null, %s)",
        str(uuid.uuid4()),
        tenant["client"],
        client_iban,
        document["document_id"],
    )
    account = proposal["payout_account_id"]
    # a proposal is not yet the client's: still a debtor's payment
    import_entries(tenant, store, [credit(2, 6_000)], day=DAY, opening=5_000)
    assert _kind(line_id(tenant, f"A2{tag}")) == "debtor_credit"

    # the person who proposed it cannot confirm it; the client's administrator does, at aal2
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        _as(tenant["staff"], "select public.confirm_payout_account(%s, %s, %s)",
            str(uuid.uuid4()), account, client_iban)  # fmt: skip
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        _as(tenant["user"], "select public.confirm_payout_account(%s, %s, %s)",
            str(uuid.uuid4()), account, client_iban, aal="aal1")  # fmt: skip
    confirmed = _as(
        tenant["user"],
        "select public.confirm_payout_account(%s, %s, %s)",
        str(uuid.uuid4()),
        account,
        client_iban,
    )
    assert confirmed["confirmed_via"] == "client_portal"

    # from now on a credit from it is the client's money: no payment, left to ops with why
    import_entries(tenant, store, [credit(3, 7_000)], day=DAY, opening=11_000)
    line = line_id(tenant, f"A3{tag}")
    assert _kind(line) == "client_transfer_in"
    assert review_of(line) == "client_credit"
    assert _payments(tenant) == 2
