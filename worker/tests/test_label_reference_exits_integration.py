# ruff: noqa: E501 - SQL and long French labels read better unwrapped
"""M2c-7e-3 (needs `make up`; plan docs/design/m2c-7-plan.md §7.3's three exits, §7.4, §7.5;
ADR-0014 « M2c-7e-3 »): a CSV credit held `label_reference` because its label cites one of our
transfers leaves review through the real commands, as the API's session calls them (ops at aal2),
on lines the real import job and debit job held and reviewed.

- Exit (a): two runs booked from their camt.053 debits (the real jobs), then a CSV export of the
  account citing the first run's payout (RMT) — at exactly its amount, and 1,00 € under it. The
  options read class L and propose that payout's return of exactly its amount; booked
  (`book_transfer_line`): payout_returned, the payout returned, the run's chain no longer paid
  (`remittance_chain_paid`: returned, no paid date); the line short of it is refused
  label_reference_amount. The debit job's next pass books nothing more and writes no review back;
  the nightly (ten days on) lists only the line still held.
- Exits (b), (c) and the fourth: a CSV export citing a payout, then our top-up with no counterparty
  IBAN. « Règlement du client » for the tenant's client (`client_payment_line` then
  `book_client_payment_line` with the client) books client_payment; « Paiement d'un débiteur »
  (`release_own_credit`) makes the line a payment to assign, its payer the line's own name and
  IBAN; « C'est cet approvisionnement » (`book_top_up_credit` naming the TOP the label cites)
  books the top-up. After each, the review is gone, the debit job's pass leaves the line alone and
  the nightly lists none of them."""

from __future__ import annotations

import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from debit_helpers import api
from integration_helpers import DB, one, storage
from psycopg.types.json import Jsonb
from remittance_helpers import paris_today
from statement_helpers import bank_tenant, drain, upload
from test_label_references_integration import DEBTOR, _transfers
from test_transfer_files_integration import _two_runs
from test_transfer_line_foundations_integration import _booked

pytestmark = pytest.mark.integration
REASON = "Vu au relevé de la banque (test)"


def _csv(tenant: dict[str, Any], rows: list[tuple[date, str, int, str]]) -> str:
    """A CSV export of the account (`(day, label, credit minor, counterparty IBAN)`), imported
    through the payments queue (the import job, then the debit job it queues): its statement."""
    lines = ["Date;Libellé;Débit;Crédit;IBAN contrepartie"]
    for day, label, minor, iban in rows:
        lines.append(f"{day:%d/%m/%Y};{label};;{minor // 100},{minor % 100:02d};{iban}")
    target = upload(
        tenant,
        storage(),
        ("\n".join(lines) + "\n").encode(),
        name=f"releve-{uuid.uuid4().hex[:8]}.csv",
    )
    drain(storage())
    return str(target["statement_id"])


def _lines(sid: str) -> list[tuple[str, str, str | None, str | None]]:
    """The statement's lines: (id, kind, candidate, the debit job's review)."""
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select t.id::text, t.kind, t.reference_from_label, r.reason
               from public.bank_transaction t
               left join public.bank_debit_review r on r.bank_transaction_id = t.id
               where t.statement_id = %s order by t.line_no""",
            (sid,),
        ).fetchall()
    return [(str(r[0]), str(r[1]), r[2], r[3]) for r in rows]


def _state(line: str) -> tuple[list[str], str | None, int, int]:
    """A line's bookings, its review, its payments and its release rows."""
    with psycopg.connect(DB) as conn:
        bookings = [
            str(r[0])
            for r in conn.execute(
                "select kind from public.bank_line_booking where bank_transaction_id = %s order by seq",
                (line,),
            ).fetchall()
        ]
        row = conn.execute(
            "select reason from public.bank_debit_review where bank_transaction_id = %s", (line,)
        ).fetchone()
        review = None if row is None else str(row[0])
        paid = one(
            conn, "select count(*) from public.payment where bank_transaction_id = %s", (line,)
        )
        released = one(
            conn,
            "select count(*) from public.bank_own_credit_release where bank_transaction_id = %s",
            (line,),
        )
    return bookings, review, int(paid), int(released)


def _funds_pass(tenant: dict[str, Any]) -> None:
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select pgmq.send('payments', %s::jsonb)",
            (f'{{"type": "process_debits", "organization_id": "{tenant["servicer"]}"}}',),
        )
    drain(storage())


def _waiting(tenant: dict[str, Any]) -> list[str]:
    """The lines label_reference_waiting lists, ten days on (every line then past its bound)."""
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        check = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (tenant["servicer"],),
        )
        conn.execute(
            "select private.run_advance_checks(%s, %s, %s)",
            (check, tenant["servicer"], paris_today() + timedelta(days=10)),
        )
        return [
            str(r[0])
            for r in conn.execute(
                """select subject_id from public.payment_check_result
                   where run_id = %s and code = 'label_reference_waiting' order by amount_minor""",
                (check,),
            ).fetchall()
        ]


def test_the_return_of_exactly_our_payout_is_booked_and_the_run_reads_returned(
    tmp_path: Path,
) -> None:
    tenant, _other, _r1, _r2 = _two_runs()
    _data, paid = _booked(tenant, tmp_path)
    (e2e, n), _ = paid
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("update public.bank_account set feed = 'csv' where id = %s", (tenant["bank"],))
        transfer = str(
            one(conn, "select id from public.bank_transfer where end_to_end_id = %s", (e2e,))
        )
        before = one(conn, "select returned from private.remittance_chain_paid(%s)", (transfer,))
        returns = conn.execute(
            "select line_id::text from private.remittance_chain_events(%s) where delta < 0",
            (transfer,),
        ).fetchall()
    # (the fixture's bank debits the payout the day before its requested execution date: no paid date either way)
    assert (before, returns) == (False, [])
    day = paris_today()
    motif = "VIR SEPA RECU /DE DUPONT JEAN /MOTIF REMBOURSEMENT"
    sid = _csv(
        tenant, [(day, f"{motif} {e2e}", n, DEBTOR), (day, f"{motif} {e2e} B", n - 100, DEBTOR)]
    )
    (exact, _k1, c1, r1), (short, _k2, c2, r2) = _lines(sid)
    assert (c1, r1, c2, r2) == (e2e, "label_reference", e2e, "label_reference")
    assert _waiting(tenant) == [short, exact]
    # the options of the line at exactly the payout's amount: class L, the payout's return
    opts = api(tenant, "select public.transfer_line_options(%s)", exact)
    assert opts["class"] == "L" and opts["refusal"] is None, opts
    (proposal,) = opts["proposals"]
    assert proposal["request"] == [
        {"kind": "payout_returned", "transfer_id": transfer, "amount": str(n)}
    ]
    res = api(
        tenant,
        "select public.book_transfer_line(%s, %s, %s, %s, %s)",
        str(uuid.uuid4()),
        exact,
        Jsonb(proposal["request"]),
        proposal["preview"]["expected_text"],
        REASON,
    )
    assert [b["kind"] for b in res["bookings"]] == ["payout_returned"], res
    # the line 1,00 € under it: no return proposed (label_reference_amount)
    short_opts = api(tenant, "select public.transfer_line_options(%s)", short)
    assert (short_opts["class"], short_opts["refusal"], short_opts["proposals"]) == (
        "L",
        "label_reference_amount",
        [],
    )
    with psycopg.connect(DB) as conn:
        status = one(conn, "select status from public.bank_transfer where id = %s", (transfer,))
        after = conn.execute(
            "select paid_on, returned from private.remittance_chain_paid(%s)", (transfer,)
        ).fetchone()
        returns = conn.execute(
            "select line_id::text from private.remittance_chain_events(%s) where delta < 0",
            (transfer,),
        ).fetchall()
    # the run's chain reads the line booked as the payout's return, and only it (not the line short of it)
    assert status == "returned" and after == (None, True) and returns == [(exact,)]
    assert _state(exact) == (["payout_returned"], None, 0, 0)
    # the debit job's next pass: nothing more booked on it, no review back; the nightly lists the held line only
    _funds_pass(tenant)
    assert _state(exact) == (["payout_returned"], None, 0, 0)
    assert _state(short) == ([], "label_reference", 0, 0)
    assert _waiting(tenant) == [short]


def test_a_client_s_payment_a_debtor_s_payment_and_our_top_up_take_their_exits() -> None:
    tenant = bank_tenant(feed="csv")
    ids = _transfers(tenant)
    day = paris_today()
    tag = uuid.uuid4().hex[:6].upper()
    sid = _csv(
        tenant,
        [
            (day, f"VIR SEPA RECU /DE DUPONT JEAN /MOTIF REMB {ids['rmt']} {tag}", 30_000, DEBTOR),
            (
                day,
                f"VIR SEPA RECU /DE DURAND PAUL /MOTIF FACTURE {ids['rmt']} {tag}",
                20_000,
                DEBTOR,
            ),
            (
                day,
                f"VIR SEPA RECU /DE COLLECTOO SAS /MOTIF APPROVISIONNEMENT COMPTE DEDIE {ids['top']}",
                4_700,
                "",
            ),
        ],
    )
    (client_line, _k1, c1, r1), (debtor_line, _k2, c2, r2), (top_line, _k3, c3, r3) = _lines(sid)
    assert (c1, c2, c3) == (ids["rmt"], ids["rmt"], ids["top"])
    assert (r1, r2, r3) == ("label_reference",) * 3
    assert sorted(_waiting(tenant)) == sorted([client_line, debtor_line, top_line])
    # (b) « Règlement du client »: the preview for the client named, then the booking
    facts = api(
        tenant,
        "select public.client_payment_line(%s, null, null, %s)",
        client_line,
        tenant["client"],
    )
    assert (facts["client_id"], facts["refusal"]) == (str(tenant["client"]), None), facts
    with pytest.raises(psycopg.errors.CheckViolation, match="client_required"):
        api(
            tenant,
            "select public.book_client_payment_line(%s, %s, null, null, null, %s, %s)",
            str(uuid.uuid4()),
            client_line,
            facts["preview"]["open_minor"],
            REASON,
        )
    booked = api(
        tenant,
        "select public.book_client_payment_line(%s, %s, null, null, null, %s, %s, %s)",
        str(uuid.uuid4()),
        client_line,
        facts["preview"]["open_minor"],
        REASON,
        tenant["client"],
    )
    assert booked["entry_id"], booked
    # (c) « Paiement d'un débiteur »
    released = api(
        tenant,
        "select public.release_own_credit(%s, %s, %s)",
        str(uuid.uuid4()),
        debtor_line,
        REASON,
    )
    assert released["status"] == "unmatched", released
    assert (
        released["note"] == "Paiement d'un débiteur citant notre référence (vérifié par l'équipe)"
    )
    with psycopg.connect(DB) as conn:
        payer = conn.execute(
            "select payer_iban, review_reason from public.payment where bank_transaction_id = %s",
            (debtor_line,),
        ).fetchone()
        top = str(
            one(conn, "select id from public.bank_transfer where end_to_end_id = %s", (ids["top"],))
        )
    assert payer == (DEBTOR, "no_match")
    # the fourth exit: « C'est cet approvisionnement »
    topped = api(
        tenant,
        "select public.book_top_up_credit(%s, %s, %s, %s)",
        str(uuid.uuid4()),
        top_line,
        top,
        "Notre approvisionnement, relevé sans le compte émetteur (test)",
    )
    assert topped["status"] == "booked", topped
    assert _state(client_line) == (["client_payment"], None, 0, 0)
    assert _state(debtor_line) == ([], None, 1, 1)
    assert _state(top_line) == (["top_up"], None, 0, 0)
    with psycopg.connect(DB) as conn:
        assert (
            one(conn, "select status from public.bank_transfer where id = %s", (top,)) == "booked"
        )
    # the debit job's next pass leaves them alone; the nightly lists none of them
    _funds_pass(tenant)
    assert _state(client_line) == (["client_payment"], None, 0, 0)
    assert _state(debtor_line) == ([], None, 1, 1)
    assert _state(top_line) == (["top_up"], None, 0, 0)
    assert _waiting(tenant) == []
