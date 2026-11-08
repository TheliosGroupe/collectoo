"""`synth camt053` (M2-07, founder decision #19: synthetic statements only): files with a manifest
that tells the ground truth; the readers return exactly the manifest; overlapping statements repeat
the same lines with the same dedup keys; every IBAN and RF reference is synthetic and valid."""

import json
from collections import Counter
from datetime import date
from pathlib import Path

from collectoo_worker.payments.camt053 import parse_camt053
from collectoo_worker.payments.csv_import import parse_csv
from collectoo_worker.payments.rf import iban_valid, rf_make, rf_valid
from collectoo_worker.synth.camt053 import generate_entries, make_doc, render_camt053
from collectoo_worker.synth.cli import main

IBAN = "FR7630004000031234567890143"


def _manifest(path: Path) -> dict[str, object]:
    data: dict[str, object] = json.loads(path.read_text("utf-8"))
    return data


def _lines(manifest: dict[str, object]) -> list[dict[str, str]]:
    lines = manifest["lines"]
    assert isinstance(lines, list)
    return lines


def test_the_cli_writes_a_statement_its_manifest_and_an_overlapping_one(tmp_path: Path) -> None:
    refs = tmp_path / "refs.txt"
    refs.write_text("\n".join(rf_make(f"{i:012d}") for i in range(1, 6)), "utf-8")
    assert (
        main(
            [
                "camt053",
                "--lines",
                "300",
                "--seed",
                "4",
                "--iban",
                IBAN,
                "--days",
                "4",
                "--overlap",
                "2",
                "--references",
                str(refs),
                "--version",
                "08",
                "--out",
                str(tmp_path),
            ]
        )
        == 0
    )
    first, second = tmp_path / "camt053-s4.xml", tmp_path / "camt053-s4-overlap.xml"
    a = parse_camt053(first, iban=IBAN, currency="EUR")
    b = parse_camt053(second, iban=IBAN, currency="EUR")
    manifest = _manifest(tmp_path / "camt053-s4.manifest.json")
    assert [(x.amount_minor, x.kind) for x in a.lines] == [
        (int(m["amount_minor"]), m["kind"]) for m in _lines(manifest)
    ]
    # the second statement starts where the first one's day 3 started: days 3 and 4 are repeated
    overlap = {x.dedup_key for x in a.lines if x.booking_date >= date(2026, 10, 3)}
    assert overlap and overlap <= {x.dedup_key for x in b.lines}
    assert {x.booking_date for x in b.lines if x.dedup_key not in overlap} > set()
    assert b.sections[0].opening_minor == a.sections[0].opening_minor + sum(
        x.signed_minor for x in a.lines if x.booking_date < date(2026, 10, 3)
    )
    used = {x.creditor_reference for x in a.lines if x.creditor_reference}
    assert used and used <= set(refs.read_text("utf-8").split())


def test_the_cli_writes_the_csv_export(tmp_path: Path) -> None:
    assert main(["camt053", "--lines", "200", "--seed", "6", "--csv", "--out", str(tmp_path)]) == 0
    parsed = parse_csv(tmp_path / "camt053-s6.csv", currency="EUR")
    manifest = _manifest(tmp_path / "camt053-s6.manifest.json")
    assert [(x.direction, x.amount_minor, x.kind) for x in parsed.lines] == [
        (m["direction"], int(m["amount_minor"]), m["kind"]) for m in _lines(manifest)
    ]


def test_the_mix_covers_what_french_banks_send_and_is_synthetic() -> None:
    entries = generate_entries(3000, seed=9, start=date(2026, 10, 1), days=5)
    doc = make_doc(entries, iban=IBAN, from_date=date(2026, 10, 1), to_date=date(2026, 10, 5))
    xml = render_camt053(doc, "02")
    assert (
        render_camt053(
            make_doc(
                generate_entries(3000, seed=9, start=date(2026, 10, 1), days=5),
                iban=IBAN,
                from_date=date(2026, 10, 1),
                to_date=date(2026, 10, 5),
            ),
            "02",
        )
        == xml
    )  # deterministic
    statuses = Counter(e.status for e in entries)
    assert statuses["PDNG"] > 0
    reasons = {t.return_reason for e in entries for t in e.txs if t.return_reason}
    assert reasons == {"AC04", "MD06", "MS03"}
    assert any(e.batch_count and e.adds_up() and len(e.txs) > 1 for e in entries)  # split batches
    assert any(e.batch_count and not e.adds_up() for e in entries)  # unsplit batches
    assert any(e.reversal for e in entries)
    payer_ibans = {t.iban for e in entries for t in e.txs if t.iban}
    assert payer_ibans and all(iban_valid(i) for i in payer_ibans)  # ISO 13616 registry length
    refs = {t.creditor_ref for e in entries for t in e.txs if t.creditor_ref}
    assert refs and all(rf_valid(r) for r in refs)
    twins = Counter((e.booking_date, e.amount_minor) for e in entries if not e.ref)
    assert max(twins.values()) >= 2  # identical lines without a bank reference
    assert b"NOTPROVIDED" in xml
