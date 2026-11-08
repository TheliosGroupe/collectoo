"""Canonical mapping target registry (M1-06): Layer-2 fields plus EU-template fields."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from functools import cache
from importlib import resources

import yaml

from collectoo_worker.eba.catalogue import fields

EBA_VALUE_TYPES = {
    "Date": ("date_fr",),
    "Number": ("decimal_dot", "integer"),
    "Percentage": ("decimal_dot", "integer"),
}


@dataclass(frozen=True)
class Target:
    id: str
    type: str
    description: str
    example: str = ""
    aliases: tuple[str, ...] = ()
    value_types: tuple[str, ...] = field(default_factory=tuple)


@cache
def registry() -> tuple[Target, ...]:
    text = resources.files("collectoo_worker.boarding.specs").joinpath("targets.yaml").read_text()
    raw = yaml.safe_load(text)["targets"]
    layer2 = [
        Target(
            id=tid,
            type=t["type"],
            description=t["description"],
            example=str(t.get("example", "")),
            aliases=tuple(t.get("aliases", [])),
            value_types=tuple(t.get("value_types", [])),
        )
        for tid, t in raw.items()
    ]
    eba = [
        Target(
            id=f"eba.{f.column}",
            type=f.data_type.lower(),
            description=f"EU NPL template {f.field_id} {f.name}",
            aliases=(f.column, f.name),
            value_types=EBA_VALUE_TYPES.get(f.data_type, ()),
        )
        for f in fields()
    ]
    return tuple(layer2 + eba)


def by_id() -> dict[str, Target]:
    return {t.id: t for t in registry()}


def export_json() -> str:
    """Registry as JSON, e.g. for the review UI or a real LLM prompt."""
    return json.dumps([asdict(t) for t in registry()], ensure_ascii=False, indent=1)
