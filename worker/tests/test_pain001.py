"""pain.001 writer (M2c-6a; design §11, §18 « pain.001: XSD (.03, .09), golden bytes, CtrlSum and
NbOfTxs, unique end-to-end ids ≤ 35, charset property, same bytes when downloaded twice »).

Goldens: the §7 worked example's TF-2026-000001 (RMT Martin 164 000, RMT Lilas 451 136; CtrlSum
6151.36) and a second file holding a refund with accented, long names and the sweep in its own
PmtInf, per version. Regenerate with PAIN001_UPDATE_GOLDEN=1 (and review the diff).
"""

from __future__ import annotations

import os
import re
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from lxml import etree

from collectoo_worker.remittance import pain001
from collectoo_worker.remittance.pain001 import (
    VERSIONS,
    Pain001Error,
    PaymentInfo,
    Transaction,
    TransferFile,
    XsdUnavailableError,
    amount_text,
    check,
    epc_text,
    is_epc,
    render,
    validate_xsd,
)

GOLDEN = Path(__file__).parent / "golden" / "pain001"
CF_IBAN = "FR3430001007940000000001001"  # the dedicated account CF-EUR (synthetic)
OWN_IBAN = "FR7610107001011234567890129"  # the servicer's own account (synthetic)
MARTIN_IBAN = "FR7630004000031234567890143"
LILAS_IBAN = "FR1420041010050500013M02606"
PAYER_IBAN = "FR7630006000011234567890189"
NS = {
    "pain.001.001.09": "urn:iso:std:iso:20022:tech:xsd:pain.001.001.09",
    "pain.001.001.03": "urn:iso:std:iso:20022:tech:xsd:pain.001.001.03",
}


def worked_example(version: str) -> TransferFile:
    """§7: file TF-2026-000001, debtor CF-EUR, execution 03/11/2026."""
    return TransferFile(
        version=version,
        msg_id="TF-2026-000001",
        created_at="2026-11-02T09:30:12+01:00",
        initiating_party="Collectoo SAS",
        payment_infos=(
            PaymentInfo(
                pmt_inf_id="TF-2026-000001-1",
                requested_execution_date=date(2026, 11, 3),
                debtor_name="Collectoo SAS",
                debtor_iban=CF_IBAN,
                debtor_bic="TESTFRPPXXX",
                transactions=(
                    Transaction(
                        "RV-2026-000001",
                        "RMT0A1B2C3D4E5F",
                        164_000,
                        "EUR",
                        "MARTIN SAS",
                        MARTIN_IBAN,
                        None,
                        "REVERSEMENT RV-2026-000001 FACTURE FC-2026-000001",
                    ),
                    Transaction(
                        "RV-2026-000002",
                        "RMT1B2C3D4E5F60",
                        451_136,
                        "EUR",
                        "LILAS FINANCE",
                        LILAS_IBAN,
                        "TESTFRPP",
                        "REVERSEMENT RV-2026-000002 FACTURE FC-2026-000002",
                    ),
                ),
            ),
        ),
    )


def mixed_example(version: str) -> TransferFile:
    """A refund to a payer (accents, a long name, a non-Latin letter) and the sweep, no BIC."""
    return TransferFile(
        version=version,
        msg_id="TF-2026-000002",
        created_at="2026-11-03T16:05:00+01:00",
        initiating_party="Collectoo SAS",
        payment_infos=(
            PaymentInfo(
                "TF-2026-000002-1",
                date(2026, 11, 4),
                "Collectoo SAS",
                CF_IBAN,
                None,
                (
                    Transaction(
                        "RFD00AABBCCDDEE",
                        "RFD00AABBCCDDEE",
                        8_000,
                        "EUR",
                        "Soci\u00e9t\u00e9 \u0152uvres & B\u00e2timents "
                        "d\u2019\u00cele-de-France \u2014 "
                        "\u00c9tablissement \u00ab Saint-\u00c9tienne \u00bb \u03a9",
                        PAYER_IBAN,
                        None,
                        "REMBOURSEMENT RFD00AABBCCDDEE trop-perçu 80,00 € dossier L-9",
                    ),
                ),
            ),
            PaymentInfo(
                "TF-2026-000002-2",
                date(2026, 11, 4),
                "Collectoo SAS",
                CF_IBAN,
                None,
                (
                    Transaction(
                        "SWPFEDCBA987654",
                        "SWPFEDCBA987654",
                        96_864,
                        "EUR",
                        "Collectoo SAS",
                        OWN_IBAN,
                        None,
                        "VIREMENT AU COMPTE PROPRE SWPFEDCBA987654",
                    ),
                ),
            ),
        ),
    )


def _golden(name: str, data: bytes) -> bytes:
    path = GOLDEN / name
    if os.environ.get("PAIN001_UPDATE_GOLDEN") == "1":
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return path.read_bytes()


def _find(doc: etree._Element, version: str, path: str) -> list[str]:
    ns = NS[version]
    xp = "/".join(f"p:{part}" for part in path.split("/"))
    return [str(x.text) for x in doc.xpath(f"//{xp}", namespaces={"p": ns})]


@pytest.mark.parametrize("version", VERSIONS)
@pytest.mark.parametrize("example", ["worked", "mixed"])
def test_golden_bytes(version: str, example: str) -> None:
    f = worked_example(version) if example == "worked" else mixed_example(version)
    data = render(f)
    assert data == _golden(f"{example}.{version}.xml", data)
    assert render(f) == data  # deterministic: the same inputs, the same bytes (rendered twice)
    check(data, version)


@pytest.mark.parametrize("version", VERSIONS)
def test_the_worked_example_carries_every_field_the_design_lists(version: str) -> None:
    data = render(worked_example(version))
    doc = etree.fromstring(data)
    assert etree.QName(doc).namespace == NS[version]
    assert _find(doc, version, "GrpHdr/MsgId") == ["TF-2026-000001"]
    assert _find(doc, version, "GrpHdr/CreDtTm") == ["2026-11-02T09:30:12+01:00"]
    assert _find(doc, version, "GrpHdr/NbOfTxs") == ["2"]
    assert _find(doc, version, "GrpHdr/CtrlSum") == ["6151.36"]
    assert _find(doc, version, "GrpHdr/InitgPty/Nm") == ["Collectoo SAS"]
    assert _find(doc, version, "PmtInf/PmtMtd") == ["TRF"]
    assert _find(doc, version, "PmtInf/BtchBookg") == ["false"]
    assert _find(doc, version, "PmtInf/PmtTpInf/SvcLvl/Cd") == ["SEPA"]
    when = "PmtInf/ReqdExctnDt/Dt" if version == "pain.001.001.09" else "PmtInf/ReqdExctnDt"
    assert _find(doc, version, when) == ["2026-11-03"]
    assert _find(doc, version, "PmtInf/Dbtr/Nm") == ["Collectoo SAS"]
    assert _find(doc, version, "PmtInf/DbtrAcct/Id/IBAN") == [CF_IBAN]
    bic = "BICFI" if version == "pain.001.001.09" else "BIC"
    assert _find(doc, version, f"PmtInf/DbtrAgt/FinInstnId/{bic}") == ["TESTFRPPXXX"]
    assert _find(doc, version, "PmtInf/ChrgBr") == ["SLEV"]
    assert _find(doc, version, "CdtTrfTxInf/PmtId/InstrId") == ["RV-2026-000001", "RV-2026-000002"]
    assert _find(doc, version, "CdtTrfTxInf/PmtId/EndToEndId") == [
        "RMT0A1B2C3D4E5F",
        "RMT1B2C3D4E5F60",
    ]
    assert _find(doc, version, "CdtTrfTxInf/Amt/InstdAmt") == ["1640.00", "4511.36"]
    ccy = doc.xpath("//p:InstdAmt/@Ccy", namespaces={"p": NS[version]})
    assert ccy == ["EUR", "EUR"]
    assert _find(doc, version, "CdtTrfTxInf/Cdtr/Nm") == ["MARTIN SAS", "LILAS FINANCE"]
    assert _find(doc, version, "CdtTrfTxInf/CdtrAcct/Id/IBAN") == [MARTIN_IBAN, LILAS_IBAN]
    # the creditor's BIC only when known (optional in SEPA: Reg. 260/2012 art. 5 7)
    assert _find(doc, version, f"CdtTrfTxInf/CdtrAgt/FinInstnId/{bic}") == ["TESTFRPP"]
    assert _find(doc, version, "CdtTrfTxInf/RmtInf/Ustrd") == [
        "REVERSEMENT RV-2026-000001 FACTURE FC-2026-000001",
        "REVERSEMENT RV-2026-000002 FACTURE FC-2026-000002",
    ]


@pytest.mark.parametrize("version", VERSIONS)
def test_names_are_transliterated_and_cut_and_the_bic_falls_back_to_notprovided(
    version: str,
) -> None:
    doc = etree.fromstring(render(mixed_example(version)))
    names = _find(doc, version, "CdtTrfTxInf/Cdtr/Nm")
    # « Œ » spelled « OE », « & », « « » », « Ω » become spaces (collapsed), cut at 70 characters
    assert names[0] == "Societe OEuvres Batiments d'Ile-de-France - Etablissement Saint-Etienn"
    assert len(names[0]) == 70
    assert _find(doc, version, "CdtTrfTxInf/RmtInf/Ustrd")[0] == (
        "REMBOURSEMENT RFD00AABBCCDDEE trop-percu 80,00 dossier L-9"
    )
    assert _find(doc, version, "PmtInf/DbtrAgt/FinInstnId/Othr/Id") == [
        "NOTPROVIDED",
        "NOTPROVIDED",
    ]
    assert _find(doc, version, "PmtInf/PmtInfId") == ["TF-2026-000002-1", "TF-2026-000002-2"]
    assert _find(doc, version, "PmtInf/CtrlSum") == ["80.00", "968.64"]
    assert _find(doc, version, "GrpHdr/CtrlSum") == ["1048.64"]


@pytest.mark.parametrize(
    ("raw", "out"),
    [
        ("é è ê ë à â ç ô û ù ï", "e e e e a a c o u u i"),
        ("Œuvre cœur Æther", "OEuvre coeur AEther"),
        ("Straße", "Strasse"),
        ("50 € — « payé »", "50 - paye"),
        ("L\u2019Oréal", "L'Oreal"),
        ("tab\tnew\nline", "tab new line"),
        ("Ωμέγα", ""),
        ('A&B <C> "D" ; E', "A B C D E"),
        ("  plein   d'espaces  ", "plein d'espaces"),
    ],
)
def test_epc_transliteration_examples(raw: str, out: str) -> None:
    assert epc_text(raw, 140) == out


@settings(max_examples=500)
@given(st.text(max_size=300), st.integers(1, 140))
def test_epc_text_property(raw: str, limit: int) -> None:
    out = epc_text(raw, limit)
    assert is_epc(out)
    assert len(out) <= limit
    assert out == out.strip()
    assert "  " not in out
    assert epc_text(out, limit) == out  # idempotent
    # basic Latin letters and digits always survive (up to the limit)
    ascii_only = re.sub(r"[^A-Za-z0-9]", "", raw)
    if raw.isascii() and re.fullmatch(r"[A-Za-z0-9 ]*", raw) and len(raw.strip()) <= limit:
        assert re.sub(r"[^A-Za-z0-9]", "", out) == ascii_only


_names = st.text(
    alphabet=st.characters(codec="utf-8", categories=("L", "N", "P", "Zs", "S")),
    min_size=1,
    max_size=120,
).filter(lambda s: epc_text(s, 70) != "")
_hex = st.text(alphabet="0123456789ABCDEF", min_size=12, max_size=12)


@st.composite
def _files(draw: st.DrawFn) -> TransferFile:
    version = draw(st.sampled_from(VERSIONS))
    n_pmt = draw(st.integers(1, 3))
    e2e = draw(st.lists(_hex, min_size=n_pmt * 4, max_size=n_pmt * 4, unique=True))
    infos = []
    k = 0
    for i in range(n_pmt):
        txs = []
        for _ in range(draw(st.integers(1, 4))):
            prefix = draw(st.sampled_from(["RMT", "RFD", "SWP"]))
            txs.append(
                Transaction(
                    f"RV-2026-{k:06d}" if prefix == "RMT" else f"{prefix}{e2e[k]}",
                    f"{prefix}{e2e[k]}",
                    draw(st.integers(1, pain001.MAX_AMOUNT_MINOR)),
                    "EUR",
                    draw(_names),
                    draw(st.sampled_from([MARTIN_IBAN, LILAS_IBAN, PAYER_IBAN, OWN_IBAN])),
                    draw(st.sampled_from([None, "TESTFRPP", "TESTFRPPXXX"])),
                    draw(st.text(max_size=200)),
                )
            )
            k += 1
        infos.append(
            PaymentInfo(
                f"TF-2026-000009-{i + 1}",
                date(2026, 11, 2) + timedelta(days=draw(st.integers(0, 60))),
                draw(_names),
                CF_IBAN,
                draw(st.sampled_from([None, "TESTFRPPXXX"])),
                tuple(txs),
            )
        )
    return TransferFile(
        version, "TF-2026-000009", "2026-11-02T09:30:12+01:00", draw(_names), tuple(infos)
    )


@settings(max_examples=200, deadline=None)
@given(_files())
def test_every_rendered_file_passes_the_structural_check(f: TransferFile) -> None:
    data = render(f)
    facts = check(data, f.version)
    # NbOfTxs and CtrlSum from integer minor units, exactly (no float): Σ of the amounts
    assert facts["nb_of_txs"] == f.nb_of_txs
    assert facts["ctrl_sum_minor"] == f.ctrl_sum_minor
    doc = etree.fromstring(data)
    assert _find(doc, f.version, "GrpHdr/CtrlSum") == [
        str(
            sum(
                (Decimal(t.amount_minor) / 100 for p in f.payment_infos for t in p.transactions),
                Decimal(0),
            ).quantize(Decimal("0.01"))
        )
    ]
    for name in _find(doc, f.version, "Cdtr/Nm") + _find(doc, f.version, "Dbtr/Nm"):
        assert 0 < len(name) <= 70 and is_epc(name)
    for info in _find(doc, f.version, "Ustrd"):
        assert 0 < len(info) <= 140 and is_epc(info)
    ids = _find(doc, f.version, "EndToEndId")
    assert len(ids) == len(set(ids)) and all(len(i) <= 35 for i in ids)
    assert render(f) == data


def test_amounts_are_written_from_minor_units() -> None:
    assert amount_text(1) == "0.01"
    assert amount_text(615_136) == "6151.36"
    assert amount_text(99_999_999_999) == "999999999.99"
    # a CtrlSum beyond float precision
    assert amount_text(123_456_789_012_345_678) == "1234567890123456.78"
    with pytest.raises(ValueError, match="sign"):
        amount_text(-1)


def _tx(**kw: object) -> Transaction:
    base: dict[str, object] = {
        "instr_id": "RV-2026-000001",
        "end_to_end_id": "RMT0A1B2C3D4E5F",
        "amount_minor": 100,
        "currency": "EUR",
        "creditor_name": "MARTIN SAS",
        "creditor_iban": MARTIN_IBAN,
        "creditor_bic": None,
        "remittance_info": "REVERSEMENT",
    }
    base.update(kw)
    return Transaction(**base)  # type: ignore[arg-type]


def _one(*txs: Transaction, version: str = "pain.001.001.09") -> TransferFile:
    return TransferFile(
        version,
        "TF-2026-000003",
        "2026-11-02T09:30:12+01:00",
        "Collectoo SAS",
        (PaymentInfo("TF-2026-000003-1", date(2026, 11, 3), "Collectoo SAS", CF_IBAN, None, txs),),
    )


@pytest.mark.parametrize(
    ("tx", "match"),
    [
        (_tx(currency="USD"), "EUR only"),
        (_tx(amount_minor=0), "out of range"),
        (_tx(amount_minor=pain001.MAX_AMOUNT_MINOR + 1), "out of range"),
        (_tx(creditor_name="Ωμέγα"), "no EPC character"),
        (_tx(creditor_iban="FR7630004000031234567890144"), "invalid IBAN"),
        (_tx(creditor_bic="bad"), "invalid BIC"),
        (_tx(end_to_end_id="RMT//1"), "no leading"),
        (_tx(end_to_end_id="RMT" + "0" * 33), "1 to 35"),
        (_tx(instr_id="RV 1"), "1 to 35"),
    ],
)
def test_refused_inputs(tx: Transaction, match: str) -> None:
    with pytest.raises(Pain001Error, match=match):
        render(_one(tx))


def test_an_end_to_end_id_twice_is_refused() -> None:
    with pytest.raises(Pain001Error, match="twice"):
        render(_one(_tx(), _tx(instr_id="RV-2026-000002")))


def test_an_unknown_version_is_refused() -> None:
    with pytest.raises(Pain001Error, match="unsupported"):
        render(_one(_tx(), version="pain.001.001.12"))


@pytest.mark.parametrize("version", VERSIONS)
@pytest.mark.parametrize(
    ("old", "new", "match"),
    [
        (b"<BtchBookg>false</BtchBookg>", b"<BtchBookg>true</BtchBookg>", "BtchBookg"),
        (b"<CtrlSum>6151.36</CtrlSum>", b"<CtrlSum>6151.37</CtrlSum>", "CtrlSum"),
        (
            b"<NbOfTxs>2</NbOfTxs>\n      <CtrlSum>6151.36",
            b"<NbOfTxs>3</NbOfTxs>\n      <CtrlSum>6151.36",
            "NbOfTxs",
        ),
        (b"<ChrgBr>SLEV</ChrgBr>", b"<ChrgBr>DEBT</ChrgBr>", "SLEV"),
        (b'Ccy="EUR"', b'Ccy="USD"', "EUR"),
        (b"<Nm>MARTIN SAS</Nm>", b"<Nm>MARTIN  SAS</Nm>", "EPC"),
        (b"<Nm>MARTIN SAS</Nm>", b"<Nm>MARTIN &#233;</Nm>", "EPC"),
        (b"<PmtMtd>TRF</PmtMtd>", b"", "PmtMtd missing"),
        (
            b"<EndToEndId>RMT1B2C3D4E5F60</EndToEndId>",
            b"<EndToEndId>RMT0A1B2C3D4E5F</EndToEndId>",
            "twice",
        ),
        (
            b'<InstdAmt Ccy="EUR">1640.00</InstdAmt>',
            b'<InstdAmt Ccy="EUR">1640</InstdAmt>',
            "InstdAmt",
        ),
    ],
)
def test_the_check_catches_a_tampered_file(
    version: str, old: bytes, new: bytes, match: str
) -> None:
    data = render(worked_example(version))
    assert old in data, old
    with pytest.raises(Pain001Error, match=match):
        check(data.replace(old, new, 1), version)


@pytest.mark.parametrize("version", VERSIONS)
def test_the_check_refuses_reordered_elements_and_other_namespaces(version: str) -> None:
    data = render(worked_example(version))
    swapped = data.replace(
        b"<PmtMtd>TRF</PmtMtd>\n      <BtchBookg>false</BtchBookg>",
        b"<BtchBookg>false</BtchBookg>\n      <PmtMtd>TRF</PmtMtd>",
    )
    with pytest.raises(Pain001Error):
        check(swapped, version)
    other = "pain.001.001.03" if version == "pain.001.001.09" else "pain.001.001.09"
    with pytest.raises(Pain001Error, match="root"):
        check(data, other)
    with pytest.raises(Pain001Error, match="DTD"):
        check(data.replace(b"?>", b"?><!DOCTYPE x>", 1), version)


@pytest.mark.parametrize("version", VERSIONS)
def test_without_the_vendored_xsd_validation_says_so(version: str, tmp_path: Path) -> None:
    with pytest.raises(XsdUnavailableError):
        validate_xsd(render(worked_example(version)), version, tmp_path)


@pytest.mark.xfail(
    strict=True,
    raises=XsdUnavailableError,
    reason="XSD not vendored yet: www.iso20022.org download pending "
    "(docs/reference/iso20022/README.md)",
)
@pytest.mark.parametrize("version", VERSIONS)
@pytest.mark.parametrize("example", ["worked", "mixed"])
def test_the_goldens_validate_against_the_iso20022_xsd(version: str, example: str) -> None:
    data = (GOLDEN / f"{example}.{version}.xml").read_bytes()
    validate_xsd(data, version)
