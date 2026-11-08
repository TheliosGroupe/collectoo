"""Apply the declarative EU-template mapping (specs/eba_to_core.yaml) in both directions.

`to_core` turns Layer-1 rows (raw strings as in a tape, Annex III formats) into Layer-2 rows.
`from_core` regenerates the Layer-1 rows. The round trip is lossless: anything the operational
model does not hold (yet) travels in `source_attributes`.
"""

from __future__ import annotations

import datetime as dt
import re
from dataclasses import dataclass, field
from importlib import resources
from typing import Any

import yaml

Row = dict[str, Any]
Tape = dict[str, list[Row]]

DATE_FORMAT = "%d/%m/%Y"  # Annex III, Part 1 §3
_DATE_RE = re.compile(r"(?P<d>\d{2})/(?P<m>\d{2})/(?P<y>\d{4})")


class MappingError(ValueError):
    """A tape row cannot be mapped (missing key, unknown enum value, bad date)."""


@dataclass(frozen=True)
class FieldSpec:
    source: str
    target: str
    type: str
    required: bool = False
    values: dict[str, str] = field(default_factory=dict)

    @property
    def lossless(self) -> bool:
        return self.type != "enum" or len(set(self.values.values())) == len(self.values)


@dataclass(frozen=True)
class EntitySpec:
    source_table: str
    key_source: str
    key_target: str
    fields: tuple[FieldSpec, ...]


@dataclass(frozen=True)
class MappingSpec:
    version: int
    party: EntitySpec
    account: EntitySpec
    link_table: str
    link_party: str
    link_account: str
    link_constants: dict[str, str]
    capacity_by_kind: dict[str, str]

    def source_columns(self) -> set[str]:
        cols = {self.link_party, self.link_account}
        for e in (self.party, self.account):
            cols.add(e.key_source)
            cols.update(f.source for f in e.fields)
        return cols


def _entity(raw: dict[str, Any]) -> EntitySpec:
    return EntitySpec(
        source_table=raw["source_table"],
        key_source=raw["key"]["source"],
        key_target=raw["key"]["target"],
        fields=tuple(
            FieldSpec(
                source=f["source"],
                target=f["target"],
                type=f["type"],
                required=bool(f.get("required", False)),
                values=dict(f.get("values", {})),
            )
            for f in raw["fields"]
        ),
    )


def load_spec() -> MappingSpec:
    text = (
        resources.files("collectoo_worker.boarding.specs").joinpath("eba_to_core.yaml").read_text()
    )
    raw = yaml.safe_load(text)
    ents = raw["entities"]
    link = ents["account_party"]
    return MappingSpec(
        version=int(raw["version"]),
        party=_entity(ents["party"]),
        account=_entity(ents["account"]),
        link_table=link["source_table"],
        link_party=link["links"]["party"],
        link_account=link["links"]["account"],
        link_constants=dict(link["constants"]),
        capacity_by_kind=dict(link["derive"]["capacity"]["values"]),
    )


def _parse_date(raw: str, ref: str) -> dt.date:
    """Parse an Annex III date (DD/MM/YYYY). Business dates carry no time zone."""
    m = _DATE_RE.fullmatch(raw)
    try:
        if m is None:
            raise ValueError(raw)
        return dt.date(int(m["y"]), int(m["m"]), int(m["d"]))
    except ValueError as exc:
        raise MappingError(f"{ref}={raw!r} is not DD/MM/YYYY") from exc


def _parse(f: FieldSpec, raw: str | None, ref: str) -> object:
    if raw is None or raw == "":
        if f.required:
            raise MappingError(f"{ref}: {f.source} is required")
        return None
    if f.type == "date":
        return _parse_date(raw, f"{ref}: {f.source}")
    if f.type == "enum":
        if raw not in f.values:
            raise MappingError(f"{ref}: {f.source}={raw!r} is not an allowed value")
        return f.values[raw]
    return raw


def _format(f: FieldSpec, value: object) -> str | None:
    if value is None:
        return None
    if f.type == "date":
        if not isinstance(value, dt.date):
            raise MappingError(f"{f.target}: expected a date, got {value!r}")
        return value.strftime(DATE_FORMAT)
    if f.type == "enum":
        # Only reached for lossless enums: the inverse is unique.
        return next(k for k, v in f.values.items() if v == value)
    return str(value)


def _to_target(e: EntitySpec, row: Row, ref: str) -> Row:
    key = row.get(e.key_source)
    if not key:
        raise MappingError(f"{ref}: {e.key_source} is required")
    out: Row = {e.key_target: key}
    kept: Row = {}
    mapped_lossless = {e.key_source}
    for f in e.fields:
        out[f.target] = _parse(f, row.get(f.source), ref)
        if f.lossless:
            mapped_lossless.add(f.source)
    for col, val in row.items():
        if col not in mapped_lossless and val not in (None, ""):
            kept[col] = val
    out["source_attributes"] = kept
    return out


def _from_target(e: EntitySpec, row: Row, columns: list[str]) -> Row:
    out: Row = dict.fromkeys(columns)
    out.update(row.get("source_attributes", {}))
    out[e.key_source] = row[e.key_target]
    for f in e.fields:
        if f.lossless:
            out[f.source] = _format(f, row.get(f.target))
    return out


def to_core(tape: Tape, spec: MappingSpec | None = None) -> dict[str, list[Row]]:
    """Map Layer-1 rows to Layer-2 rows: party, account, account_party."""
    spec = spec or load_spec()
    parties = [
        _to_target(spec.party, r, f"{spec.party.source_table} row {i + 1}")
        for i, r in enumerate(tape.get(spec.party.source_table, []))
    ]
    accounts = [
        _to_target(spec.account, r, f"{spec.account.source_table} row {i + 1}")
        for i, r in enumerate(tape.get(spec.account.source_table, []))
    ]
    kind_by_ref = {p[spec.party.key_target]: p["kind"] for p in parties}
    account_refs = {a[spec.account.key_target] for a in accounts}
    links = []
    for i, r in enumerate(tape.get(spec.link_table, [])):
        party_ref, account_ref = r.get(spec.link_party), r.get(spec.link_account)
        if party_ref not in kind_by_ref or account_ref not in account_refs:
            raise MappingError(f"{spec.link_table} row {i + 1}: unknown counterparty or loan")
        links.append(
            {
                "party_seller_ref": party_ref,
                "account_external_ref": account_ref,
                "capacity": spec.capacity_by_kind[kind_by_ref[party_ref]],
                **spec.link_constants,
            }
        )
    return {"party": parties, "account": accounts, "account_party": links}


def from_core(
    core: dict[str, list[Row]], columns: dict[str, list[str]], spec: MappingSpec | None = None
) -> Tape:
    """Regenerate Layer-1 rows. `columns` lists each eba table's columns, in tape order."""
    spec = spec or load_spec()
    return {
        spec.party.source_table: [
            _from_target(spec.party, r, columns[spec.party.source_table]) for r in core["party"]
        ],
        spec.account.source_table: [
            _from_target(spec.account, r, columns[spec.account.source_table])
            for r in core["account"]
        ],
        spec.link_table: [
            {spec.link_party: r["party_seller_ref"], spec.link_account: r["account_external_ref"]}
            for r in core["account_party"]
        ],
    }
