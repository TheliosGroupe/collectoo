"""The money terms of a mandate version (M2-13 data, design §8.1, §8.2, §8.5; CPCE R124-3 3°, 4°).

Two documents, each stored as jsonb on `mandate_terms` with its clause reference in a column
(`commission_clause_ref`, `remittance_clause_ref`):

* the commission schedule `commission-1`: the basis (component families, forwards, what a reversal
  does) and the rules, first match wins, the last one matching everything; a rule's rate is flat,
  marginal (tiers on what the file brought in under the rule's tier key) or bracket (one rate chosen
  by a file attribute fixed at boarding); an optional minimum per file;
* the remittance terms `remittance-1`: frequency (twice monthly, or weekly on a weekday), the
  netting and claw-back clauses (null: none), the payment term of a due invoice (≤ 45 days after
  issue, C. com. L441-10 I), and the hold-back key reserved for M5 (empty).

Rates and amounts are strings (integer minor units, decimal rates with at most 4 decimals): no
float anywhere. These pydantic models are the Python twin of the SQL validators
`private.commission_schedule_error` / `private.remittance_terms_error` (migration
20261111120000): both give the same verdict on every case of the parity test (5,000 generated
documents of each kind, valid and invalid). The JSON Schemas in `schemas/` are generated from these
models (a unit test keeps them in step); the cross-field rules (ascending tiers, a catch-all last
rule, distinct ids) are the models' validators, not expressible in the schemas.
"""

from __future__ import annotations

import json
from itertools import pairwise
from pathlib import Path
from typing import Annotated, Any, ClassVar, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StrictBool,
    StrictInt,
    StringConstraints,
    ValidationError,
    field_validator,
    model_validator,
)

SCHEMAS = Path(__file__).parent / "schemas"
FAMILIES = ("principal", "interest", "indemnity", "charge", "cost", "unclassified")
BLANK = str.maketrans("", "", " \t\n\r")

Family = Literal["principal", "interest", "indemnity", "charge", "cost", "unclassified"]
# 0 ≤ rate ≤ 1, at most 4 decimals ("0.15", "1", "0.0600")
Rate = Annotated[str, StringConstraints(strict=True, pattern=r"^(0(\.[0-9]{1,4})?|1(\.0{1,4})?)$")]
# a non-negative amount in minor units (≤ 15 digits, no leading zero)
Minor = Annotated[str, StringConstraints(strict=True, pattern=r"^(0|[1-9][0-9]{0,14})$")]
Ident = Annotated[str, StringConstraints(strict=True, pattern=r"^[a-z0-9][a-z0-9_-]{0,39}$")]
ClaimType = Annotated[str, StringConstraints(strict=True, pattern=r"^[a-z][a-z0-9_]{0,39}$")]
PortfolioId = Annotated[
    str,
    StringConstraints(
        strict=True,
        pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    ),
]


def _text(value: str, max_len: int) -> str:
    """1..max_len characters, not only spaces, tabs and line breaks (the SQL twin's rule)."""
    if not 1 <= len(value) <= max_len or not value.translate(BLANK):
        raise ValueError("a non-blank text")
    return value


def _distinct(values: list[str]) -> list[str]:
    if len(set(values)) != len(values):
        raise ValueError("values repeat")
    return values


class _Doc(BaseModel):
    """Strict JSON: no unknown key, no coercion (a number is not a string, a boolean not an
    integer). Optional keys may be absent but never null."""

    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)
    _not_null: ClassVar[frozenset[str]] = frozenset()

    @model_validator(mode="before")
    @classmethod
    def _no_null_optional(cls, data: Any) -> Any:
        if isinstance(data, dict):
            for key in cls._not_null:
                if key in data and data[key] is None:
                    raise ValueError(f"{key} may be absent, never null")
        return data


# -- commission-1 ---------------------------------------------------------------------------------


class Forwards(_Doc):
    """Which forwards (money passed on without allocation) earn commission (founder #4: none unless
    the mandate says so)."""

    file_recalled: StrictBool
    before_servicing_start: StrictBool
    client_ratification: StrictBool


class Basis(_Doc):
    families: Literal["all"] | Annotated[list[Family], Field(min_length=1, max_length=6)]
    forwards: Forwards
    on_reversal: Literal["credit", "keep"]  # keep: only when the clause says the fee stays due

    @field_validator("families")
    @classmethod
    def _families(cls, v: str | list[str]) -> str | list[str]:
        return v if isinstance(v, str) else _distinct(v)


class Match(_Doc):
    _not_null: ClassVar[frozenset[str]] = frozenset({"claim_types", "families", "portfolio_ids"})
    claim_types: list[ClaimType] = Field(default_factory=list, min_length=1, max_length=20)
    families: list[Family] = Field(default_factory=list, min_length=1, max_length=6)
    portfolio_ids: list[PortfolioId] = Field(default_factory=list, min_length=1, max_length=50)

    @field_validator("claim_types", "families", "portfolio_ids")
    @classmethod
    def _sets(cls, v: list[str]) -> list[str]:
        return _distinct(v)

    def matches_everything(self) -> bool:
        return not (self.claim_types or self.families or self.portfolio_ids)


class Tier(_Doc):
    up_to_minor: Minor | None  # null: the last, unbounded tier
    rate: Rate


class Bracket(_Doc):
    up_to: Minor | None  # boarded amount in minor units, or age in days; null: the last
    rate: Rate


def _bands(bounds: list[str | None]) -> None:
    """Bounds strictly ascending from 0, only the last unbounded."""
    *head, last = bounds
    if last is not None or any(b is None or b == "0" for b in head):
        raise ValueError("only the last band is unbounded, and no bound is 0")
    values = [int(b) for b in head if b is not None]
    if any(b <= a for a, b in pairwise(values)):
        raise ValueError("bounds ascend")


class FlatRate(_Doc):
    kind: Literal["flat"]
    rate: Rate


class MarginalRate(_Doc):
    """Tiers on what the file brought in under the rule's tier key, net of reversals. (Whole-rate
    tiers on cumulative collections are not offered: the rate would fall as collections rise.)"""

    kind: Literal["marginal"]
    tiers: list[Tier] = Field(min_length=1, max_length=20)

    @field_validator("tiers")
    @classmethod
    def _ascending(cls, v: list[Tier]) -> list[Tier]:
        _bands([t.up_to_minor for t in v])
        return v


class BracketRate(_Doc):
    """One rate for the whole file, chosen by an attribute fixed at boarding."""

    kind: Literal["bracket"]
    attribute: Literal["boarded_amount", "age_days_at_boarding"]
    brackets: list[Bracket] = Field(min_length=1, max_length=20)

    @field_validator("brackets")
    @classmethod
    def _ascending(cls, v: list[Bracket]) -> list[Bracket]:
        _bands([b.up_to for b in v])
        return v


class Rule(_Doc):
    _not_null: ClassVar[frozenset[str]] = frozenset({"min_per_file_minor"})
    id: Ident
    tier_key: Ident  # stable across versions: tiers continue when the terms change
    label_fr: str
    match: Match
    rate: Annotated[FlatRate | MarginalRate | BracketRate, Field(discriminator="kind")]
    min_per_file_minor: Minor | None = None  # capped so the TTC never exceeds the file's basis

    @field_validator("label_fr")
    @classmethod
    def _label(cls, v: str) -> str:
        return _text(v, 200)


class CommissionSchedule(_Doc):
    """`commission-1` (design §8.1)."""

    model_config = ConfigDict(
        extra="forbid", strict=True, frozen=True, title="Barème de commission (commission-1)"
    )
    schema_: Literal["commission-1"] = Field(alias="schema")
    basis: Basis
    rules: list[Rule] = Field(min_length=1, max_length=50)

    @model_validator(mode="after")
    def _rules(self) -> CommissionSchedule:
        _distinct([r.id for r in self.rules])
        _distinct([r.tier_key for r in self.rules])
        if not self.rules[-1].match.matches_everything():
            raise ValueError("the last rule matches everything")
        return self


# -- remittance-1 ---------------------------------------------------------------------------------


class Clause(_Doc):
    clause_ref: str

    @field_validator("clause_ref")
    @classmethod
    def _ref(cls, v: str) -> str:
        return _text(v, 200)


class RemittanceTerms(_Doc):
    """`remittance-1` (design §8.2): R124-3 4°; the delay itself is
    mandate_terms.remittance_max_days (1..30, the one source)."""

    model_config = ConfigDict(
        extra="forbid", strict=True, frozen=True, title="Conditions de reversement (remittance-1)"
    )
    _not_null: ClassVar[frozenset[str]] = frozenset({"weekday", "holdback"})
    schema_: Literal["remittance-1"] = Field(alias="schema")
    frequency: Literal["twice_monthly", "weekly"]  # twice monthly: the 1st and the 16th
    weekday: Annotated[StrictInt, Field(ge=1, le=5)] | None = None  # weekly only: ISO, Monday = 1
    netting: Clause | None  # null: gross remittance, the invoice is due
    clawback: Clause | None  # null: advances recovered by a repayment request
    invoice_payment_days: StrictInt = Field(ge=0, le=45)  # L441-10 I: ≤ 45 days after issue
    holdback: list[Any] = Field(default_factory=list, max_length=0)  # reserved (M5): empty

    @model_validator(mode="after")
    def _weekday(self) -> RemittanceTerms:
        if (self.frequency == "weekly") != ("weekday" in self.model_fields_set):
            raise ValueError("a weekday for a weekly frequency only")
        return self


# -- the validators -----------------------------------------------------------------------------


def commission_schedule_error(doc: object) -> str | None:
    """The first error of a schedule (pydantic's message), or None when it is valid."""
    try:
        CommissionSchedule.model_validate(doc)
    except ValidationError as exc:
        return str(exc.errors(include_url=False)[0]["msg"])
    return None


def remittance_terms_error(doc: object) -> str | None:
    try:
        RemittanceTerms.model_validate(doc)
    except ValidationError as exc:
        return str(exc.errors(include_url=False)[0]["msg"])
    return None


def commission_schedule_valid(doc: object) -> bool:
    return commission_schedule_error(doc) is None


def remittance_terms_valid(doc: object) -> bool:
    return remittance_terms_error(doc) is None


def json_schemas() -> dict[str, str]:
    """The committed JSON Schemas (schemas/*.json), as generated from the models."""
    return {
        "commission-1.json": _dump(CommissionSchedule.model_json_schema(by_alias=True)),
        "remittance-1.json": _dump(RemittanceTerms.model_json_schema(by_alias=True)),
    }


def _dump(schema: dict[str, Any]) -> str:
    return json.dumps(schema, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def legacy_schedule(rate: str) -> dict[str, Any]:
    """The schedule the M2c-2 back-fill gives an earlier version (one flat rule at its
    commission_rate; `private.legacy_commission_schedule`)."""
    return {
        "schema": "commission-1",
        "basis": {
            "families": "all",
            "forwards": {
                "file_recalled": False,
                "before_servicing_start": False,
                "client_ratification": False,
            },
            "on_reversal": "credit",
        },
        "rules": [
            {
                "id": "taux-unique",
                "tier_key": "taux-unique",
                "label_fr": "Taux unique (repris de l'ancien taux de commission)",
                "match": {},
                "rate": {"kind": "flat", "rate": rate},
            }
        ],
    }


if __name__ == "__main__":  # regenerate the committed schemas
    for name, text in json_schemas().items():
        (SCHEMAS / name).write_text(text, encoding="utf-8")
