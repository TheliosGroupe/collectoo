"""SEPA credit transfer files: ISO 20022 pain.001 (M2c-6a; design §11, founder #15).

`pain.001.001.09` by default, `pain.001.001.03` when the paying bank's guide asks for it
(`bank_account.pain_version`). What the file carries (design §11):

- `GrpHdr`: `MsgId` = the file number (TF-AAAA-NNNNNN), `CreDtTm` frozen when the file was
  generated, `NbOfTxs`, `CtrlSum` written from integer minor units (`minor_to_iso`: no float
  anywhere), `InitgPty/Nm` = the servicer's legal name.
- one `PmtInf` per (group, requested execution date): `PmtMtd TRF`, `BtchBookg false` (one debit
  per transfer on the statement, so each is matched by its own end-to-end id), `SvcLvl SEPA`,
  `ReqdExctnDt` (.09: `<Dt>`; .03: the date itself), `Dbtr` / `DbtrAcct` = the dedicated account,
  `DbtrAgt` its BIC (`BICFI` in .09, `BIC` in .03) or `Othr/Id NOTPROVIDED`, `ChrgBr SLEV`.
- per transaction: `InstrId` (the run's number for a payout), `EndToEndId` (our RMT/RFD/SWP id),
  `InstdAmt Ccy="EUR"`, the creditor's BIC when known (optional in SEPA, Reg. 260/2012 art. 5 7),
  `Cdtr/Nm` = the RIB holder (≤ 70), `CdtrAcct/IBAN`, `RmtInf/Ustrd` (≤ 140).

Text is transliterated to the EPC basic Latin set (`a-z A-Z 0-9 / - ? : ( ) . , ' +` and space):
accents dropped (é → e), ligatures spelled out (œ → oe), anything else becomes a space; runs of
spaces are collapsed and the text cut to its field's length. EUR only.

`render` is deterministic: the same inputs give the same bytes (the file is rendered once by the
job and its SHA-256 kept; a retry renders the same bytes). `check` verifies the structure the
design lists (element order, lengths, charset, sums, unique ids, IBANs) and runs on every file.
`validate_xsd` validates against the ISO 20022 XSD of the version when it is vendored in
`docs/reference/iso20022/` (see its README); the job records whether it could.
"""

from __future__ import annotations

import os
import re
import unicodedata
from dataclasses import dataclass
from datetime import date
from functools import cache
from pathlib import Path

from lxml import etree

from collectoo_worker.payments.rf import iban_valid
from collectoo_worker.payments.statement import minor_to_iso

VERSIONS = ("pain.001.001.09", "pain.001.001.03")
DEFAULT_VERSION = "pain.001.001.09"
RENDERER_VERSION = "pain001-1"
MAX_NAME = 70  # EPC SCT: Dbtr/Nm, Cdtr/Nm, InitgPty/Nm
MAX_USTRD = 140
MAX_ID = 35
MAX_AMOUNT_MINOR = 99_999_999_999  # EPC: 999 999 999,99 at most per transaction
NOT_PROVIDED = "NOTPROVIDED"
XSD_DIR_ENV = "PAIN001_XSD_DIR"

# EPC basic Latin character set (SEPA credit transfer implementation guidelines, character set).
_EPC = re.compile(r"[A-Za-z0-9/\-?:().,'+ ]*")
_NOT_EPC = re.compile(r"[^A-Za-z0-9/\-?:().,'+ ]")
_SPACES = re.compile(r" {2,}")
_BIC = re.compile(r"[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?")
_ISO_AMOUNT = re.compile(r"(0|[1-9][0-9]{0,10})\.[0-9]{2}")
_IBAN = re.compile(r"[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}")
# Letters NFKD does not decompose into basic Latin.
_SPELLED = str.maketrans(
    {
        "œ": "oe",
        "Œ": "OE",
        "æ": "ae",
        "Æ": "AE",
        "ß": "ss",
        "ẞ": "SS",
        "ø": "o",
        "Ø": "O",
        "đ": "d",
        "Đ": "D",
        "ð": "d",
        "Ð": "D",
        "ł": "l",
        "Ł": "L",
        "þ": "th",
        "Þ": "TH",
        "\u0131": "i",  # dotless i
        "\u2019": "'",  # right single quotation mark (the French apostrophe)
        "\u2018": "'",
        "\u02bc": "'",
        "\u00b4": "'",
        "\u2013": "-",  # en dash
        "\u2014": "-",  # em dash
        "\u2010": "-",
        "\u2011": "-",
        "\u00a0": " ",  # no-break spaces
        "\u202f": " ",
    }
)


# The SEPA schemes' geographical scope by IBAN country code (EPC409-09 « EPC List of SEPA Scheme
# Countries », v8.0 of 24/12/2025: the 27 EU, 3 other EEA and 11 non-EEA countries, and the
# territories listed with them). An SCT file (SvcLvl SEPA) pays no other IBAN. The twin of the
# database's private.sepa_scheme_country, which holds such a transfer out of the file first
# (`iban_not_sepa`, review T3); parity tested.
SEPA_COUNTRIES = frozenset(
    {
        # EU
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
        "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
        # other EEA
        "IS", "LI", "NO",
        # non-EEA
        "CH", "GB", "MC", "SM", "VA", "AD", "AL", "ME", "MD", "MK", "RS",
        # territories listed with their countries (their IBANs mostly carry the country's code)
        "AX", "GF", "GP", "MQ", "YT", "RE", "BL", "MF", "PM", "GI", "GG", "JE", "IM",
    }
)  # fmt: skip


def iban_in_sepa(iban: str) -> bool:
    """The IBAN's country is in the SEPA schemes' geographical scope (EPC409-09)."""
    return iban[:2].upper() in SEPA_COUNTRIES


class Pain001Error(ValueError):
    """The file cannot be written or does not hold what it must (a data error: never retried)."""


class XsdUnavailableError(RuntimeError):
    """The ISO 20022 XSD of the version is not vendored (docs/reference/iso20022/README.md)."""


def epc_text(text: str, limit: int) -> str:
    """`text` in the EPC basic Latin set, spaces collapsed, cut to `limit` characters."""
    spelled = unicodedata.normalize("NFKD", text.translate(_SPELLED))
    basic = "".join(ch for ch in spelled if not unicodedata.combining(ch))
    out = _SPACES.sub(" ", _NOT_EPC.sub(" ", basic.translate(_SPELLED))).strip()
    return out[:limit].rstrip()


def is_epc(text: str) -> bool:
    return _EPC.fullmatch(text) is not None


def epc_id(text: str) -> str:
    """An identifier (MsgId, PmtInfId, InstrId, EndToEndId): EPC characters, ≤ 35, not starting or
    ending with '/' and without '//' (EPC rule); refused rather than altered."""
    if not (0 < len(text) <= MAX_ID) or not is_epc(text) or " " in text:
        raise Pain001Error(f"identifier {text!r}: 1 to 35 EPC characters without spaces")
    if text.startswith("/") or text.endswith("/") or "//" in text:
        raise Pain001Error(f"identifier {text!r}: no leading or trailing '/' and no '//'")
    return text


@dataclass(frozen=True)
class Transaction:
    instr_id: str
    end_to_end_id: str
    amount_minor: int
    currency: str
    creditor_name: str
    creditor_iban: str
    creditor_bic: str | None
    remittance_info: str


@dataclass(frozen=True)
class PaymentInfo:
    pmt_inf_id: str
    requested_execution_date: date
    debtor_name: str
    debtor_iban: str
    debtor_bic: str | None
    transactions: tuple[Transaction, ...]

    @property
    def ctrl_sum_minor(self) -> int:
        return sum(t.amount_minor for t in self.transactions)


@dataclass(frozen=True)
class TransferFile:
    version: str
    msg_id: str
    created_at: str  # CreDtTm as frozen at generation (xs:dateTime text)
    initiating_party: str
    payment_infos: tuple[PaymentInfo, ...]

    @property
    def nb_of_txs(self) -> int:
        return sum(len(p.transactions) for p in self.payment_infos)

    @property
    def ctrl_sum_minor(self) -> int:
        return sum(p.ctrl_sum_minor for p in self.payment_infos)


def namespace(version: str) -> str:
    if version not in VERSIONS:
        raise Pain001Error(f"unsupported pain.001 version {version!r}")
    return f"urn:iso:std:iso:20022:tech:xsd:{version}"


def amount_text(minor: int) -> str:
    """An EUR amount (`InstdAmt`, `CtrlSum`) from integer minor units: `615136` → `6151.36`."""
    return minor_to_iso(minor, 2)


def _name(text: str, what: str) -> str:
    out = epc_text(text, MAX_NAME)
    if not out:
        raise Pain001Error(f"{what}: no EPC character left in {text!r}")
    return out


def _bic(bic: str | None, what: str) -> str | None:
    if bic is None or bic == "":
        return None
    if not _BIC.fullmatch(bic):
        raise Pain001Error(f"{what}: invalid BIC {bic!r}")
    return bic


def _iban(iban: str, what: str) -> str:
    if not _IBAN.fullmatch(iban) or not iban_valid(iban):
        raise Pain001Error(f"{what}: invalid IBAN")
    if not iban_in_sepa(iban):
        raise Pain001Error(f"{what}: IBAN outside the SEPA schemes' countries")
    return iban


def _sub(parent: etree._Element, ns: str, tag: str, text: str | None = None) -> etree._Element:
    el = etree.SubElement(parent, f"{{{ns}}}{tag}")
    if text is not None:
        el.text = text
    return el


def _agent(parent: etree._Element, ns: str, tag: str, bic: str | None, version: str) -> None:
    fin = _sub(_sub(parent, ns, tag), ns, "FinInstnId")
    if bic is not None:
        _sub(fin, ns, "BICFI" if version == "pain.001.001.09" else "BIC", bic)
    else:
        _sub(_sub(fin, ns, "Othr"), ns, "Id", NOT_PROVIDED)


def _validate_inputs(f: TransferFile) -> None:
    namespace(f.version)
    epc_id(f.msg_id)
    if not f.payment_infos:
        raise Pain001Error("a file holds at least one PmtInf")
    seen_e2e: set[str] = set()
    seen_pmt: set[str] = set()
    for p in f.payment_infos:
        epc_id(p.pmt_inf_id)
        if p.pmt_inf_id in seen_pmt:
            raise Pain001Error(f"PmtInfId {p.pmt_inf_id} twice")
        seen_pmt.add(p.pmt_inf_id)
        if not p.transactions:
            raise Pain001Error(f"PmtInf {p.pmt_inf_id} holds no transaction")
        for t in p.transactions:
            epc_id(t.instr_id)
            epc_id(t.end_to_end_id)
            if t.end_to_end_id in seen_e2e:
                raise Pain001Error(f"EndToEndId {t.end_to_end_id} twice")
            seen_e2e.add(t.end_to_end_id)
            if t.currency != "EUR":
                raise Pain001Error(
                    f"{t.end_to_end_id}: SEPA files are in EUR only, not {t.currency}"
                )
            if not (0 < t.amount_minor <= MAX_AMOUNT_MINOR):
                raise Pain001Error(f"{t.end_to_end_id}: amount out of range")


def render(f: TransferFile) -> bytes:
    """The file's bytes (UTF-8, XML declaration, two-space indentation)."""
    _validate_inputs(f)
    ns = namespace(f.version)
    root = etree.Element(f"{{{ns}}}Document", nsmap={None: ns})
    init = _sub(root, ns, "CstmrCdtTrfInitn")
    hdr = _sub(init, ns, "GrpHdr")
    _sub(hdr, ns, "MsgId", f.msg_id)
    _sub(hdr, ns, "CreDtTm", f.created_at)
    _sub(hdr, ns, "NbOfTxs", str(f.nb_of_txs))
    _sub(hdr, ns, "CtrlSum", amount_text(f.ctrl_sum_minor))
    _sub(_sub(hdr, ns, "InitgPty"), ns, "Nm", _name(f.initiating_party, "InitgPty/Nm"))
    for p in f.payment_infos:
        pmt = _sub(init, ns, "PmtInf")
        _sub(pmt, ns, "PmtInfId", p.pmt_inf_id)
        _sub(pmt, ns, "PmtMtd", "TRF")
        _sub(pmt, ns, "BtchBookg", "false")
        _sub(pmt, ns, "NbOfTxs", str(len(p.transactions)))
        _sub(pmt, ns, "CtrlSum", amount_text(p.ctrl_sum_minor))
        _sub(_sub(_sub(pmt, ns, "PmtTpInf"), ns, "SvcLvl"), ns, "Cd", "SEPA")
        when = p.requested_execution_date.isoformat()
        if f.version == "pain.001.001.09":
            _sub(_sub(pmt, ns, "ReqdExctnDt"), ns, "Dt", when)
        else:
            _sub(pmt, ns, "ReqdExctnDt", when)
        _sub(_sub(pmt, ns, "Dbtr"), ns, "Nm", _name(p.debtor_name, "Dbtr/Nm"))
        _sub(
            _sub(_sub(pmt, ns, "DbtrAcct"), ns, "Id"), ns, "IBAN", _iban(p.debtor_iban, "DbtrAcct")
        )
        _agent(pmt, ns, "DbtrAgt", _bic(p.debtor_bic, "DbtrAgt"), f.version)
        _sub(pmt, ns, "ChrgBr", "SLEV")
        for t in p.transactions:
            tx = _sub(pmt, ns, "CdtTrfTxInf")
            pid = _sub(tx, ns, "PmtId")
            _sub(pid, ns, "InstrId", t.instr_id)
            _sub(pid, ns, "EndToEndId", t.end_to_end_id)
            amt = _sub(_sub(tx, ns, "Amt"), ns, "InstdAmt", amount_text(t.amount_minor))
            amt.set("Ccy", t.currency)
            bic = _bic(t.creditor_bic, f"CdtrAgt of {t.end_to_end_id}")
            if bic is not None:
                _agent(tx, ns, "CdtrAgt", bic, f.version)
            _sub(
                _sub(tx, ns, "Cdtr"),
                ns,
                "Nm",
                _name(t.creditor_name, f"Cdtr/Nm of {t.end_to_end_id}"),
            )
            iban = _iban(t.creditor_iban, f"CdtrAcct of {t.end_to_end_id}")
            _sub(_sub(_sub(tx, ns, "CdtrAcct"), ns, "Id"), ns, "IBAN", iban)
            info = epc_text(t.remittance_info, MAX_USTRD)
            if info:
                _sub(_sub(tx, ns, "RmtInf"), ns, "Ustrd", info)
    etree.indent(root, space="  ")
    return bytes(etree.tostring(root, xml_declaration=True, encoding="UTF-8"))


# -- structural check (every file, every version) -----------------------------------------------

# For each element the file writes: its children, in schema order, and whether each is required.
_CHILDREN: dict[str, tuple[tuple[str, bool], ...]] = {
    "Document": (("CstmrCdtTrfInitn", True),),
    "CstmrCdtTrfInitn": (("GrpHdr", True), ("PmtInf", True)),
    "GrpHdr": (
        ("MsgId", True),
        ("CreDtTm", True),
        ("NbOfTxs", True),
        ("CtrlSum", True),
        ("InitgPty", True),
    ),
    "InitgPty": (("Nm", True),),
    "PmtInf": (
        ("PmtInfId", True),
        ("PmtMtd", True),
        ("BtchBookg", True),
        ("NbOfTxs", True),
        ("CtrlSum", True),
        ("PmtTpInf", True),
        ("ReqdExctnDt", True),
        ("Dbtr", True),
        ("DbtrAcct", True),
        ("DbtrAgt", True),
        ("ChrgBr", True),
        ("CdtTrfTxInf", True),
    ),
    "PmtTpInf": (("SvcLvl", True),),
    "SvcLvl": (("Cd", True),),
    "Dbtr": (("Nm", True),),
    "Cdtr": (("Nm", True),),
    "DbtrAcct": (("Id", True),),
    "CdtrAcct": (("Id", True),),
    "DbtrAgt": (("FinInstnId", True),),
    "CdtrAgt": (("FinInstnId", True),),
    "CdtTrfTxInf": (
        ("PmtId", True),
        ("Amt", True),
        ("CdtrAgt", False),
        ("Cdtr", True),
        ("CdtrAcct", True),
        ("RmtInf", False),
    ),
    "PmtId": (("InstrId", True), ("EndToEndId", True)),
    "Amt": (("InstdAmt", True),),
    "RmtInf": (("Ustrd", True),),
}
_REPEATED = {"PmtInf", "CdtTrfTxInf"}


def _local(el: etree._Element) -> str:
    return etree.QName(el).localname


def _order(el: etree._Element, path: str) -> None:
    spec = _CHILDREN.get(_local(el))
    if spec is None:
        return
    names = [_local(c) for c in el]
    i = 0
    for name, required in spec:
        n = 0
        while i < len(names) and names[i] == name:
            i += 1
            n += 1
        if (required and n == 0) or (n > 1 and name not in _REPEATED):
            raise Pain001Error(f"{path}: {name} {'missing' if n == 0 else 'repeated'}")
    if i != len(names):
        raise Pain001Error(f"{path}: unexpected {names[i]}")


def _text(el: etree._Element, path: str, ns: str) -> str:
    found = el.find("/".join(f"{{{ns}}}{part}" for part in path.split("/")))
    if found is None or found.text is None:
        raise Pain001Error(f"{path} missing")
    return str(found.text)


def _check_text(value: str, limit: int, what: str) -> None:
    if (
        not value
        or len(value) > limit
        or not is_epc(value)
        or value != value.strip()
        or "  " in value
    ):
        raise Pain001Error(f"{what}: 1 to {limit} EPC characters, trimmed")


def _check_agent(agent: etree._Element, ns: str, version: str, what: str) -> None:
    fin = agent.find(f"{{{ns}}}FinInstnId")
    assert fin is not None  # noqa: S101 - checked by _order
    kids = [_local(c) for c in fin]
    bic_tag = "BICFI" if version == "pain.001.001.09" else "BIC"
    if kids == [bic_tag]:
        if not _BIC.fullmatch(_text(fin, bic_tag, ns)):
            raise Pain001Error(f"{what}: invalid BIC")
    elif kids == ["Othr"]:
        if _text(fin, "Othr/Id", ns) != NOT_PROVIDED:
            raise Pain001Error(f"{what}: Othr/Id must be NOTPROVIDED")
    else:
        raise Pain001Error(f"{what}: FinInstnId holds {bic_tag} or Othr/Id")


def _parse(xml: bytes) -> etree._Element:
    if b"<!DOCTYPE" in xml[:4096]:
        raise Pain001Error("a DTD is not allowed")
    parser = etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False)
    try:
        return etree.fromstring(xml, parser)
    except etree.XMLSyntaxError as exc:
        raise Pain001Error(f"not well-formed XML: {exc}") from exc


def check(xml: bytes, version: str) -> dict[str, object]:  # noqa: PLR0912, PLR0915 - one pass over the listed fields
    """Verify what design §11 lists; returns the header's facts. Raises Pain001Error."""
    ns = namespace(version)
    if not xml.startswith(b"<?xml version='1.0' encoding='UTF-8'?>"):
        raise Pain001Error("the file starts with its UTF-8 XML declaration")
    root = _parse(xml)
    if root.tag != f"{{{ns}}}Document":
        raise Pain001Error(f"root is not {version} Document")
    for el in root.iter():
        if not isinstance(el.tag, str) or etree.QName(el).namespace != ns:
            raise Pain001Error("only elements of the pain.001 namespace")
        _order(el, _local(el))
    init = root[0]
    hdr = init[0]
    msg_id = _text(hdr, "MsgId", ns)
    epc_id(msg_id)
    cre = _text(hdr, "CreDtTm", ns)
    if not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)?", cre
    ):
        raise Pain001Error("CreDtTm is not an ISO date-time")
    _check_text(_text(hdr, "InitgPty/Nm", ns), MAX_NAME, "InitgPty/Nm")
    total_n, total_minor = 0, 0
    pmt_ids: set[str] = set()
    e2e_ids: set[str] = set()
    for pmt in init.findall(f"{{{ns}}}PmtInf"):
        pid = _text(pmt, "PmtInfId", ns)
        epc_id(pid)
        if pid in pmt_ids:
            raise Pain001Error(f"PmtInfId {pid} twice")
        pmt_ids.add(pid)
        if _text(pmt, "PmtMtd", ns) != "TRF" or _text(pmt, "BtchBookg", ns) != "false":
            raise Pain001Error(f"{pid}: PmtMtd TRF and BtchBookg false")
        if _text(pmt, "PmtTpInf/SvcLvl/Cd", ns) != "SEPA" or _text(pmt, "ChrgBr", ns) != "SLEV":
            raise Pain001Error(f"{pid}: SvcLvl SEPA and ChrgBr SLEV")
        when = _text(pmt, "ReqdExctnDt/Dt" if version == "pain.001.001.09" else "ReqdExctnDt", ns)
        try:
            date.fromisoformat(when)
        except ValueError as exc:
            raise Pain001Error(f"{pid}: ReqdExctnDt is not a date") from exc
        _check_text(_text(pmt, "Dbtr/Nm", ns), MAX_NAME, f"{pid} Dbtr/Nm")
        debtor_iban = _text(pmt, "DbtrAcct/Id/IBAN", ns)
        if not iban_valid(debtor_iban) or not iban_in_sepa(debtor_iban):
            raise Pain001Error(f"{pid}: DbtrAcct IBAN invalid or outside SEPA")
        agent = pmt.find(f"{{{ns}}}DbtrAgt")
        assert agent is not None  # noqa: S101 - checked by _order
        _check_agent(agent, ns, version, f"{pid} DbtrAgt")
        n, minor = 0, 0
        for tx in pmt.findall(f"{{{ns}}}CdtTrfTxInf"):
            e2e = _text(tx, "PmtId/EndToEndId", ns)
            epc_id(e2e)
            epc_id(_text(tx, "PmtId/InstrId", ns))
            if e2e in e2e_ids:
                raise Pain001Error(f"EndToEndId {e2e} twice")
            e2e_ids.add(e2e)
            amt = tx.find(f"{{{ns}}}Amt/{{{ns}}}InstdAmt")
            assert amt is not None  # noqa: S101 - checked by _order
            if amt.get("Ccy") != "EUR" or list(amt.attrib) != ["Ccy"]:
                raise Pain001Error(f"{e2e}: InstdAmt in EUR")
            text = amt.text or ""
            if not _ISO_AMOUNT.fullmatch(text) or text in ("0.00",):
                raise Pain001Error(f"{e2e}: InstdAmt {text!r}")
            units, cents = text.split(".")
            minor += int(units) * 100 + int(cents)
            n += 1
            cagent = tx.find(f"{{{ns}}}CdtrAgt")
            if cagent is not None:
                _check_agent(cagent, ns, version, f"{e2e} CdtrAgt")
            _check_text(_text(tx, "Cdtr/Nm", ns), MAX_NAME, f"{e2e} Cdtr/Nm")
            creditor_iban = _text(tx, "CdtrAcct/Id/IBAN", ns)
            if not iban_valid(creditor_iban) or not iban_in_sepa(creditor_iban):
                raise Pain001Error(f"{e2e}: CdtrAcct IBAN invalid or outside SEPA")
            if tx.find(f"{{{ns}}}RmtInf") is not None:
                _check_text(_text(tx, "RmtInf/Ustrd", ns), MAX_USTRD, f"{e2e} Ustrd")
        if _text(pmt, "NbOfTxs", ns) != str(n) or _text(pmt, "CtrlSum", ns) != amount_text(minor):
            raise Pain001Error(f"{pid}: NbOfTxs / CtrlSum differ from its transactions")
        total_n += n
        total_minor += minor
    if _text(hdr, "NbOfTxs", ns) != str(total_n) or _text(hdr, "CtrlSum", ns) != amount_text(
        total_minor
    ):
        raise Pain001Error("GrpHdr NbOfTxs / CtrlSum differ from the transactions")
    return {
        "msg_id": msg_id,
        "nb_of_txs": total_n,
        "ctrl_sum_minor": total_minor,
        "pmt_inf_ids": sorted(pmt_ids),
    }


# -- XSD validation (when the schemas are vendored) ---------------------------------------------


def xsd_dir() -> Path:
    env = os.environ.get(XSD_DIR_ENV)
    if env:
        return Path(env)
    # worker/src/collectoo_worker/remittance/pain001.py → the repository's docs/reference/iso20022
    return Path(__file__).resolve().parents[4] / "docs" / "reference" / "iso20022"


@cache
def _schema(path: Path) -> etree.XMLSchema:
    parser = etree.XMLParser(resolve_entities=False, no_network=True)
    return etree.XMLSchema(etree.parse(str(path), parser))


def xsd_path(version: str, directory: Path | None = None) -> Path:
    namespace(version)
    return (directory or xsd_dir()) / f"{version}.xsd"


def xsd_available(version: str, directory: Path | None = None) -> bool:
    return xsd_path(version, directory).is_file()


def validate_xsd(xml: bytes, version: str, directory: Path | None = None) -> None:
    """Validate against the vendored ISO 20022 XSD; XsdUnavailableError when it is not vendored."""
    path = xsd_path(version, directory)
    if not path.is_file():
        raise XsdUnavailableError(f"{path} is not vendored (docs/reference/iso20022/README.md)")
    schema = _schema(path)
    doc = _parse(xml)
    if not schema.validate(doc):
        raise Pain001Error(f"XSD {version}: {schema.error_log.last_error}")
