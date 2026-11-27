# ruff: noqa: E501 - SQL fixtures read better unwrapped
"""M2c-7e-3 (needs `make up`; ADR-0014 « M2c-7e-3 »): the exits' reads by a parameter or a correlated
key stay keyed whatever the statistics — the plan class that broke main after 7a (a key the last
analyse saw with two values, priced at half the table: a sequential scan, a hash of the whole table,
a partial index whose predicate a parameter's filter implies).

In the test's rolled-back transaction the tables 7e-2's reads test plants are planted the same way
(`test_label_reference_reads_integration._plant`: PLANTED rows of two other servicers' transfers,
statement lines, resolutions, reviews, links, bookings, releases and runs, each analysed with its
keys' n_distinct pinned at 2; every plan generic). Then, on a servicer whose runs were booked from
their camt.053 debits (the real jobs) and whose CSV export holds four credits held label_reference
(the import job, the debit job's reviews), each exit as the API's session takes it — « Comptabiliser… »
(public.transfer_line_options, then public.book_transfer_line: private.transfer_line_class, _pre,
_check, _options_of, the booking guard), the chain's paid date after the return
(private.remittance_chain_paid: private.remittance_chain_events), « Règlement du client »
(public.client_payment_line, public.book_client_payment_line: private.client_line_facts, the guard),
« Paiement d'un débiteur » (public.release_own_credit: the release and payment guards) and « C'est
cet approvisionnement » (public.book_top_up_credit: the re-check, the guard) — and the rows each read
from the planted tables: a few per call, never the planted rows. The nightly that reads the chain's
events (private.run_remittance_runs_checks' booked branch) is bounded by the same nightly on 7e-2's
remittance_chain_events body (read from its migration file), plus PER_CALL."""

from __future__ import annotations

import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import DB, one, storage
from psycopg.types.json import Jsonb
from remittance_helpers import paris_today
from statement_helpers import drain, upload
from test_client_payment_reads_integration import _as
from test_label_reference_reads_integration import PLANTED, WATCHED, _plant
from test_label_references_integration import DEBTOR
from test_transfer_files_integration import _two_runs
from test_transfer_line_foundations_integration import _booked

pytestmark = pytest.mark.integration
PER_CALL = 60
REASON = "Vu au relevé de la banque (test)"
MIGRATIONS = Path(__file__).resolve().parents[2] / "supabase/migrations"
EVENTS_BEFORE_7E3 = (
    "20261118100000_switch_on_prerequisites_2.sql",
    "create or replace function private.remittance_chain_events(",
)


# (review round 1, CC-1) release_own_credit's payer reads the line's IBAN among the servicer's clients' payout accounts
# (as client_line_facts does): planted too — the servicer's own and another servicer's over two IBANs, both keys'
# n_distinct pinned at 2
EXIT_WATCHED = (*WATCHED, "public.client_payout_account")
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"
# (review round 2) other servicers' current (active) payout accounts planted beside the retired ones
CURRENT_PLANTED = 300


def _plant_payout_accounts(conn: psycopg.Connection[Any], org: str) -> None:
    conn.execute("set local session_replication_role = replica")
    conn.execute(
        "alter table public.client_payout_account disable trigger client_payout_account_guard"
    )
    conn.execute(
        f"""insert into public.client_payout_account (organization_id, client_organization_id, currency, iban,
             holder_name, evidence_document_id, proposed_by, status, confirmed_by, confirmed_at, confirmed_via,
             closed_by, closed_at, closed_reason)
           select (array['{org}'::uuid, gen_random_uuid()])[1 + g % 2], k.client[1 + g % 2], 'EUR',
                  (array['FR7630006000011234567890189', 'FR7688685684899121950048661'])[1 + g % 2],
                  'PLANTED', gen_random_uuid(), gen_random_uuid(), 'retired', gen_random_uuid(), now(),
                  'second_admin', gen_random_uuid(), now(), 'Planted'
           from (select {TWO} client) k, generate_series(1, {PLANTED}) g"""  # noqa: S608 - the tests' own constants
    )
    # (review round 2) other servicers' current accounts, each its own client: what a booking reads of them is what a
    # plan reading client_payout_account_current_uq (status active or returned) whole costs — the return's update of
    # its payout account was planned so (a BitmapAnd with the key), its reads then the number of such accounts
    conn.execute(
        f"""insert into public.client_payout_account (organization_id, client_organization_id, currency, iban,
             holder_name, evidence_document_id, proposed_by, status, confirmed_by, confirmed_at, confirmed_via)
           select gen_random_uuid(), gen_random_uuid(), 'EUR', 'FR7688685684899121950048661', 'PLANTED',
                  gen_random_uuid(), gen_random_uuid(), 'active', gen_random_uuid(), now(), 'second_admin'
           from generate_series(1, {CURRENT_PLANTED}) g"""  # noqa: S608 - the tests' own constants
    )
    conn.execute(
        "alter table public.client_payout_account enable always trigger client_payout_account_guard"
    )
    conn.execute("set local session_replication_role = origin")
    for key in ("organization_id", "iban"):
        conn.execute(
            f"alter table public.client_payout_account alter column {key} set (n_distinct = 2)"
        )
    conn.execute("analyze public.client_payout_account")


def _rows(conn: psycopg.Connection[Any]) -> dict[str, int]:
    rows = conn.execute(
        """select t.relid::regclass::text,
                  coalesce(pg_stat_get_xact_tuples_returned(t.relid), 0)
                  + coalesce((select sum(pg_stat_get_xact_tuples_returned(i.indexrelid))
                              from pg_index i where i.indrelid = t.relid), 0)
           from (select unnest(%s::regclass[]) relid) t""",
        (list(EXIT_WATCHED),),
    ).fetchall()
    return {str(r[0]).replace("public.", ""): int(r[1]) for r in rows}


def _body(file: str, marker: str) -> str:
    text = (MIGRATIONS / file).read_text()
    start = text.index(marker)
    end = text.index("\n$$;", start) + len("\n$$;")
    return text[start:end]


def _csv(tenant: dict[str, Any], rows: list[tuple[date, str, int, str]]) -> str:
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


@pytest.fixture(scope="module")
def held(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """Two runs booked from their camt.053 debits; a top-up ordered to the dedicated account; then a
    CSV export of the account holding four credits citing ours (held label_reference, reviewed by
    the debit job): the first run's payout at exactly its amount (exit (a)), twice more (exits (b)
    and (c)), and our top-up with no counterparty IBAN (the fourth exit)."""
    tenant, _other, _r1, _r2 = _two_runs()
    _data, paid = _booked(tenant, tmp_path_factory.mktemp("label-exit-reads"))
    (e2e, n), _ = paid
    top_e2e = "TOP" + uuid.uuid4().hex[:12].upper()
    with psycopg.connect(DB) as conn, conn.transaction():
        own = one(
            conn,
            "select id from public.bank_account where organization_id = %s and purpose = 'own'",
            (tenant["servicer"],),
        )
        top = one(
            conn,
            """insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id,
                 creditor_bank_account_id, currency, amount_minor, payee_name, payee_iban,
                 end_to_end_id, remittance_info, requested_execution_date)
               values (%s, 'top_up', %s, %s, 'EUR', 4700, 'Fonds de tiers', %s, %s, %s, %s)
               returning id""",
            (tenant["servicer"], own, tenant["bank"], tenant["iban"], top_e2e,
             f"APPROVISIONNEMENT COMPTE DEDIE {top_e2e}", paris_today()),
        )  # fmt: skip
        transfer = one(conn, "select id from public.bank_transfer where end_to_end_id = %s", (e2e,))
        # the plant's copy of a payout (another booked run's, under another id): a payout of the account still
        # ordered — a booked one's copy would repeat its entry (bank_transfer_entry_id_key)
        planted = one(
            conn,
            """insert into public.bank_transfer (organization_id, client_organization_id, kind,
                 debtor_bank_account_id, currency, amount_minor, payee_name, payee_iban,
                 end_to_end_id, remittance_info, requested_execution_date)
               select organization_id, client_organization_id, 'payout', debtor_bank_account_id, 'EUR', 100000,
                      payee_name, payee_iban, %s, 'REVERSEMENT (test)', %s
               from public.bank_transfer where end_to_end_id = %s
               returning id""",
            ("RMT" + uuid.uuid4().hex[:12].upper(), paris_today(), e2e),
        )
        conn.execute("update public.bank_account set feed = 'csv' where id = %s", (tenant["bank"],))
    day = paris_today()
    motif = "VIR SEPA RECU /DE DUPONT JEAN /MOTIF REMBOURSEMENT"
    sid = _csv(
        tenant,
        [
            (day, f"{motif} {e2e}", n, DEBTOR),
            (day, f"{motif} {e2e} B", 30_000, DEBTOR),
            (day, f"{motif} {e2e} C", 20_000, DEBTOR),
            (
                day,
                f"VIR SEPA RECU /DE COLLECTOO SAS /MOTIF APPROVISIONNEMENT COMPTE DEDIE {top_e2e}",
                4_700,
                "",
            ),
        ],
    )
    with psycopg.connect(DB) as conn:
        lines = [
            str(r[0])
            for r in conn.execute(
                "select id from public.bank_transaction where statement_id = %s and kind = 'label_reference' "
                "order by line_no",
                (sid,),
            ).fetchall()
        ]
    assert len(lines) == 4, lines
    return {
        "tenant": tenant,
        "lines": lines,
        "planted": str(planted),
        "top": str(top),
        "transfer": str(transfer),
    }


Reads = dict[str, dict[str, int]]


def _exits(held: dict[str, Any], *, planted: bool) -> tuple[Reads, Reads]:
    """Each exit taken in a rolled-back transaction — on the tables planted (generic plans) or as
    they are — and the rows each call read of the watched tables; then the nightly's."""
    tenant, lines = held["tenant"], held["lines"]
    org, user, client = str(tenant["servicer"]), str(tenant["staff"]), str(tenant["client"])
    measured: Reads = {}
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        if planted:
            _plant(conn, held["planted"], lines[0])
            _plant_payout_accounts(conn, org)
            conn.execute("set local plan_cache_mode = force_generic_plan")

        def call(name: str, who: str | None, sql: str, *params: Any) -> Any:
            before = _rows(conn)
            with conn.transaction():
                if who is None:
                    conn.execute("set local role postgres")
                else:
                    _as(conn, who)
                value = one(conn, sql, params)
                conn.execute("reset role")
            after = _rows(conn)
            measured[name] = {k: after[k] - before[k] for k in after if after[k] - before[k]}
            return value

        # exit (a): the options (class L, the payout's return), then the booking
        opts = call(
            "transfer_line_options", user, "select public.transfer_line_options(%s)", lines[0]
        )
        assert opts["class"] == "L" and len(opts["proposals"]) == 1, opts
        (proposal,) = opts["proposals"]
        res = call("book_transfer_line", user, "select public.book_transfer_line(%s, %s, %s, %s, %s)",
                   str(uuid.uuid4()), lines[0], Jsonb(proposal["request"]), proposal["preview"]["expected_text"],
                   REASON)  # fmt: skip
        assert [b["kind"] for b in res["bookings"]] == ["payout_returned"], res
        chain = call("remittance_chain_paid", None,
                     "select to_jsonb(p) from private.remittance_chain_paid(%s) p", held["transfer"])  # fmt: skip
        assert chain["returned"] is True and chain["paid_on"] is None, chain
        # exit (b): « Règlement du client » for the tenant's client
        facts = call("client_payment_line", user, "select public.client_payment_line(%s, null, null, %s)",
                     lines[1], client)  # fmt: skip
        assert facts["refusal"] is None, facts
        booked = call("book_client_payment_line", user,
                      "select public.book_client_payment_line(%s, %s, null, null, null, %s, %s, %s)",
                      str(uuid.uuid4()), lines[1], facts["preview"]["open_minor"], REASON, client)  # fmt: skip
        assert booked["entry_id"], booked
        # exit (c): « Paiement d'un débiteur »
        released = call("release_own_credit", user, "select public.release_own_credit(%s, %s, %s)",
                        str(uuid.uuid4()), lines[2], REASON)  # fmt: skip
        assert released["status"] == "unmatched", released
        # the fourth exit: « C'est cet approvisionnement »
        topped = call("book_top_up_credit", user, "select public.book_top_up_credit(%s, %s, %s, %s)",
                      str(uuid.uuid4()), lines[3], held["top"], REASON)  # fmt: skip
        assert topped["status"] == "booked", topped
        # the nightly reading the chain's events (the booked runs' branch), on 7e-2's events body then this slice's
        nightly: Reads = {}
        later = paris_today() + timedelta(days=10)
        for label, setup in (("7e-2", _body(*EVENTS_BEFORE_7E3)), ("7e-3", None)):
            with conn.transaction(force_rollback=True):
                if setup is not None:
                    conn.execute(setup)
                check = one(conn, "insert into public.payment_check_run (organization_id) values (%s) "
                                  "returning id", (org,))  # fmt: skip
                b0 = _rows(conn)
                conn.execute(
                    "select private.run_remittance_runs_checks(%s, %s, %s)", (check, org, later)
                )
                b1 = _rows(conn)
                nightly[label] = {k: b1[k] - b0[k] for k in b1 if b1[k] - b0[k]}
    return measured, nightly


def test_the_exits_read_by_key_whatever_the_statistics(held: dict[str, Any]) -> None:
    bare, _ = _exits(held, planted=False)
    measured, nightly = _exits(held, planted=True)
    print(
        "\nexits' reads (planted, generic plans):",
        measured,
        "\nunplanted:",
        bare,
        "\nnightly:",
        nightly,
    )
    # each call reads of a planted table what the same call reads of it unplanted, plus PER_CALL — a few rows, never
    # the planted ones (a return's booking reads its transfers by key many times over: book_transfer_line reads some
    # 75 rows of bank_transfer on these tables unplanted as planted)
    over = {
        name: {
            k: (v, bare[name].get(k, 0))
            for k, v in rows.items()
            if v > bare[name].get(k, 0) + PER_CALL
        }
        for name, rows in measured.items()
    }
    assert not any(over.values()), (over, measured, bare)
    assert (
        set(measured)
        == set(bare)
        == {
            "transfer_line_options",
            "book_transfer_line",
            "remittance_chain_paid",
            "client_payment_line",
            "book_client_payment_line",
            "release_own_credit",
            "book_top_up_credit",
        }
    )
    # (review round 1, CC-1) the release's payer probe reads the line's IBAN by key: none of the planted accounts
    assert measured["release_own_credit"].get("client_payout_account", 0) <= PER_CALL, measured
    for table in EXIT_WATCHED:
        key = table.replace("public.", "")
        assert nightly["7e-3"].get(key, 0) <= nightly["7e-2"].get(key, 0) + PER_CALL, nightly
