"""M2-07 against the local stack (needs `make up`): statements uploaded through the commands and
imported by the payments job. Importing twice creates nothing; an overlapping statement adds only
its new lines; refused files write nothing; one cash_in per statement day (design §2 #1, I11)."""

from collections import Counter
from dataclasses import replace
from datetime import date, timedelta
from typing import Any

import psycopg
import pytest
from integration_helpers import DB, one, storage
from statement_helpers import (
    START,
    bank_tenant,
    cash_in_by_day,
    drain,
    money_state,
    paid_by_day,
    statement,
    upload,
)

from collectoo_worker.jobs.payments import make_handler, record_dead_job
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.synth.camt053 import (
    Doc,
    Entry,
    Expected,
    Tx,
    balance_before,
    expected_csv,
    expected_lines,
    generate_entries,
    make_doc,
    render_bank_csv,
    render_camt053,
)

pytestmark = pytest.mark.integration


def _doc(tenant: dict[str, Any], lines: int, days: int, seed: int = 11) -> tuple[Doc, list[Entry]]:
    entries = generate_entries(lines, seed=seed, start=START, days=days * 2)
    end = START + timedelta(days=days - 1)
    return make_doc(entries, iban=tenant["iban"], from_date=START, to_date=end), entries


def _imported(target: dict[str, Any]) -> dict[str, Any]:
    s = statement(target["statement_id"])
    assert s["status"] == "imported", s
    return s


def _check_counts(counts: dict[str, Any], expected: list[Expected], doc: Doc) -> None:
    kinds = Counter(x.kind for x in expected)
    paid = [
        x
        for x in expected
        if x.direction == "credit" and x.kind in ("debtor_credit", "batch_unsplit")
    ]
    assert counts["lines"] == counts["new_lines"] == len(expected)
    assert counts["payments"] == {
        "count": len(paid),
        "minor": str(sum(x.amount_minor for x in paid)),
    }
    assert counts["returns"] == kinds["return"]
    assert counts["batch_unsplit"] == kinds["batch_unsplit"] > 0
    assert counts["other_debits"] == kinds["other_debit"] > 0
    assert counts["refunds_out"] == kinds["refund_out"]
    assert counts["unposted"]["lines"] == len(expected) - len(paid)
    assert counts["skipped_not_booked"] == sum(
        1 for e in doc.statements[0].entries if e.status != "BOOK"
    )


def test_a_camt053_statement_is_imported_and_its_days_booked() -> None:
    tenant = bank_tenant()
    store = storage()
    doc, _ = _doc(tenant, 600, 3)
    expected = expected_lines(doc)
    target = upload(tenant, store, render_camt053(doc, "08"))
    drain(store)
    s = _imported(target)
    _check_counts(s["counts"], expected, doc)
    by_day = paid_by_day(expected)
    state = money_state(tenant["bank"])
    assert state["payments"] == s["counts"]["payments"]["count"]
    assert state["payments_minor"] == sum(by_day.values())
    # one cash_in per booking day with payments, each = Σ that day's payments (I11)
    assert s["counts"]["cash_in_entries"] == state["cash_entries"] == len(by_day)
    assert cash_in_by_day(tenant["bank"], target["statement_id"]) == by_day
    assert {
        date.fromisoformat(c["date"]): int(c["minor"]) for c in s["counts"]["cash_in"]
    } == by_day
    # I9 at import: closing = cash booked + lines not booked (the opening is 0)
    assert s["bank_check"]["difference_minor"] == "0"
    assert s["bank_check"]["unposted_lines"] == s["counts"]["unposted"]["lines"]
    assert s["warnings"] == [] and s["format_version"] == "08"
    with psycopg.connect(DB) as conn:
        statuses = conn.execute(
            "select status, count(*) from public.payment where bank_account_id = %s"
            " group by status",
            (tenant["bank"],),
        ).fetchall()
    assert statuses == [("unmatched", state["payments"])]


def test_the_same_file_twice_is_one_statement_and_the_same_lines_again_create_nothing() -> None:
    tenant = bank_tenant()
    store = storage()
    doc, _ = _doc(tenant, 300, 3, seed=12)
    data = render_camt053(doc, "02")
    first = upload(tenant, store, data)
    drain(store)
    _imported(first)
    before = money_state(tenant["bank"])

    # the same file again: the command answers with the statement already imported
    again = upload(tenant, store, data, "le-meme.xml")
    assert again["duplicate"] and again["statement_id"] == first["statement_id"]

    # the same lines in another file (another message id, .08 instead of .02): nothing new
    other = upload(tenant, store, render_camt053(replace(doc, msg_id="MSG-AGAIN"), "08"))
    drain(store)
    s = _imported(other)
    assert s["counts"]["new_lines"] == 0 and s["counts"]["payments"]["count"] == 0
    assert s["counts"]["known_lines"] == s["counts"]["lines"] > 0
    assert money_state(tenant["bank"]) == before  # ledger unchanged, to the hash
    assert {w["code"] for w in s["warnings"]} == {"overlap"}
    assert s["bank_check"]["difference_minor"] == "0"


def test_an_overlapping_statement_adds_only_its_new_lines() -> None:
    tenant = bank_tenant()
    store = storage()
    doc, entries = _doc(tenant, 300, 3, seed=13)
    first = upload(tenant, store, render_camt053(doc, "02"))
    drain(store)
    _imported(first)
    before = money_state(tenant["bank"])
    # last day of the first statement + 2 new days
    start2 = START + timedelta(days=2)
    second = make_doc(
        entries,
        iban=tenant["iban"],
        from_date=start2,
        to_date=start2 + timedelta(days=2),
        opening_minor=balance_before(entries, start2),
        stmt_id="STMT-2",
        seq=2,
    )
    overlap = upload(tenant, store, render_camt053(second, "02"))
    drain(store)
    s2 = _imported(overlap)
    new_days = {d: v for d, v in paid_by_day(expected_lines(second)).items() if d > start2}
    assert s2["counts"]["known_lines"] == sum(
        1 for x in expected_lines(second) if x.booking_date == start2
    )
    after = money_state(tenant["bank"])
    assert after["payments_minor"] - before["payments_minor"] == sum(new_days.values())
    assert after["cash_entries"] - before["cash_entries"] == len(new_days)
    assert s2["bank_check"]["difference_minor"] == "0"
    assert {w["code"] for w in s2["warnings"]} == {
        "overlap"
    }  # continuity: opening = previous closing


def test_a_reused_bank_reference_with_other_facts_refuses_the_file() -> None:
    tenant = bank_tenant()
    store = storage()
    tx = Tx(1000, ref="TX-1", name="MARTIN", ustrd=("F-1",))
    day = make_doc(
        [Entry(1000, True, START, ref="N1", txs=(tx,))],
        iban=tenant["iban"],
        from_date=START,
        to_date=START,
    )
    first = upload(tenant, store, render_camt053(day))
    drain(store)
    _imported(first)
    later = START + timedelta(days=1)
    reused = make_doc(
        [Entry(2500, True, later, ref="N2", txs=(replace(tx, amount_minor=2500),))],
        iban=tenant["iban"],
        from_date=later,
        to_date=later,
        opening_minor=1000,
    )
    target = upload(tenant, store, render_camt053(reused))
    drain(store)
    s = statement(target["statement_id"])
    assert (s["status"], s["error_code"]) == ("rejected", "reference_conflict"), s
    assert money_state(tenant["bank"])["payments_minor"] == 1000


def test_csv_reimports_and_lines_already_imported_under_another_label() -> None:
    tenant = bank_tenant("csv")
    store = storage()
    doc, _ = _doc(tenant, 120, 2, seed=14)
    lines = expected_lines(doc)
    first = upload(tenant, store, render_bank_csv(lines), "export.csv")
    drain(store)
    s = _imported(first)
    parsed = expected_csv(lines)
    assert s["counts"]["payments"]["count"] == sum(1 for x in parsed if x.kind == "debtor_credit")
    assert s["bank_check"] is None and s["format_version"] is None  # a CSV proves no balance
    before = money_state(tenant["bank"])
    # a re-export without the bank's ids and with reworded labels: same days and amounts, similar
    # labels -> suspected duplicates, no payment, no cash
    reworded = [replace(x, remittance_text=(x.remittance_text or "") + " SEPA") for x in lines]
    second = upload(
        tenant, store, render_bank_csv(reworded, bank_ids=False, seed=2), "export-2.csv"
    )
    drain(store)
    s2 = _imported(second)
    assert s2["counts"]["suspected_duplicates"] == s2["counts"]["new_lines"] == len(lines)
    after = money_state(tenant["bank"])
    assert after["lines"] == before["lines"] + len(lines)  # recorded, held for ops
    assert {k: v for k, v in after.items() if k != "lines"} == {
        k: v for k, v in before.items() if k != "lines"
    }


def test_a_csv_with_the_same_lines_again_creates_nothing() -> None:
    tenant = bank_tenant("csv")
    store = storage()
    doc, _ = _doc(tenant, 80, 2, seed=15)
    lines = expected_lines(doc)
    first = upload(tenant, store, render_bank_csv(lines), "a.csv")
    drain(store)
    _imported(first)
    before = money_state(tenant["bank"])
    target = upload(tenant, store, render_bank_csv(lines, seed=9, signed=True), "b.csv")
    drain(store)
    s = _imported(target)
    assert s["counts"]["new_lines"] == 0 and s["counts"]["known_lines"] == len(lines)
    assert money_state(tenant["bank"]) == before


def _tamper_iban(data: bytes, tenant: dict[str, Any]) -> bytes:
    return data.replace(tenant["iban"].encode(), b"FR7630004000031234567890143")


def _tamper_closing(data: bytes, _tenant: dict[str, Any]) -> bytes:
    return data.replace(
        b'<Cd>CLBD</Cd></CdOrPrtry></Tp><Amt Ccy="EUR">',
        b'<Cd>CLBD</Cd></CdOrPrtry></Tp><Amt Ccy="EUR">1',
    )


def _tamper_dtd(data: bytes, _tenant: dict[str, Any]) -> bytes:
    return data.replace(b"<Document", b'<!DOCTYPE d [<!ENTITY a "aaaa">]><Document', 1)


def _tamper_cut(data: bytes, _tenant: dict[str, Any]) -> bytes:
    return data[: len(data) // 2]


@pytest.mark.parametrize(
    ("tamper", "code"),
    [
        (_tamper_iban, "wrong_account"),
        (_tamper_closing, "unbalanced"),
        (_tamper_dtd, "xml_dtd_refused"),
        (_tamper_cut, "xml_invalid"),
    ],
)
def test_a_refused_file_writes_nothing(tamper: Any, code: str) -> None:
    tenant = bank_tenant()
    store = storage()
    doc, _ = _doc(tenant, 60, 2, seed=16)
    target = upload(tenant, store, tamper(render_camt053(doc), tenant))
    drain(store)
    s = statement(target["statement_id"])
    assert (s["status"], s["error_code"]) == ("rejected", code), s
    state = money_state(tenant["bank"])
    assert (state["lines"], state["payments"], state["cash_entries"]) == (0, 0, 0)


def test_a_closed_bank_account_refuses_the_import_in_sql() -> None:
    tenant = bank_tenant()
    store = storage()
    doc, _ = _doc(tenant, 30, 1, seed=17)
    target = upload(tenant, store, render_camt053(doc))
    with psycopg.connect(DB) as conn, conn.transaction():
        conn.execute(
            "update public.bank_account set status = 'closed', closed_on = '2026-11-01',"
            " closed_reason = 'test' where id = %s",
            (tenant["bank"],),
        )
    drain(store)
    s = statement(target["statement_id"])
    assert (s["status"], s["error_code"]) == ("rejected", "bank_account_closed"), s
    assert s["from"] == START  # what the file said is kept for the page
    assert money_state(tenant["bank"])["lines"] == 0


class _Broken:
    def download(self, *_args: Any) -> Any:
        raise OSError("storage unavailable")

    def upload(self, *_args: Any) -> None:  # pragma: no cover - not used
        raise OSError("storage unavailable")

    def remove(self, *_args: Any) -> None:  # pragma: no cover - not used
        raise OSError("storage unavailable")


def test_a_technical_failure_is_retried_then_marked_failed() -> None:
    tenant = bank_tenant()
    doc, _ = _doc(tenant, 20, 1, seed=18)
    target = upload(tenant, storage(), render_camt053(doc))
    consumer = QueueConsumer(
        DB,
        "payments",
        make_handler(_Broken()),
        on_dead=record_dead_job,
        max_attempts=1,
        backoff_base_s=0,
    )
    for _ in range(3):
        consumer.poll_once()
    s = statement(target["statement_id"])
    assert (s["status"], s["error_code"]) == ("failed", "import_failed"), s
    assert "storage unavailable" in s["error"]
    with psycopg.connect(DB) as conn:
        assert (
            one(
                conn,
                "select count(*) from private.bank_import_stage where statement_id = %s",
                (target["statement_id"],),
            )
            == 0
        )
