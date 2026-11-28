# ruff: noqa: E501 - SQL fixtures read better unwrapped
"""M2c-7f-2 (needs `make up`; ADR-0014 « M2c-7f-2 », migration 20261203090000_close_out_fixes.sql): what the
close-out volume file (test_close_out_scale_integration.py, §8.3 row 6) found, held in the db job.

« Règlement du client » (public.record_client_payment) reads the client's open documents
(private.client_payment_docs). Each document's « before the opening » and « payable » were private.document_before_opening
and private.document_client_payable: per document, the client's opening (private.client_opening_date, twice) and
whether its proceeding stands (private.client_proceeding_stands) — the same for every document of the client — and
each advance's open part four times (private.client_open_advances' lateral, flattened). At volume (a client with 1,000
open advances, the covers of 1,000 returns of remitted collections) one call took 360 ms, the row's bound 200 ms. The
fix reads the client's opening and proceeding once per call (a fenced subquery) and each advance's open part once per
advance (the lateral fenced): 117 ms at 1,000.

- `test_a_client_payment_reads_the_clients_opening_once_whatever_the_statistics`: a client with OPEN advances, the
  client payments' plant (test_client_payment_reads_integration: PLANTED rows over two keys, n_distinct pinned, generic
  plans) — one record_client_payment: the client-level helpers called a bounded number of times (track_functions:
  deterministic), the per-document helpers never, each advance's open part at most three times, and the rows read
  from the watched tables a few per document. On the earlier bodies: 2 x OPEN + 1 calls of the client-level helpers.
- `test_the_documents_are_the_same_as_before`: the old body and the new, side by side in rolled-back transactions,
  give the same documents, the same « payable » and « before the opening », for a client with no event, an opening
  (a proceeding_opened) after some advances were born, and a liquidation recorded alone.

The posting core (§8.3 row 8: the 5,000-payout funds pass took 28.2 s, its bound 26.4 s; 14 s of it the pooled
lookup). private.ledger_post_set found each pooled ledger account by the first three columns of
ledger_account_pooled_uq (servicer, book, currency) — « is not distinct from » is no index condition — so each client's
dimension read every account of the servicer's book, one per client: a lot of n clients' entries read n x the
servicer's clients rows. 7f-2's first fix found a client's dimension by the client's own index
(ledger_account_client_idx), which held only while the statistics priced it the cheaper: its predicate « portfolio_id
is null » is a condition of ledger_account_portfolio_idx, its « book = » one of ledger_account_org_book_idx, and with
the table analysed while (nearly) empty every probe is priced alike, the tie broken by the indexes' sizes — 81,004 rows
for the lot after a reset, 1,081,004 beside another servicer's 10,000 pooled accounts (review round 1, VC-1). The fix
(round 1) compares the dimension's key (private.ledger_pooled_key) with the expression of a unique index of its own
(ledger_account_pooled_key_uq, every account but the receivables) and nothing else of the account, so no other index
has a condition to work with; each receivable line's account by a probe of ledger_account_receivable_uq (joined, the
whole table was hashed at each call). The same plant found the entry check's receivable / owner-claim mirror
(private.ledger_entry_verify) reading, per line, every receivable and owner-claim account of the table with it analysed
while empty (its book a condition beside the primary key: 36,804 rows after the db job's first files, 2,045,604 beside
the background): now by the primary key alone.

- `test_a_lot_finds_each_clients_pooled_accounts_by_its_key_whatever_the_statistics`: a servicer with CLIENTS clients,
  each with its 4670 and 4112 (posted by a first lot), then a lot of LOT of them (an advance's entry each: +4679 /
  -4670[c] || +4112[c] / -4689), alone or beside BACKGROUND other clients' pooled accounts (planted), with
  ledger_account's statistics planted — forgotten (the table and its indexes never analysed), analysed while empty
  (no row, the files' pages), or analysed before the servicer's accounts: the rows read from ledger_account a few per
  entry (the earlier bodies: 2 x LOT x CLIENTS and more; the earlier entry check, every owner-claim account of the
  background per line), and each line on its client's own account. The two
  statement-level checks of ledger_posting (ledger_posting_guard, ledger_posting_client_payable: unchanged here) are
  off for the measured lot, in its transaction rolled back: their own reads are of the whole table — every servicer's
  4670 accounts by a hash join, and, the guard's plan flipping with the table's size, all of ledger_account by a
  sequential scan — and would hide the lookup's; the lookup's accounts are checked by the test itself (each line on
  its client's account, none created twice).
"""

from __future__ import annotations

import json
import re
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from explain_helpers import ADMIN
from integration_helpers import DB, one
from remittance_helpers import own_account, remittance_tenant
from test_client_payment_reads_integration import WATCHED, _as, _plant, _rows
from test_client_payments_integration import NO_NETTING, REASON, _evidence, _invoice_due

pytestmark = pytest.mark.integration
OPEN = 60  # the client's open advances
PER_DOCUMENT = 12  # rows read per open document from the watched tables
SLACK = 60
CLIENT_LEVEL = ("client_opening_date", "client_proceeding_stands")
CLIENTS = 400  # the servicer's clients (each its 4670 and 4112)
LOT = 100  # the measured lot's entries, one client each
BACKGROUND = 5_000  # another servicer's clients, each its 4670, 4112 and an owner's-claim account
PER_ENTRY = 20  # rows read from ledger_account per entry (the posting core: four lines, its checks; row 1 too)
STATEMENT_CHECKS = (
    "ledger_posting_guard",
    "ledger_posting_client_payable",
)  # off for the measured lot
PER_DOCUMENT_HELPERS = ("document_before_opening", "document_client_payable")
MIGRATIONS = Path(__file__).resolve().parents[2] / "supabase" / "migrations"


def _advances(tenant: dict[str, Any], days: list[date]) -> list[str]:
    """Advances of the tenant's client on its mandate, one per day (its entry posted as the funds pass posts an
    overrun's: +4679 / -4670[c] ‖ +4112[c] / -4689, by ledger_post_set; its row after), 10 000 + n each."""
    org, client = str(tenant["servicer"]), str(tenant["client"])
    ids = [str(uuid.uuid4()) for _ in days]
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute("select private.ledger_post_set_begin()")
        with conn.cursor() as cur:
            cur.executemany(
                """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                     client_organization_id, source_type, source_id, reason)
                   values (%s, %s, 'client_advance', %s, %s, %s, 'client_advance', %s, 'Avance du cabinet (test)')""",
                [
                    (n + 1, org, d, f"adv:test:{a}", client, a)
                    for n, (d, a) in enumerate(zip(days, ids, strict=True))
                ],
            )
            cur.executemany(
                """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
                   values (%s, 1, 'due_to_servicer', %s, 'EUR'), (%s, 2, 'client_payable', %s, 'EUR'),
                          (%s, 3, 'client_advance_receivable', %s, 'EUR'), (%s, 4, 'due_from_client_funds', %s, 'EUR')""",
                [
                    (n + 1, 10_000 + n, n + 1, -10_000 - n, n + 1, 10_000 + n, n + 1, -10_000 - n)
                    for n in range(len(days))
                ],
            )
        conn.execute(
            "create temp table _posted on commit drop as select * from private.ledger_post_set()"
        )
        conn.execute(
            """insert into public.client_advance (id, organization_id, client_organization_id, mandate_id, currency,
                 amount_minor, cause, cause_entry_id, entry_id)
               select x.id::uuid, %s, %s, %s, 'EUR', 10000 + x.n - 1, 'payout_overrun', p.entry_id, p.entry_id
               from unnest(%s::text[]) with ordinality x (id, n) join pg_temp._posted p on p.entry_no = x.n""",
            (org, client, tenant["mandate"], ids),
        )
    return ids


@pytest.fixture(scope="module")
def many() -> dict[str, Any]:
    """A client owing one invoice (no netting clause) and OPEN advances born over the last OPEN days, the own
    account, a designation."""
    tenant = remittance_tenant(terms=NO_NETTING)
    invoice = _invoice_due(tenant)
    own_account(tenant)
    with psycopg.connect(DB) as conn:
        today = one(conn, "select private.paris_today()")
    days = [today - timedelta(days=OPEN - n) for n in range(OPEN)]
    return {
        "tenant": tenant,
        "invoice": invoice,
        "advances": _advances(tenant, days),
        "days": days,
        "designation": _evidence(tenant, "payment_designation_evidence"),
    }


def _calls(conn: psycopg.Connection[Any]) -> dict[str, int]:
    rows = conn.execute(
        "select funcname, sum(calls)::int from pg_stat_xact_user_functions group by funcname"
    ).fetchall()
    return {str(r[0]): int(r[1]) for r in rows}


def test_a_client_payment_reads_the_clients_opening_once_whatever_the_statistics(
    many: dict[str, Any],
) -> None:
    tenant = many["tenant"]
    org, client, ops = str(tenant["servicer"]), str(tenant["client"]), str(tenant["staff"])
    advance = many["advances"][-1]
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        _plant(conn, org)
        conn.execute("set local plan_cache_mode = force_generic_plan")
        proof = _evidence(tenant, "client_payment_evidence")
        conn.execute("set local track_functions = 'all'")
        before, calls_before = _rows(conn), _calls(conn)
        _as(conn, ops)
        paid = one(
            conn,
            """select public.record_client_payment(%s, %s, 'EUR', %s, private.paris_today(), %s, %s::uuid[], %s, null,
                                                   %s, %s)""",
            (
                str(uuid.uuid4()),
                client,
                f"{(10_000 + OPEN - 1) // 100},{(10_000 + OPEN - 1) % 100:02d}",
                proof,
                [advance],
                many["designation"],
                str(10_000 + OPEN - 1),
                REASON,
            ),
        )
        conn.execute("reset role")
        after, calls_after = _rows(conn), _calls(conn)
    assert [x["document_id"] for x in paid["settled"]] == [advance], paid
    calls = {f: calls_after.get(f, 0) - calls_before.get(f, 0) for f in calls_after}
    read = {t: after[t] - before[t] for t in after if after[t] - before[t]}
    print(
        f"\nrecord_client_payment, {OPEN} open advances: calls {sorted(calls.items())}, rows read {read}"
    )
    assert sum(calls.get(f, 0) for f in CLIENT_LEVEL) <= 4, calls
    assert sum(calls.get(f, 0) for f in PER_DOCUMENT_HELPERS) == 0, calls
    assert calls.get("advance_open", 0) <= 3 * OPEN + 4, calls
    over = {t: n for t, n in read.items() if n > PER_DOCUMENT * (OPEN + 1) + SLACK}
    assert over == {}, (over, WATCHED)


def _latest_before(name: str, migration: str) -> str:
    """`name`'s definition as the migrations before `migration` left it (its latest `create or replace` there)."""
    pat = re.compile(rf"^create or replace function {re.escape(name)}\(", re.M)
    found = None
    for f in sorted(MIGRATIONS.glob("*.sql")):
        if f.name >= migration:
            break
        text = f.read_text()
        for m in pat.finditer(text):
            found = (text, m.start())
    assert found, name
    text, start = found
    return text[start : text.index("\n$$;", start) + len("\n$$;")]


def _docs(conn: psycopg.Connection[Any], client: str) -> list[dict[str, Any]]:
    return list(
        one(conn, "select private.client_payment_docs(%s, 'EUR', private.paris_today())", (client,))
    )


def test_the_documents_are_the_same_as_before(many: dict[str, Any]) -> None:
    tenant = many["tenant"]
    org, client = str(tenant["servicer"]), str(tenant["client"])
    old = [
        _latest_before(f, "20261203090000")
        for f in ("private.client_payment_docs", "private.client_open_advances")
    ]
    opening = many["days"][OPEN // 2]
    states: dict[str, str | None] = {
        "no event": None,
        "a proceeding opened after half the advances": "proceeding_opened",
        "a liquidation recorded alone": "liquidation",
    }
    seen: dict[str, tuple[int, int]] = {}
    for label, kind in states.items():
        with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
            if kind:
                evidence = one(
                    conn,
                    """insert into public.document (organization_id, client_organization_id, kind, storage_path,
                         sha256, mime_type)
                       values (%s, %s, 'client_status_evidence', %s, repeat('e', 64), 'application/pdf') returning id""",
                    (org, client, f"client/test/{uuid.uuid4()}.pdf"),
                )
                conn.execute(
                    """insert into public.client_status_event (organization_id, client_organization_id, kind,
                         effective_date, evidence_document_id, note, recorded_by)
                       values (%s, %s, %s, %s, %s, 'Événement (test)', %s)""",
                    (org, client, kind, opening, evidence, tenant["staff"]),
                )
            new = _docs(conn, client)
            with conn.transaction(force_rollback=True):
                for body in old:
                    conn.execute(body)
                was = _docs(conn, client)
        assert json.dumps(new, sort_keys=True) == json.dumps(was, sort_keys=True), (
            label,
            new[:2],
            was[:2],
        )
        seen[label] = (
            sum(1 for d in new if d["payable"]),
            sum(1 for d in new if d["before_opening"]),
        )
    print(f"\n(payable, before the opening) of {OPEN + 1} documents: {seen}")
    assert seen["no event"] == (OPEN + 1, 0), seen
    assert seen["a proceeding opened after half the advances"][1] > 0, (
        seen
    )  # some born before the opening
    assert seen["a liquidation recorded alone"][0] < OPEN + 1, seen  # the advances not payable


def _post_advances(conn: psycopg.Connection[Any], org: str, clients: list[str]) -> list[Any]:
    """One advance-shaped entry per client (+4679 / -4670[c] || +4112[c] / -4689, 100 each), by
    ledger_post_set in the caller's transaction: (entry_no, entry_id, created)."""
    conn.execute("select private.ledger_post_set_begin()")
    with conn.cursor() as cur:
        cur.executemany(
            """insert into pg_temp._lps_entry (entry_no, organization_id, entry_type, effective_date, idempotency_key,
                 client_organization_id, source_type, source_id, reason)
               values (%s, %s, 'client_advance', private.paris_today(), %s, %s, 'client_advance', %s,
                       'Avance du cabinet (test)')""",
            [
                (n + 1, org, f"adv:lps:{uuid.uuid4()}", c, str(uuid.uuid4()))
                for n, c in enumerate(clients)
            ],
        )
        cur.executemany(
            """insert into pg_temp._lps_line (entry_no, line_no, book, amount_minor, currency)
               values (%s, 1, 'due_to_servicer', 100, 'EUR'), (%s, 2, 'client_payable', -100, 'EUR'),
                      (%s, 3, 'client_advance_receivable', 100, 'EUR'), (%s, 4, 'due_from_client_funds', -100, 'EUR')""",
            [(n + 1,) * 4 for n in range(len(clients))],
        )
    return conn.execute("select * from private.ledger_post_set()").fetchall()


def _ledger_account_rows(conn: psycopg.Connection[Any]) -> int:
    return int(
        one(
            conn,
            """select coalesce(idx_tup_fetch, 0) + coalesce(seq_tup_read, 0) from pg_stat_xact_user_tables
               where relid = 'public.ledger_account'::regclass""",
        )
    )


def _background(conn: psycopg.Connection[Any], n: int) -> None:
    """(planted, in the test's transaction) `n` other clients of another servicer, each with its 4670 and its 4112
    (pooled accounts outside any portfolio, no claim item) and an owner's-claim account (in a portfolio, a component:
    what the receivable / owner-claim mirror of private.ledger_entry_verify reads): the table's bulk whatever the
    stack's state (a reset, or the integration files' receivable accounts before it). The ledger account guard off
    while planting (the portfolios are planted ids)."""
    other = one(
        conn,
        "insert into public.organization (kind, legal_name) values ('servicer', 'Fond S') returning id",
    )
    conn.execute("alter table public.ledger_account disable trigger ledger_account_guard")
    conn.execute(
        """with c as (
             insert into public.organization (kind, servicer_organization_id, legal_name)
             select 'creditor_client', %s, 'Fond ' || g from generate_series(1, %s) g returning id)
           insert into public.ledger_account (organization_id, book, currency, client_organization_id,
                                              owner_organization_id, portfolio_id, component)
           select %s, b.book, 'EUR', c.id, case when b.book = 'owner_claim' then c.id end,
                  case when b.book = 'owner_claim' then gen_random_uuid() end,
                  case when b.book = 'owner_claim' then 'principal' end
           from c
           cross join (values ('client_payable'), ('client_advance_receivable'), ('owner_claim')) b (book)""",
        (other, n, other),
    )
    conn.execute("alter table public.ledger_account enable always trigger ledger_account_guard")


def _plant_statistics(conn: psycopg.Connection[Any], state: str) -> None:
    """ledger_account's statistics, planted (in the test's transaction) so that the planner's estimates depend on the
    table's rows only, never on when the stack last analysed or vacuumed it: none at all (forgotten: the table and
    its indexes never analysed, their sizes read from the files), or analysed while empty (no row, the files' pages:
    every index probe priced alike, the tie broken by the indexes' sizes)."""
    conn.execute("delete from pg_statistic where starelid = 'public.ledger_account'::regclass")
    if state == "forgotten":
        conn.execute(
            """update pg_class set reltuples = -1, relpages = 0
               where oid = 'public.ledger_account'::regclass
                  or oid in (select indexrelid from pg_index where indrelid = 'public.ledger_account'::regclass)"""
        )
    else:
        conn.execute(
            """update pg_class set reltuples = 0, relpages = greatest(1, pg_relation_size(oid) / 8192)
               where oid = 'public.ledger_account'::regclass
                  or oid in (select indexrelid from pg_index where indrelid = 'public.ledger_account'::regclass)"""
        )


STATES = ("forgotten", "analysed while empty", "analysed before the servicer's accounts")


@pytest.mark.parametrize("background", [0, BACKGROUND], ids=["alone", "background"])
@pytest.mark.parametrize("statistics", STATES)
def test_a_lot_finds_each_clients_pooled_accounts_by_its_key_whatever_the_statistics(
    statistics: str, background: int
) -> None:
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        org = one(
            conn,
            "insert into public.organization (kind, legal_name) values ('servicer', 'Lot S') returning id",
        )
        clients = [
            str(r[0])
            for r in conn.execute(
                """insert into public.organization (kind, servicer_organization_id, legal_name)
                   select 'creditor_client', %s, 'Client ' || g from generate_series(1, %s) g returning id""",
                (org, CLIENTS),
            ).fetchall()
        ]
        if background:
            _background(conn, background)
        if statistics == STATES[2]:
            conn.execute("analyze public.ledger_account")
        assert len(_post_advances(conn, str(org), clients)) == CLIENTS
        if statistics != STATES[2]:
            _plant_statistics(conn, statistics)
        some = clients[:: CLIENTS // LOT][:LOT]
        for trigger in STATEMENT_CHECKS:
            conn.execute(f"alter table public.ledger_posting disable trigger {trigger}")
        before = _ledger_account_rows(conn)
        posted = _post_advances(conn, str(org), some)
        read = _ledger_account_rows(conn) - before
        for trigger in STATEMENT_CHECKS:
            conn.execute(f"alter table public.ledger_posting enable always trigger {trigger}")
        wrong = one(
            conn,
            """select count(*) from public.ledger_posting p
               join public.ledger_account a on a.id = p.ledger_account_id
               join public.ledger_entry e on e.id = p.entry_id
               where p.entry_id = any(%s::uuid[])
                 and a.book in ('client_payable', 'client_advance_receivable')
                 and a.client_organization_id is distinct from e.client_organization_id""",
            ([str(r[1]) for r in posted],),
        )
        accounts = one(
            conn, "select count(*) from public.ledger_account where organization_id = %s", (org,)
        )
    print(
        f"\na lot of {LOT} clients' entries ({CLIENTS} clients, {background} others' pooled, statistics {statistics}):"
        f" {read} ledger_account rows read"
    )
    assert len(posted) == LOT and all(r[2] for r in posted), posted[:3]
    assert accounts == 2 * CLIENTS + 2, (
        accounts
    )  # no account created twice: each line found its own
    assert wrong == 0, wrong
    assert read <= PER_ENTRY * LOT + SLACK, read


# -- the prepare's earlier charges (review round 1, VC-3) ----------------------------------------------------------------
PLANTED = 10_000  # rows per table of two other clients
FILES = 40  # the client's files, each charged by every one of its invoices
INVOICES = 6
CHARGE_TABLES = (
    "public.commission_invoice_charge",
    "public.commission_invoice",
    "public.commission_credit_alloc",
    "public.commission_waiver",
)
PER_CHARGE = 4  # rows read per charge of the client's files over the four tables (its row, its invoice's share, probes)
TWO = "(array[gen_random_uuid(), gen_random_uuid()])"


def _invoices_sql(org: str, series: str) -> str:
    """Invoices of the servicer `org`: the client's (its ids) or two other clients' (PLANTED of them)."""
    return f"""insert into public.commission_invoice (id, organization_id, client_organization_id, mandate_id, kind,
                 series, year, seq, number, issue_date, currency, ht_minor, vat_rate, vat_minor, ttc_minor, vat_book,
                 settlement, due_date, reason, payload, payload_sha256, ledger_entry_id)
               select x.id, '{org}', x.client, gen_random_uuid(), 'invoice', '{series}', 2026, x.g,
                      '{series}-2026-' || lpad(x.g::text, 6, '0'), date '2026-01-01', 'EUR', 100,
                      case when x.g %% 2 = 0 then 0.2 else 0.1 end, 20, 120, 'vat_pending', 'due', date '2026-02-01',
                      'commission', '{{}}', repeat('0', 64), gen_random_uuid()
               from (select coalesce((%s::uuid[])[g], gen_random_uuid()) id, coalesce(%s::uuid, k.c[1 + g %% 2]) client,
                            g
                     from (select {TWO} c) k, generate_series(1, %s) g) x"""  # noqa: S608 - the tests' own constants


def _plant_charges(conn: psycopg.Connection[Any], state: str) -> tuple[str, list[str], list[str]]:
    """(planted, in the test's transaction: triggers and foreign keys off while planting) a client with FILES files
    each charged by its INVOICES invoices (the first two invoices with credit allocations on half the files, the first
    with waivers on a quarter), beside PLANTED rows per table of two other clients (two invoices, two files): read by
    anything but the client's keys, those rows come too. Then the four tables' statistics: analysed with their keys'
    n_distinct pinned at 2 (the house plant), or forgotten. The client, its files, its invoices."""
    org = str(uuid.uuid4())
    client = str(uuid.uuid4())
    files = [str(uuid.uuid4()) for _ in range(FILES)]
    invoices = [str(uuid.uuid4()) for _ in range(INVOICES)]
    conn.execute("set local session_replication_role = replica")
    for t, trig in (
        ("public.commission_invoice", "commission_invoice_guard"),
        ("public.commission_invoice", "commission_invoice_append_only"),
        ("public.commission_credit_alloc", "commission_credit_alloc_insert_guard"),
        ("public.commission_waiver", "commission_waiver_insert_guard"),
    ):
        conn.execute(f"alter table {t} disable trigger {trig}")
    conn.execute(_invoices_sql(org, "ZZ"), (invoices, client, INVOICES))
    conn.execute(_invoices_sql(org, "ZY"), ([], None, PLANTED))
    conn.execute(
        """insert into public.commission_invoice_charge (invoice_id, account_id, tier_key, charged_minor)
           select i, f, 'tout', 1000 + n from unnest(%s::uuid[]) with ordinality i (i, n), unnest(%s::uuid[]) f""",
        (invoices, files),
    )
    conn.execute(
        f"""insert into public.commission_invoice_charge (invoice_id, account_id, tier_key, charged_minor)
            select k.i[1 + g % 2], k.f[1 + (g / 2) % 2], 'k' || g, 100
            from (select {TWO} i, {TWO} f) k, generate_series(1, {PLANTED}) g"""  # noqa: S608 - the tests' own constants
    )
    conn.execute(
        """insert into public.commission_credit_alloc (credit_note_id, line_no, original_invoice_id, account_id,
             tier_key, ht_minor)
           select gen_random_uuid(), 1, i, f, 'tout', -(100 + n)
           from unnest(%s::uuid[]) with ordinality i (i, n), unnest(%s::uuid[]) with ordinality f (f, m)
           where n <= 2 and m %% 2 = 0""",
        (invoices, files),
    )
    conn.execute(
        f"""insert into public.commission_credit_alloc (credit_note_id, line_no, original_invoice_id, account_id,
              tier_key, ht_minor)
            select gen_random_uuid(), 1, k.i[1 + g % 2], k.f[1 + (g / 2) % 2], 'k' || g, -1
            from (select {TWO} i, {TWO} f) k, generate_series(1, {PLANTED}) g"""  # noqa: S608 - the tests' own constants
    )
    conn.execute(
        """insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id,
             tier_key, amount_minor, cause, credit_note_id)
           select %s, %s, %s, f, 'tout', 50, 'credit_note', gen_random_uuid()
           from unnest(%s::uuid[]) with ordinality f (f, m) where m %% 4 = 0""",
        (org, client, invoices[0], files),
    )
    conn.execute(
        f"""insert into public.commission_waiver (organization_id, client_organization_id, invoice_id, account_id,
              tier_key, amount_minor, cause, credit_note_id)
            select '{org}', k.c[1 + g % 2], k.i[1 + g % 2], k.f[1 + (g / 2) % 2], 'k' || g, 1, 'credit_note',
                   gen_random_uuid()
            from (select {TWO} c, {TWO} i, {TWO} f) k, generate_series(1, {PLANTED}) g"""  # noqa: S608 - the tests' own constants
    )
    for t, trig in (
        ("public.commission_invoice", "commission_invoice_guard"),
        ("public.commission_invoice", "commission_invoice_append_only"),
        ("public.commission_credit_alloc", "commission_credit_alloc_insert_guard"),
        ("public.commission_waiver", "commission_waiver_insert_guard"),
    ):
        conn.execute(f"alter table {t} enable always trigger {trig}")
    conn.execute("set local session_replication_role = origin")
    keys = {
        "public.commission_invoice": ("client_organization_id",),
        "public.commission_invoice_charge": ("invoice_id", "account_id"),
        "public.commission_credit_alloc": ("original_invoice_id", "account_id"),
        "public.commission_waiver": ("invoice_id", "account_id"),
    }
    for table, cols in keys.items():
        if state == "forgotten":
            conn.execute("delete from pg_statistic where starelid = %s::regclass", (table,))
            conn.execute(
                """update pg_class set reltuples = -1, relpages = 0
                   where oid = %s::regclass or oid in (select indexrelid from pg_index where indrelid = %s::regclass)""",
                (table, table),
            )
        else:
            for col in cols:
                conn.execute(f"alter table {table} alter column {col} set (n_distinct = 2)")
            conn.execute(f"analyze {table}")
    return client, files, invoices


def _charge_rows(conn: psycopg.Connection[Any]) -> int:
    return int(
        one(
            conn,
            """select sum(coalesce(pg_stat_get_xact_tuples_returned(t.relid), 0)
                          + coalesce((select sum(pg_stat_get_xact_tuples_returned(i.indexrelid))
                                      from pg_index i where i.indrelid = t.relid), 0))
               from (select unnest(%s::regclass[]) relid) t""",
            (list(CHARGE_TABLES),),
        )
    )


@pytest.mark.parametrize("statistics", ["planted", "forgotten"])
def test_the_prepares_earlier_charges_are_read_by_the_clients_keys_whatever_the_statistics(
    statistics: str,
) -> None:
    """(Review round 1, VC-3) The prepare's two reads of the earlier charges — whole for the files the run reverses a
    line of (private.remittance_earlier_charges), summed per key and VAT rate for every other
    (private.remittance_charge_totals) — read the client's own rows only: a few per charge of its files, beside
    PLANTED rows per table of two other clients whose invoices, files and keys share two values (n_distinct 2, the
    house plant) or with the statistics forgotten. The totals are the whole charges summed."""
    with psycopg.connect(ADMIN) as conn, conn.transaction(force_rollback=True):
        client, files, invoices = _plant_charges(conn, statistics)
        conn.execute("set local plan_cache_mode = force_generic_plan")
        conn.execute("set role postgres")  # the worker's role
        before = _charge_rows(conn)
        whole = conn.execute(
            "select * from private.remittance_earlier_charges(%s::uuid[])", (files,)
        ).fetchall()
        whole_read = _charge_rows(conn) - before
        before = _charge_rows(conn)
        totals = conn.execute(
            "select * from private.remittance_charge_totals(%s, %s::uuid[])", (client, files)
        ).fetchall()
        totals_read = _charge_rows(conn) - before
        conn.execute("reset role")
        rates: dict[str, Any] = dict(conn.execute("select id::text, vat_rate from public.commission_invoice where id = any(%s::uuid[])",
                                  (invoices,)).fetchall())  # fmt: skip
    charges = FILES * INVOICES
    print(
        f"\nthe earlier charges of {FILES} files x {INVOICES} invoices (statistics {statistics}): whole {whole_read} rows"
        f" read, summed {totals_read}"
    )
    assert len(whole) == charges, len(whole)
    want: dict[tuple[str, str, Any], list[int]] = {}
    for a, tier, inv, charged, credited, waived in whole:
        g = want.setdefault((str(a), tier, rates[str(inv)]), [0, 0, 0, 0])
        cap = charged - credited + waived
        g[0] += 1 if cap > 0 else 0
        g[1] += cap if cap > 0 else 0
        g[2] += charged - credited
        g[3] += waived
    got = {(str(a), tier, rate): [n, cap, o, w] for a, tier, rate, n, cap, o, w, _neg in totals}
    assert got == want
    assert sum(w for *_, w in got.values()) == 50 * (FILES // 4) and any(
        o < 1000 * INVOICES for _, _, o, _ in got.values()
    )
    assert whole_read <= PER_CHARGE * charges + SLACK, whole_read
    assert totals_read <= PER_CHARGE * charges + SLACK, totals_read
