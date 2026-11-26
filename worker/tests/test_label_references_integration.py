"""M2c-7e-2 (needs `make up`; plan docs/design/m2c-7-plan.md §7.3's S24 up to the review, §7.5;
ADR-0014 « M2c-7e-2 »): our references in a CSV label through the database.

- The classifier's twins agree (Hypothesis, generated labels and kinds): the candidate the parser
  reads (`statement.label_reference`) handed to `statement.refine_kind` and to SQL
  `private.bank_line_refined_kind` (ninth argument) gives one kind; every candidate the parser
  stages (`statement.label_references`, review round 1 MB-1) has the form the import accepts.
- Review round 1 (MB-1, MB-2, MB-3): through the real import, a look-alike or another account's
  reference before our real one never hides it, a « référence de bout en bout » reading NOTPROVIDED
  is none, and our own top-up's credit with no counterparty IBAN, citing it, is held (« À classer »
  gives no IBAN: the page then never says it is not the own account's).
- Review round 2 (notprovided-ref-books-return): with the end-to-end column reading NOTPROVIDED, a
  « /REF RMT… » the payer typed is no end-to-end id — our booked payout's RMT there is held, never
  booked as its return (the import job, then the debit job).
- Review round 3 (first-kept-candidate-hides-p0): of the label's candidates that are transfers of
  the account the import keeps the payout of a booked run over the others (its RMT after our
  sweep's SWP: « À classer » names that payout and its booked run, the nightly's
  label_reference_waiting is P0), else the first in the label's order.
- A CSV export of the dedicated account, imported through the payments queue (the real import job,
  then the debit job it queues and its funds pass): a credit citing our payout's RMT and one citing
  our sweep's SWP — of this account — are held (`label_reference`: no payment, no cash_in, the
  candidate stored, never in an end-to-end id); one citing a look-alike and one citing another
  account's transfer are payments as before; the debit job itself writes the review
  `label_reference` of each held line and books nothing ([check 2] gap 1 (3): the review is the
  job's, not planted); « Débits et retours » lists them with their candidate and its transfer, and
  `link_debit` refuses them ([check 3]: `label_reference_line`)."""

import random
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

import psycopg
import pytest
from debit_helpers import api
from hypothesis import given, settings
from hypothesis import strategies as st
from integration_helpers import DB, one, storage
from remittance_helpers import own_account, paris_today
from statement_helpers import bank_tenant, drain, other_bank, upload
from test_debit_bookings_integration import _bookings, _reviews, _transfer
from test_transfer_files_integration import _two_runs
from test_transfer_line_foundations_integration import _booked, _csv_export

from collectoo_worker.payments.statement import (
    LABEL_REFERENCE_KIND,
    KnownIbans,
    label_reference,
    label_references,
    refine_kind,
)
from collectoo_worker.synth.ids import iban_fr

pytestmark = pytest.mark.integration
OWN = "FR7030001007940000000002002"
CLIENT = "FR0930001007940000000003003"
DEBTOR = "FR7630004000031234567890143"
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
    LABEL_REFERENCE_KIND,
)


@pytest.fixture(scope="module")
def parity_conn() -> Any:
    with psycopg.connect(DB) as conn:
        yield conn


token = st.builds(
    lambda p, h, lower: (p + h).lower() if lower else p + h,
    st.sampled_from(["RMT", "SWP", "TOP", "RFD"]),
    st.from_regex(r"[0-9A-F]{11,13}", fullmatch=True),
    st.booleans(),
)
labels = st.builds(
    lambda head, before, t, sep, after, t2: f"{head}{before}{sep}{t}{sep}{after} {t2}",
    st.sampled_from(["VIR SEPA RECU /DE DUPONT /MOTIF ", "REMISE ", "", "RETOUR VIR SEPA /MOTIF "]),
    st.text(st.sampled_from("ABC xyz12é"), max_size=8),
    token,
    st.sampled_from(["", " ", ".", "/", "_", "-", "A", "0"]),
    st.text(st.sampled_from("ABC xyz12é"), max_size=8),
    # review round 1 (MB-1): a second token after the first — the label's every one is a candidate
    st.one_of(st.just(""), token),
)


@settings(max_examples=300, deadline=None)
@given(
    label=st.one_of(st.none(), labels),
    kind=st.sampled_from(KINDS),
    direction=st.sampled_from(["credit", "debit"]),
    e2e=st.one_of(st.none(), st.sampled_from(["RMT0123456789AB", "TOP0123456789AB", "E2E-1"])),
    original=st.one_of(st.none(), st.sampled_from(["SWP0123456789AB", "E2E-2"])),
    iban=st.one_of(st.none(), st.sampled_from([OWN, CLIENT, DEBTOR])),
)
def test_python_and_sql_read_a_label_reference_alike(  # noqa: PLR0913, PLR0917
    parity_conn: psycopg.Connection[Any],
    label: str | None,
    kind: str,
    direction: str,
    e2e: str | None,
    original: str | None,
    iban: str | None,
) -> None:
    candidate = label_reference(label, e2e)
    row = parity_conn.execute(
        "select private.bank_line_refined_kind(%s, %s, %s, %s, null, %s, %s, %s, %s)",
        (kind, direction, e2e, original, iban, sorted(IBANS.own), sorted(IBANS.clients), candidate),
    ).fetchone()
    assert row is not None
    assert row[0] == refine_kind(
        kind,
        direction,
        e2e,
        iban,
        IBANS,
        original_end_to_end_id=original,
        reference_from_label=candidate,
    )
    # the candidate, when there is one, has the stored column's form (its check constraint), and
    # every one the parser stages has the form the import accepts (review round 1, MB-1); the first
    # is the parser's provisional reading
    every = label_references(label, e2e)
    assert (every[0] if every else None) == candidate
    assert len(set(every)) == len(every) and e2e not in every
    for c in every:
        ok = parity_conn.execute("select %s ~ '^(RMT|SWP|TOP)[0-9A-F]{12}$'", (c,)).fetchone()
        assert ok is not None and ok[0] is True


def _hex12(rng: random.Random) -> str:
    return "".join(rng.choice("0123456789ABCDEF") for _ in range(12))


def _transfers(tenant: dict[str, Any]) -> dict[str, str]:
    """A payout of the dedicated account to the tenant's client (RMT), a sweep of it to the own
    account (SWP), a sweep of another dedicated account of the servicer (another account's id), and
    a top-up the dedicated account receives from the own account (TOP, ordered)."""
    rng = random.Random(str(tenant["servicer"]))
    own, own_iban = own_account(tenant)
    other = other_bank(tenant, feed="csv")
    ids = {"rmt": "RMT" + _hex12(rng), "swp": "SWP" + _hex12(rng), "other": "SWP" + _hex12(rng)}
    ids["top"] = "TOP" + _hex12(rng)
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            """insert into public.bank_transfer (organization_id, client_organization_id, kind,
                 debtor_bank_account_id, currency, amount_minor, payee_name, payee_iban,
                 end_to_end_id, remittance_info, requested_execution_date)
               values (%s, %s, 'payout', %s, 'EUR', 100000, 'C', %s, %s,
                       'REVERSEMENT (test)', %s)""",
            (
                tenant["servicer"],
                tenant["client"],
                tenant["bank"],
                iban_fr(rng),
                ids["rmt"],
                paris_today(),
            ),
        )
        for debtor, e2e in ((tenant["bank"], ids["swp"]), (other["bank"], ids["other"])):
            conn.execute(
                """insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id,
                     creditor_bank_account_id, currency, amount_minor, payee_name, payee_iban,
                     end_to_end_id, remittance_info, requested_execution_date)
                   values (%s, 'sweep', %s, %s, 'EUR', 5000, 'S', %s, %s,
                           'QUOTE-PART (test)', %s)""",
                (tenant["servicer"], debtor, own, own_iban, e2e, paris_today()),
            )
        conn.execute(
            """insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id,
                 creditor_bank_account_id, currency, amount_minor, payee_name, payee_iban,
                 end_to_end_id, remittance_info, requested_execution_date)
               values (%s, 'top_up', %s, %s, 'EUR', 4700, 'Fonds de tiers', %s, %s, %s, %s)""",
            (
                tenant["servicer"],
                own,
                tenant["bank"],
                tenant["iban"],
                ids["top"],
                f"APPROVISIONNEMENT COMPTE DEDIE {ids['top']}",
                paris_today(),
            ),
        )
    return ids


def _fr(day: date) -> str:
    return day.strftime("%d/%m/%Y")


def test_a_csv_citing_our_transfers_is_held_and_reviewed_by_the_job() -> None:
    tenant = bank_tenant(feed="csv")
    ids = _transfers(tenant)
    tag = uuid.uuid4().hex[:6].upper()
    day = _fr(paris_today())
    csv = (
        "Date;Libellé;Débit;Crédit;IBAN contrepartie\n"
        f"{day};VIR SEPA RECU /DE DUPONT JEAN /MOTIF REMB {ids['rmt']} {tag};;1000,00;{DEBTOR}\n"
        f"{day};VIR SEPA RECU /DE DUPONT JEAN /MOTIF {ids['swp']} {tag};;50,00;{DEBTOR}\n"
        f"{day};VIR SEPA RECU /DE DURAND /MOTIF RMT0000000047BF {tag};;30,00;{DEBTOR}\n"
        f"{day};VIR SEPA RECU /DE DURAND /MOTIF {ids['other']} {tag};;31,00;{DEBTOR}\n"
        f"{day};VIR SEPA RECU /DE DURAND /MOTIF FACTURE 12 {tag};;20,00;{DEBTOR}\n"
    ).encode()
    target = upload(tenant, storage(), csv, name=f"releve-{tag}.csv")
    drain(storage())
    sid = str(target["statement_id"])
    with psycopg.connect(DB) as conn:
        lines = conn.execute(
            """select t.id, t.kind, t.reference_from_label, t.end_to_end_id,
                      t.original_end_to_end_id, p.status, r.reason, r.candidates,
                      (select count(*) from public.bank_line_booking b
                       where b.bank_transaction_id = t.id)
               from public.bank_transaction t
               left join public.payment p on p.bank_transaction_id = t.id
               left join public.bank_debit_review r on r.bank_transaction_id = t.id
               where t.statement_id = %s order by t.line_no""",
            (sid,),
        ).fetchall()
        status, counts = conn.execute(
            "select status, counts from public.bank_statement where id = %s", (sid,)
        ).fetchone() or (None, None)
    assert status == "imported"
    assert [tuple(r[1:]) for r in lines] == [
        (LABEL_REFERENCE_KIND, ids["rmt"], None, None, None, "label_reference", [], 0),
        (LABEL_REFERENCE_KIND, ids["swp"], None, None, None, "label_reference", [], 0),
        ("debtor_credit", None, None, None, "unmatched", None, None, 0),
        ("debtor_credit", None, None, None, "unmatched", None, None, 0),
        ("debtor_credit", None, None, None, "unmatched", None, None, 0),
    ]
    assert counts["label_references"] == 2
    assert counts["payments"] == {"count": 3, "minor": "8100"}
    assert [c["minor"] for c in counts["cash_in"]] == ["8100"]
    # « Débits et retours »: listed with its candidate and that transfer; nothing to book on it
    queue = api(
        tenant,
        """select coalesce(jsonb_agg(jsonb_build_array(q.bank_transaction_id,
                 q.reference_from_label, q.label_transfer ->> 'kind',
                 q.label_transfer ->> 'amount_minor', q.bookable_as)
                 order by q.amount_minor::bigint desc), '[]')
           from public.debit_queue('a-classer', 0, 100) q where q.kind = 'label_reference'""",
    )
    assert queue == [
        [str(lines[0][0]), ids["rmt"], "payout", "100000", None],
        [str(lines[1][0]), ids["swp"], "sweep", "5000", None],
    ]
    # [check 3] no other way out: every link kind refused label_reference_line
    with pytest.raises(psycopg.errors.CheckViolation, match="label_reference_line"):
        api(
            tenant,
            "select public.link_debit(%s, %s, 'explained', null, null, null, 'Expliqué (test)')",
            str(uuid.uuid4()),
            str(lines[0][0]),
        )
    # the funds pass again: the review is rewritten, still no booking (one review per line)
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "select pgmq.send('payments', %s::jsonb)",
            (f'{{"type": "process_debits", "organization_id": "{tenant["servicer"]}"}}',),
        )
    drain(storage())
    with psycopg.connect(DB) as conn:
        again = conn.execute(
            """select r.reason, (select count(*) from public.bank_line_booking b
                                 where b.bank_transaction_id = r.bank_transaction_id)
               from public.bank_debit_review r where r.bank_transaction_id = any(%s)
               order by r.reason""",
            ([lines[0][0], lines[1][0]],),
        ).fetchall()
        payments = one(
            conn,
            "select count(*) from public.payment where bank_transaction_id = any(%s)",
            ([lines[0][0], lines[1][0]],),
        )
    assert [tuple(r) for r in again] == [("label_reference", 0), ("label_reference", 0)]
    assert payments == 0


def test_every_reference_the_label_cites_is_tried_and_notprovided_is_none() -> None:
    """Review round 1 (MB-1, MB-2, MB-3), through the real import job: a look-alike, or another
    account's sweep, before our real reference never hides it (label_reference, the real one kept,
    no payment); a « référence de bout en bout » cell reading NOTPROVIDED is none (the label read,
    no end-to-end id stored), a real one keeps the bank's word (a payment); our own top-up's credit
    with no counterparty IBAN, its motif citing it, is held and « À classer » gives no IBAN."""
    tenant = bank_tenant(feed="csv")
    ids = _transfers(tenant)
    tag = uuid.uuid4().hex[:6].upper()
    day = _fr(paris_today())
    csv = (
        "Date;Libellé;Débit;Crédit;IBAN contrepartie;Référence de bout en bout\n"
        f"{day};VIR SEPA RECU /DE DUPONT /MOTIF REMB RMT0000000047BF {ids['rmt']} {tag};;2000,00;"
        f"{DEBTOR};\n"
        f"{day};VIR SEPA RECU /DE DUPONT /MOTIF {ids['other']} {ids['swp']} {tag};;50,00;{DEBTOR};"
        "NOTPROVIDED\n"
        f"{day};VIR SEPA RECU /DE DUPONT /MOTIF REMB {ids['rmt']} {tag};;20,00;{DEBTOR};"
        "E2E-CLIENT-1\n"
        f"{day};VIR SEPA RECU /DE COLLECTOO SAS /MOTIF APPROVISIONNEMENT COMPTE DEDIE "
        f"{ids['top']};;47,00;;\n"
        f"{day};VIR SEPA RECU /DE DURAND /MOTIF RMT0000000047BF {ids['other']} {tag};;31,00;"
        f"{DEBTOR};notprovided\n"
    ).encode()
    target = upload(tenant, storage(), csv, name=f"releve-{tag}.csv")
    drain(storage())
    sid = str(target["statement_id"])
    with psycopg.connect(DB) as conn:
        lines = conn.execute(
            """select t.id, t.kind, t.reference_from_label, t.end_to_end_id, p.status, r.reason
               from public.bank_transaction t
               left join public.payment p on p.bank_transaction_id = t.id
               left join public.bank_debit_review r on r.bank_transaction_id = t.id
               where t.statement_id = %s order by t.line_no""",
            (sid,),
        ).fetchall()
        status, counts = conn.execute(
            "select status, counts from public.bank_statement where id = %s", (sid,)
        ).fetchone() or (None, None)
    assert status == "imported"
    assert [tuple(r[1:]) for r in lines] == [
        (LABEL_REFERENCE_KIND, ids["rmt"], None, None, "label_reference"),
        (LABEL_REFERENCE_KIND, ids["swp"], None, None, "label_reference"),
        ("debtor_credit", None, "E2E-CLIENT-1", "unmatched", None),
        (LABEL_REFERENCE_KIND, ids["top"], None, None, "label_reference"),
        ("debtor_credit", None, None, "unmatched", None),
    ]
    assert counts["label_references"] == 3
    assert counts["payments"] == {"count": 2, "minor": "5100"}
    queue = api(
        tenant,
        """select coalesce(jsonb_agg(jsonb_build_array(q.reference_from_label,
                 q.counterparty_iban_end is null, q.label_transfer ->> 'kind',
                 q.label_transfer ->> 'status', q.label_transfer ->> 'amount_minor', q.amount_minor)
                 order by q.amount_minor::bigint desc), '[]')
           from public.debit_queue('a-classer', 0, 100) q where q.kind = 'label_reference'""",
    )
    assert queue == [
        [ids["rmt"], False, "payout", "ordered", "100000", "200000"],
        [ids["swp"], False, "sweep", "ordered", "5000", "5000"],
        [ids["top"], True, "top_up", "ordered", "4700", "4700"],
    ]


def test_a_ref_of_ours_beside_a_notprovided_cell_is_held_never_booked(tmp_path: Path) -> None:
    """Review round 2 (notprovided-ref-books-return), through the real import job and the debit job
    it queues: a client repaying an advance types « /REF RMT… » (our booked payout's) in its motif,
    the bank appends « /REF NOTPROVIDED » and its « référence de bout en bout » column reads
    NOTPROVIDED. At the payout's amount, and 50 € under it, each credit is held label_reference
    (the RMT its candidate, no end-to-end id) with the job's review label_reference — never
    payout_returned nor a fee from the label alone (round 1 read the first /REF as the line's
    end-to-end id: a return the job booked, the payout « returned »); the payout stays booked; no
    payment, no booking."""
    tenant, _other, _r1, _r2 = _two_runs()
    _data, paid = _booked(tenant, tmp_path)
    (e2e, n), _ = paid
    with psycopg.connect(DB) as conn:
        row = conn.execute(
            """select booking_date from public.bank_transaction
               where end_to_end_id = %s and direction = 'debit'""",
            (e2e,),
        ).fetchone()
        assert row is not None
        day = row[0]
        conn.execute("update public.bank_account set feed = 'csv' where id = %s", (tenant["bank"],))
    motif = f"VIR SEPA RECU /DE MARTIN SAS /MOTIF REMBOURSEMENT AVANCE /REF {e2e} /REF NOTPROVIDED"
    sid = _csv_export(
        tenant,
        [(day, motif, n, "NOTPROVIDED"), (day, f"{motif} BIS", n - 5_000, "NOTPROVIDED")],
    )
    with psycopg.connect(DB) as conn:
        lines = conn.execute(
            """select t.kind, t.reference_from_label, t.end_to_end_id, t.original_end_to_end_id,
                      (select count(*) from public.payment p where p.bank_transaction_id = t.id)
               from public.bank_transaction t where t.statement_id = %s order by t.line_no""",
            (sid,),
        ).fetchall()
    assert [tuple(r) for r in lines] == [
        (LABEL_REFERENCE_KIND, e2e, None, None, 0),
        (LABEL_REFERENCE_KIND, e2e, None, None, 0),
    ]
    assert _bookings(sid) == []
    assert _reviews(sid) == ["label_reference", "label_reference"]
    assert _transfer(e2e)["status"] == "booked"


def test_a_booked_run_s_payout_is_kept_over_the_label_s_other_candidates(tmp_path: Path) -> None:
    """Review round 3 (first-kept-candidate-hides-p0), through the real import job, « À classer »
    and the nightly: two runs booked from their camt.053 debits; a sweep of the dedicated account
    (SWP) and a payout of it in no run (RMT); then a CSV export of the account. A credit whose
    label cites the sweep, then the booked run's payout keeps the payout (round 2 kept the sweep,
    the first in the label's order): « À classer » names that payout and its booked run, and the
    nightly's label_reference_waiting (ten days on) is P0. With no booked run's payout among the
    candidates the first in the label's order is kept (the sweep before the payout of no run, that
    payout before the sweep): neither is P0. Every line held, none a payment."""
    tenant, _other, _r1, _r2 = _two_runs()
    _data, paid = _booked(tenant, tmp_path)
    (e2e, n), _ = paid
    rng = random.Random(f"r3-{tenant['servicer']}")
    swp, loose = "SWP" + _hex12(rng), "RMT" + _hex12(rng)
    with psycopg.connect(DB) as conn, conn.transaction():
        own = one(
            conn,
            "select id from public.bank_account where organization_id = %s and purpose = 'own'",
            (tenant["servicer"],),
        )
        own_iban = one(conn, "select iban from public.bank_account where id = %s", (own,))
        conn.execute(
            """insert into public.bank_transfer (organization_id, kind, debtor_bank_account_id,
                 creditor_bank_account_id, currency, amount_minor, payee_name, payee_iban,
                 end_to_end_id, remittance_info, requested_execution_date)
               values (%s, 'sweep', %s, %s, 'EUR', 5000, 'S', %s, %s, 'QUOTE-PART (test)', %s)""",
            (tenant["servicer"], tenant["bank"], own, own_iban, swp, paris_today()),
        )
        conn.execute(
            """insert into public.bank_transfer (organization_id, client_organization_id, kind,
                 debtor_bank_account_id, currency, amount_minor, payee_name, payee_iban,
                 end_to_end_id, remittance_info, requested_execution_date)
               values (%s, %s, 'payout', %s, 'EUR', 30000, 'C', %s, %s, 'REVERSEMENT (test)',
                       %s)""",
            (
                tenant["servicer"],
                tenant["client"],
                tenant["bank"],
                iban_fr(rng),
                loose,
                paris_today(),
            ),
        )
        run_number = one(
            conn,
            """select r.number from public.remittance_run r
               join public.bank_transfer t on t.run_id = r.id
               where t.end_to_end_id = %s and r.status = 'booked'""",
            (e2e,),
        )
        conn.execute("update public.bank_account set feed = 'csv' where id = %s", (tenant["bank"],))
    day = paris_today()
    motif = "VIR SEPA RECU /DE DUPONT JEAN /MOTIF REMB"
    sid = _csv_export(
        tenant,
        [
            (day, f"{motif} {swp} {e2e}", n + 101, ""),
            (day, f"{motif} {swp} {loose}", 5_101, ""),
            (day, f"{motif} {loose} {swp}", 5_102, ""),
        ],
    )
    names = {e2e: "booked_rmt", swp: "swp", loose: "rmt_of_no_run"}
    with psycopg.connect(DB) as conn:
        lines = conn.execute(
            """select t.kind, t.reference_from_label,
                      (select count(*) from public.payment p where p.bank_transaction_id = t.id)
               from public.bank_transaction t where t.statement_id = %s order by t.line_no""",
            (sid,),
        ).fetchall()
    assert [(k, names.get(r, r), p) for k, r, p in lines] == [
        (LABEL_REFERENCE_KIND, "booked_rmt", 0),
        (LABEL_REFERENCE_KIND, "swp", 0),
        (LABEL_REFERENCE_KIND, "rmt_of_no_run", 0),
    ]
    queue = api(
        tenant,
        """select coalesce(jsonb_agg(jsonb_build_array(q.reference_from_label,
                 q.label_transfer ->> 'kind', q.label_transfer ->> 'run_number',
                 q.label_transfer ->> 'run_status') order by q.amount_minor::bigint desc), '[]')
           from public.debit_queue('a-classer', 0, 100) q where q.kind = 'label_reference'""",
    )
    assert queue == [
        [e2e, "payout", run_number, "booked"],
        [loose, "payout", None, None],
        [swp, "sweep", None, None],
    ]
    with psycopg.connect(DB) as conn, conn.transaction(force_rollback=True):
        check = one(
            conn,
            "insert into public.payment_check_run (organization_id) values (%s) returning id",
            (tenant["servicer"],),
        )
        conn.execute(
            "select private.run_advance_checks(%s, %s, %s)",
            (check, tenant["servicer"], day + timedelta(days=10)),
        )
        waiting = conn.execute(
            """select c.details ->> 'reference_from_label', (c.details ->> 'p0')::boolean
               from public.payment_check_result c
               where c.run_id = %s and c.code = 'label_reference_waiting'
               order by c.amount_minor desc""",
            (check,),
        ).fetchall()
    assert [(names[r], p0) for r, p0 in waiting] == [
        ("booked_rmt", True),
        ("rmt_of_no_run", False),
        ("swp", False),
    ]


def test_a_camt053_label_is_read_as_before() -> None:
    """S24 is a CSV rule: a camt.053 credit whose remittance text cites our payout is a debtor's
    payment as before (its own fields carry our ids when it is one of ours coming back)."""
    from collectoo_worker.synth.camt053 import Entry, Tx, make_doc, render_camt053  # noqa: PLC0415

    tenant = bank_tenant()
    ids = _transfers(tenant)
    ref = f"R{uuid.uuid4().hex[:10].upper()}"
    doc = make_doc(
        [
            Entry(
                7_000,
                True,
                paris_today(),
                paris_today(),
                ref=ref,
                txs=(Tx(7_000, ref=f"L{ref}", iban=DEBTOR, ustrd=(f"REMB {ids['rmt']}",)),),
            )
        ],
        iban=tenant["iban"],
        from_date=paris_today(),
        to_date=paris_today(),
        opening_minor=0,
        stmt_id=f"S{ref}",
    )
    upload(tenant, storage(), render_camt053(doc, "08"), name=f"{ref}.xml")
    drain(storage())
    with psycopg.connect(DB) as conn:
        rows = conn.execute(
            """select t.kind, t.reference_from_label, p.status from public.bank_transaction t
               left join public.payment p on p.bank_transaction_id = t.id
               where t.bank_account_id = %s""",
            (tenant["bank"],),
        ).fetchall()
    assert [tuple(r) for r in rows] == [("debtor_credit", None, "unmatched")]
