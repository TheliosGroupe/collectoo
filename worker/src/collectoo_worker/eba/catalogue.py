"""Field catalogue of the EU NPL template, packaged from docs/reference (see `make catalogue`).

Column names follow tools/eba_catalogue/gen_sql.py; a test checks they match the migration.
"""

from __future__ import annotations

import csv
import io
import json
import re
from dataclasses import dataclass
from functools import cache
from importlib import resources
from typing import Any

TABLE_BY_TEMPLATE = {
    "T1": "t1_counterparty",
    "T3": "t3_loan",
    "T4.1": "t4_1_protection",
    "T4.2": "t4_2_mortgage",
    "T5": "t5_collection",
}


@dataclass(frozen=True)
class Field:
    field_id: str
    template_id: str
    name: str
    data_type: str
    allowed_values: tuple[str, ...]
    code_list: str
    mandatory: bool
    borrower_type: str
    loan_type: str

    @property
    def column(self) -> str:
        return column_name(self.field_id, self.name)


def column_name(field_id: str, name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    return f"f{field_id.replace('.', '_')}_{slug}"[:63].rstrip("_")


@cache
def fields() -> tuple[Field, ...]:
    text = resources.files(__package__).joinpath("field_catalogue.csv").read_text(encoding="utf-8")
    return tuple(
        Field(
            field_id=r["field_id"],
            template_id=r["template_id"],
            name=r["field_name"],
            data_type=r["data_type"],
            allowed_values=tuple(v for v in r["allowed_values"].split(" | ") if v),
            code_list=r["code_list"],
            mandatory=r["mandatory"] == "Y",
            borrower_type=r["borrower_type"],
            loan_type=r["loan_type"],
        )
        for r in csv.DictReader(io.StringIO(text))
    )


def columns(template_id: str) -> list[str]:
    """Tape columns of a template, in catalogue order."""
    return [f.column for f in fields() if f.template_id == template_id]


@cache
def json_schema() -> dict[str, Any]:
    text = resources.files(__package__).joinpath("template.schema.json").read_text(encoding="utf-8")
    schema: dict[str, Any] = json.loads(text)
    return schema
