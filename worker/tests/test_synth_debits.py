"""M2c-6b-1 (plan docs/design/m2c-6b-plan.md §6): `pain001.read` and the synthetic statement of a
file's debits (`synth camt053 --debits-of`), through the real camt.053 parser."""

from __future__ import annotations

from datetime import date
from pathlib import Path

import pytest
from hypothesis import given, settings
from test_pain001 import CF_IBAN, _files, mixed_example, worked_example

from collectoo_worker.payments.camt053 import parse_camt053
from collectoo_worker.payments.csv_import import parse_csv
from collectoo_worker.payments.statement import KnownIbans, UnsplitDetail
from collectoo_worker.remittance.pain001 import TransferFile, read, render
from collectoo_worker.synth.camt053 import (
    debits_of,
    expected_csv,
    expected_lines,
    make_doc,
    render_bank_csv,
    render_camt053,
)
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
    tmp_path: Path,
    f: TransferFile,
    version: str = "02",
    ibans: KnownIbans | None = None,
    **kw: object,
) -> list[dict[str, object]]:
    entries = debits_of(read(render(f)), **kw)  # type: ignore[arg-type]
    days = [e.booking_date for e in entries]
    doc = make_doc(entries, iban=CF_IBAN, from_date=min(days), to_date=max(days))
    path = tmp_path / f"s{version}.xml"
    path.write_bytes(render_camt053(doc, version))
    parsed = parse_camt053(path, iban=CF_IBAN, currency="EUR", ibans=ibans or KnownIbans())
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
            "reason": x.return_reason,
            "iban": x.counterparty_iban,
            "unsplit": x.unsplit_ours,
            "details": x.unsplit_details,
            "count": x.unsplit_detail_count,
            "nb": x.unsplit_batch_count,
            "charges": x.charges_minor,
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


# -- M2c-6b-2a (plan docs/design/m2c-6b-2-plan.md §6): the shapes ops book in 6b-2b -------------

A, B = "RMT0A1B2C3D4E5F", "RMT1B2C3D4E5F60"


@pytest.mark.parametrize("version", ["02", "08"])
def test_a_debit_charge_in_the_iso_shape_is_kept_unsplit_with_its_charge(
    tmp_path: Path, version: str
) -> None:
    """ML-6, CSO2-1: by default each debit is booked for N + charge on one entry, its detail
    carrying N (AmtDtls/TxAmt), the charge in the entry's Chrgs: the parser keeps it unsplit
    (class U) with its one detail at N and the stored charge. Review M2c-6b-2a (M3): a v02 file
    carries the charge as v02 does (`Chrgs/Amt`, no direction), which the parser never reads."""
    lines = _parse(tmp_path, worked_example("pain.001.001.09"), version, debit_charge_minor=120)
    charge = 120 if version == "08" else None
    assert [
        (x["kind"], x["amount"], x["unsplit"], x["details"], x["count"], x["charges"])
        for x in lines
    ] == [
        ("batch_unsplit", 164_120, 1, (UnsplitDetail(A, "debit", 164_000),), 1, charge),
        ("batch_unsplit", 451_256, 1, (UnsplitDetail(B, "debit", 451_136),), 1, charge),
    ]


def test_a_debit_charge_without_the_detail_s_amount_is_its_transfer_s_line(tmp_path: Path) -> None:
    """`--debit-charge-no-detail-amount`: the detail has no amount, so it is the whole entry: our
    transfer's own line (class E) for N + charge, the charge stored."""
    lines = _parse(
        tmp_path,
        worked_example("pain.001.001.09"),
        "08",
        debit_charge_minor=120,
        debit_charge_detail_amount=False,
    )
    assert [(x["kind"], x["amount"], x["e2e"], x["unsplit"], x["charges"]) for x in lines] == [
        ("transfer_out", 164_120, A, None, 120),
        ("transfer_out", 451_256, B, None, 120),
    ]


def test_unflagged_returns_come_from_the_payee_without_a_return_code(tmp_path: Path) -> None:
    """`--unflagged-returns`: no return code, no reversal indicator, from the payee's IBAN — read as
    our transfer coming back (a return by its id), or the client's credit when its IBAN is known."""
    f = worked_example("pain.001.001.09")
    payee = f.payment_infos[0].transactions[0].creditor_iban
    lines = _parse(tmp_path, f, returns=[A], unflagged_returns=True)
    back = [x for x in lines if x["direction"] == "credit"]
    assert [(x["kind"], x["amount"], x["original"], x["reason"], x["iban"]) for x in back] == [
        ("return", 164_000, A, None, payee)
    ]
    assert str(back[0]["code"]).split("/")[2] not in ("RRTN", "RPCR", "UPDD", "PRDD")
    known = KnownIbans(clients=frozenset({payee}))
    back = [
        x
        for x in _parse(tmp_path, f, ibans=known, returns=[A], unflagged_returns=True)
        if x["direction"] == "credit"
    ]
    assert [(x["kind"], x["e2e"]) for x in back] == [("client_transfer_in", A)]


def test_unsplit_details_of_ours_netted(tmp_path: Path) -> None:
    """`--unsplit-details ours-netted` (v08): each PmtInf as one entry of its debits with the first
    transfer's return netted in — every detail ours, with its amount and direction."""
    lines = _parse(tmp_path, worked_example("pain.001.001.09"), "08", unsplit_details="ours-netted")
    assert [
        (x["kind"], x["direction"], x["amount"], x["unsplit"], x["details"], x["count"], x["nb"])
        for x in lines
    ] == [
        (
            "batch_unsplit",
            "debit",
            451_136,
            3,
            (
                UnsplitDetail(A, "debit", 164_000),
                UnsplitDetail(B, "debit", 451_136),
                UnsplitDetail(A, "credit", 164_000),
            ),
            3,
            3,
        )
    ]


@pytest.mark.parametrize("version", ["02", "08"])
def test_unsplit_details_without_amounts_or_beside_others(tmp_path: Path, version: str) -> None:
    """ML-5: details without amounts; ours beside two details not ours netting to zero; ours beside
    one detail not ours without an amount: each kept unsplit with its count."""
    f = worked_example("pain.001.001.09")
    none = _parse(tmp_path, f, version, unsplit_details="no-amounts")
    assert [(x["amount"], x["unsplit"], x["details"], x["count"], x["nb"]) for x in none] == [
        (615_136, 2, (UnsplitDetail(A, "debit", None), UnsplitDetail(B, "debit", None)), 2, 2)
    ]
    if version == "08":  # (details of both directions: v08's TxDtls/CdtDbtInd)
        zero = _parse(tmp_path, f, version, unsplit_details="foreign-zero")
        assert [(x["amount"], x["unsplit"], x["count"]) for x in zero] == [(615_136, 2, 4)]
    other = _parse(tmp_path, f, version, unsplit_details="foreign")
    assert [(x["amount"], x["unsplit"], x["count"]) for x in other] == [(620_136, 2, 3)]


def test_the_netted_shapes_need_v08(tmp_path: Path) -> None:
    entries = debits_of(
        read(render(worked_example("pain.001.001.09"))), unsplit_details="ours-netted"
    )
    doc = make_doc(entries, iban=CF_IBAN, from_date=date(2026, 11, 3), to_date=date(2026, 11, 3))
    with pytest.raises(ValueError, match="08"):
        render_camt053(doc, "02")


def test_a_csv_without_the_references_is_reference_less(tmp_path: Path) -> None:
    """`--csv-without-references`: the label keeps no /REF, so our debits carry no end-to-end id
    (rule 3b's lines, 6b-2b)."""
    entries = debits_of(read(render(worked_example("pain.001.001.09"))))
    doc = make_doc(entries, iban=CF_IBAN, from_date=date(2026, 11, 3), to_date=date(2026, 11, 3))
    lines = expected_lines(doc)
    path = tmp_path / "export.csv"
    path.write_bytes(render_bank_csv(lines, bank_ids=False, references=False))
    parsed = parse_csv(path, currency="EUR", today=date(2026, 11, 8))
    want = expected_csv(lines, bank_ids=False, references=False)
    assert (
        [(x.direction, x.amount_minor, x.end_to_end_id, x.kind) for x in parsed.lines]
        == [(w.direction, w.amount_minor, w.end_to_end_id, w.kind) for w in want]
        == [("debit", 164_000, None, "other_debit"), ("debit", 451_136, None, "other_debit")]
    )


def test_the_command_writes_the_new_shapes(tmp_path: Path) -> None:
    source = tmp_path / "TF-2026-000001.xml"
    source.write_bytes(render(worked_example("pain.001.001.09")))
    out = tmp_path / "out"
    assert (
        main(
            [
                "camt053",
                "--debits-of",
                str(source),
                "--debit-charge",
                "120",
                "--return",
                A,
                "--unflagged-returns",
                # review M2c-6b-2a (M3): a v02 file's Chrgs is never read
                "--version",
                "08",
                "--out",
                str(out),
            ]
        )
        == 0
    )
    parsed = parse_camt053(
        out / "camt053-debits-TF-2026-000001-individual.xml", iban=CF_IBAN, currency="EUR"
    )
    assert [(x.kind, x.amount_minor, x.charges_minor) for x in parsed.lines] == [
        ("batch_unsplit", 164_120, 120),
        ("batch_unsplit", 451_256, 120),
        ("return", 164_000, None),
    ]
    assert (
        main(
            [
                "camt053",
                "--debits-of",
                str(source),
                "--mode",
                "batch",
                "--unsplit-details",
                "ours-netted",
                "--version",
                "08",
                "--out",
                str(out),
            ]
        )
        == 0
    )
    assert (
        main(
            [
                "camt053",
                "--debits-of",
                str(source),
                "--csv",
                "--csv-without-references",
                "--out",
                str(out),
            ]
        )
        == 0
    )
    text = (out / "camt053-debits-TF-2026-000001-individual.csv").read_bytes().decode("cp1252")
    assert "/REF" not in text and A not in text
