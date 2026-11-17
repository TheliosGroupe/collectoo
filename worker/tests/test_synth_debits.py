"""M2c-6b-1 (plan docs/design/m2c-6b-plan.md §6): `pain001.read` and the synthetic statement of a
file's debits (`synth camt053 --debits-of`), through the real camt.053 parser."""

from __future__ import annotations

from datetime import date
from pathlib import Path

import pytest
from hypothesis import given, settings
from test_pain001 import CF_IBAN, _files, mixed_example, worked_example

from collectoo_worker.payments.camt053 import parse_camt053
from collectoo_worker.remittance.pain001 import TransferFile, read, render
from collectoo_worker.synth.camt053 import debits_of, make_doc, render_camt053
from collectoo_worker.synth.cli import main


@settings(max_examples=100, deadline=None)
@given(_files())
def test_a_file_we_wrote_reads_back_as_written(f: TransferFile) -> None:
    data = render(f)
    back = read(data)
    assert render(back) == data  # a fixed point: names already transliterated and cut
    assert [
        (p.pmt_inf_id, p.requested_execution_date, p.debtor_iban) for p in back.payment_infos
    ] == [(p.pmt_inf_id, p.requested_execution_date, p.debtor_iban) for p in f.payment_infos]
    assert [
        (t.end_to_end_id, t.amount_minor, t.creditor_iban)
        for p in back.payment_infos
        for t in p.transactions
    ] == [
        (t.end_to_end_id, t.amount_minor, t.creditor_iban)
        for p in f.payment_infos
        for t in p.transactions
    ]


def _parse(
    tmp_path: Path, f: TransferFile, version: str = "02", **kw: object
) -> list[dict[str, object]]:
    entries = debits_of(read(render(f)), **kw)  # type: ignore[arg-type]
    days = [e.booking_date for e in entries]
    doc = make_doc(entries, iban=CF_IBAN, from_date=min(days), to_date=max(days))
    path = tmp_path / f"s{version}.xml"
    path.write_bytes(render_camt053(doc, version))
    parsed = parse_camt053(path, iban=CF_IBAN, currency="EUR")
    return [
        {
            "kind": x.kind,
            "direction": x.direction,
            "amount": x.amount_minor,
            "e2e": x.end_to_end_id,
            "original": x.original_end_to_end_id,
            "pmt": x.payment_info_id,
            "code": x.bank_tx_code,
            "day": x.booking_date,
        }
        for x in parsed.lines
    ]


@pytest.mark.parametrize("version", ["02", "08"])
def test_individual_debits_carry_each_transfer_s_own_id(tmp_path: Path, version: str) -> None:
    lines = _parse(tmp_path, worked_example("pain.001.001.09"), version)
    assert [(x["kind"], x["direction"], x["amount"], x["e2e"]) for x in lines] == [
        ("transfer_out", "debit", 164_000, "RMT0A1B2C3D4E5F"),
        ("transfer_out", "debit", 451_136, "RMT1B2C3D4E5F60"),
    ]
    assert {x["day"] for x in lines} == {date(2026, 11, 3)}  # the requested execution date


@pytest.mark.parametrize("version", ["02", "08"])
def test_a_batch_line_is_kept_unsplit_with_its_pmt_inf(tmp_path: Path, version: str) -> None:
    lines = _parse(tmp_path, worked_example("pain.001.001.09"), version, mode="batch")
    assert [(x["kind"], x["amount"], x["e2e"], x["pmt"]) for x in lines] == [
        ("batch_unsplit", 615_136, None, "TF-2026-000001-1")
    ]


def test_a_batch_with_its_details_is_split_into_our_transfers(tmp_path: Path) -> None:
    lines = _parse(tmp_path, worked_example("pain.001.001.09"), mode="batch-details")
    assert [(x["kind"], x["amount"], x["e2e"]) for x in lines] == [
        ("transfer_out", 164_000, "RMT0A1B2C3D4E5F"),
        ("transfer_out", 451_136, "RMT1B2C3D4E5F60"),
    ]


def test_a_partial_batch_misses_its_last_transfer(tmp_path: Path) -> None:
    lines = _parse(tmp_path, worked_example("pain.001.001.09"), mode="partial")
    assert [(x["kind"], x["amount"], x["pmt"]) for x in lines] == [
        ("other_debit", 164_000, "TF-2026-000001-1")  # one transaction left: not a batch
    ]


def test_twice_books_every_debit_again_the_next_day(tmp_path: Path) -> None:
    lines = _parse(tmp_path, mixed_example("pain.001.001.03"), mode="twice")
    assert [(x["kind"], x["e2e"], x["day"]) for x in lines] == [
        ("refund_out", "RFD00AABBCCDDEE", date(2026, 11, 4)),
        ("transfer_out", "SWPFEDCBA987654", date(2026, 11, 4)),
        ("refund_out", "RFD00AABBCCDDEE", date(2026, 11, 5)),
        ("transfer_out", "SWPFEDCBA987654", date(2026, 11, 5)),
    ]


def test_a_return_less_the_bank_s_charge_and_a_fee(tmp_path: Path) -> None:
    lines = _parse(
        tmp_path,
        worked_example("pain.001.001.09"),
        returns=["RMT1B2C3D4E5F60"],
        return_date=date(2026, 11, 12),
        charges_minor=1_500,
        fee_minor=250,
    )
    back = [x for x in lines if x["day"] == date(2026, 11, 12)]
    assert [(x["kind"], x["direction"], x["amount"], x["original"]) for x in back] == [
        ("return", "credit", 449_636, "RMT1B2C3D4E5F60"),
        ("other_debit", "debit", 250, None),
    ]
    assert str(back[1]["code"]).split("/")[2] == "CHRG"


def test_refused_requests() -> None:
    f = read(render(worked_example("pain.001.001.09")))
    with pytest.raises(ValueError, match="mode"):
        debits_of(f, mode="sometimes")
    with pytest.raises(ValueError, match="not in the file"):
        debits_of(f, returns=["RMT000000000000"])
    with pytest.raises(ValueError, match="charges exceed"):
        debits_of(f, returns=["RMT0A1B2C3D4E5F"], charges_minor=164_000)


def test_the_command(tmp_path: Path) -> None:
    source = tmp_path / "TF-2026-000001.xml"
    source.write_bytes(render(worked_example("pain.001.001.09")))
    out = tmp_path / "out"
    assert (
        main(
            [
                "camt053",
                "--debits-of",
                str(source),
                "--mode",
                "batch",
                "--return",
                "RMT0A1B2C3D4E5F",
                "--charges",
                "100",
                "--out",
                str(out),
            ]
        )
        == 0
    )
    xml = out / "camt053-debits-TF-2026-000001-batch.xml"
    parsed = parse_camt053(xml, iban=CF_IBAN, currency="EUR")
    assert [(x.kind, x.amount_minor) for x in parsed.lines] == [
        ("batch_unsplit", 615_136),
        ("return", 163_900),
    ]
    assert (out / "camt053-debits-TF-2026-000001-batch.manifest.json").is_file()
