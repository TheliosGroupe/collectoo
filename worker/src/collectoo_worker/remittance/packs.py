"""The M2c rule packs (design §8.5; ADR-0005, ADR-0014 M2c-3): versioned YAML with the legal texts
they rely on, read from `worker/rule_packs/` (or `$COLLECTOO_RULE_PACKS`).

* `vat/fr.yaml`: the VAT rate rows (seeded into `public.vat_rate`; CI checks the table equals the
  file), the dated texts the engine and the documents rely on, and the review tripwire of the 2027
  recodification;
* `remittance/fr.yaml`: the R124-6 deadline (founder #2), the alert margins and the conservative
  business calendar (seeded into `public.business_calendar`; CI checks the table equals the calendar
  computed from the file).

The loader refuses floats anywhere (a rate is a decimal string), unknown keys, and a text cited
without its quote: a URL means the text was read and is quoted; a convention that is not law carries
a note instead.
"""

from __future__ import annotations

import os
from datetime import date
from decimal import Decimal
from functools import cache
from itertools import pairwise
from pathlib import Path
from typing import Annotated, Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

RULE_PACKS = Path(
    os.environ.get("COLLECTOO_RULE_PACKS") or Path(__file__).resolve().parents[3] / "rule_packs"
)

Rate = Annotated[str, StringConstraints(strict=True, pattern=r"^(0(\.[0-9]{1,4})?|1(\.0{1,4})?)$")]


class _Pack(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Review(_Pack):
    """A dated re-reading: from `due_from` CI fails (and `vat_pack_review` alerts) until a human
    records who re-read the text and when."""

    due_from: date
    reviewed_on: date | None
    reviewed_by: str | None

    @model_validator(mode="after")
    def _both(self) -> Review:
        if (self.reviewed_on is None) != (self.reviewed_by is None):
            raise ValueError("a review records its date and who reviewed")
        return self


class LegalRef(_Pack):
    """A text the pack relies on: read (url + version + verbatim quote) or a convention (note, no
    quote)."""

    title: str
    url: str | None = None
    version: str | None = None
    quote: str | None = None
    note: str | None = None
    valid_from: date | None = None
    valid_to: date | None = None  # exclusive
    review: Review | None = None  # a text not yet in force when read: re-read before it applies

    @model_validator(mode="after")
    def _read_or_noted(self) -> LegalRef:
        if self.url is not None:
            if (
                not self.url.startswith("https://librejustice.fr/norm/")
                or not self.quote
                or not self.version
            ):
                raise ValueError(
                    f"{self.title}: a text read on LibreJustice needs its version and a quote"
                )
        elif not self.note or self.quote:
            raise ValueError(
                f"{self.title}: a reference that was not read needs a note and no quote"
            )
        return self


# -- vat/fr ---------------------------------------------------------------------------------------


class VatRateRow(_Pack):
    code: Literal["standard"]
    territory: Literal["FR-metro"]
    rate: Rate
    valid_from: date
    valid_to: date | None  # exclusive
    legal_ref: LegalRef
    review: Review | None = None

    @property
    def rate_decimal(self) -> Decimal:
        return Decimal(self.rate)

    def covers(self, day: date) -> bool:
        return self.valid_from <= day and (self.valid_to is None or day < self.valid_to)


class VatReference(_Pack):
    id: str
    applies: str
    texts: list[LegalRef] = Field(min_length=1)


class VatPack(_Pack):
    pack: Literal["vat/fr"]
    schema_: Literal["vat-pack-1"] = Field(alias="schema")
    label_fr: str
    read_on: date
    rates: list[VatRateRow] = Field(min_length=1)
    references: list[VatReference]

    def texts(self) -> list[tuple[LegalRef, date | None, Review | None]]:
        """Every text the pack relies on, with the day it applies from and its review: the rate
        rows' (their review is the row's) and the references'."""
        out: list[tuple[LegalRef, date | None, Review | None]] = [
            (r.legal_ref, r.valid_from, r.review) for r in self.rates
        ]
        out += [(t, t.valid_from, t.review) for ref in self.references for t in ref.texts]
        return out

    @model_validator(mode="after")
    def _reviews(self) -> VatPack:
        """A text not yet in force on the day the pack was read (the 2027 recodification) carries a
        review due before it applies; the reviews due the same day are recorded together, so the
        rate row's review (seeded into public.vat_rate, the SQL alert) attests all of them."""
        recorded: dict[date, tuple[date | None, str | None]] = {}
        for text, applies, review in self.texts():
            late = applies is not None and applies > self.read_on
            if late and (review is None or applies is None or review.due_from >= applies):
                raise ValueError(f"{text.title}: applies from {applies}, needs a review before")
            if review is not None:
                state = (review.reviewed_on, review.reviewed_by)
                if recorded.setdefault(review.due_from, state) != state:
                    raise ValueError(
                        f"{text.title}: the reviews due {review.due_from} are recorded together"
                    )
        return self

    @model_validator(mode="after")
    def _no_overlap(self) -> VatPack:
        keys = {(r.code, r.territory) for r in self.rates}
        for key in keys:
            rows = sorted(
                (r for r in self.rates if (r.code, r.territory) == key), key=lambda r: r.valid_from
            )
            for a, b in pairwise(rows):
                if a.valid_to is None or a.valid_to > b.valid_from:
                    raise ValueError(f"vat rows of {key} overlap")
        for r in self.rates:
            if r.valid_to is not None and r.valid_to <= r.valid_from:
                raise ValueError("a vat row ends after it starts")
        return self


# -- remittance/fr --------------------------------------------------------------------------------


class Deadline(_Pack):
    months: Literal[1]
    encaissement: Literal["earlier_of_booking_and_value_date"]
    weekend_holiday_extension: Literal[False]
    latest_execution: Literal["business_day_before_last_business_day"]
    alert_soon_business_days: int = Field(ge=1, le=10)
    alert_critical_business_days: int = Field(ge=1, le=10)
    legal_refs: list[LegalRef] = Field(min_length=1)


class ClosingDay(_Pack):
    """A closing day: a fixed day of the year, or a day relative to Easter Sunday."""

    id: str
    month: int | None = Field(default=None, ge=1, le=12)
    day: int | None = Field(default=None, ge=1, le=31)
    easter_offset: int | None = Field(default=None, ge=-60, le=60)
    label_fr: str
    sources: list[Literal["public_holiday", "target"]] = Field(min_length=1)

    @model_validator(mode="after")
    def _one_kind(self) -> ClosingDay:
        fixed = self.month is not None and self.day is not None
        if fixed == (self.easter_offset is not None) or (self.month is None) != (self.day is None):
            raise ValueError(f"{self.id}: a fixed day (month, day) or an Easter offset, not both")
        if fixed:
            date(2028, self.month or 1, self.day or 1)  # a real day (leap year: 29/02 allowed)
        return self


class CalendarSpec(_Pack):
    scope: Literal["FR-conservative"]
    zone: Literal["Europe/Paris"]
    weekend_isodays: list[int]
    seeded_from: date
    seeded_to: date
    min_horizon_months: int = Field(ge=1, le=60)
    closing_days: list[ClosingDay] = Field(min_length=1)
    legal_refs: list[LegalRef] = Field(min_length=1)

    @model_validator(mode="after")
    def _horizon(self) -> CalendarSpec:
        if self.seeded_from.timetuple().tm_yday != 1 or (
            self.seeded_to.month,
            self.seeded_to.day,
        ) != (12, 31):
            raise ValueError("the calendar is seeded by whole years")
        if self.seeded_to <= self.seeded_from:
            raise ValueError("an empty horizon")
        if sorted(set(self.weekend_isodays)) != self.weekend_isodays or not set(
            self.weekend_isodays
        ) <= set(range(1, 8)):
            raise ValueError("weekend days are ISO weekdays, ascending")
        if len({c.id for c in self.closing_days}) != len(self.closing_days):
            raise ValueError("closing day ids repeat")
        return self


class Schedule(_Pack):
    twice_monthly_days: list[int]


class RemittancePack(_Pack):
    pack: Literal["remittance/fr"]
    schema_: Literal["remittance-pack-1"] = Field(alias="schema")
    label_fr: str
    read_on: date
    deadline: Deadline
    calendar: CalendarSpec
    schedule: Schedule


# -- loading --------------------------------------------------------------------------------------


def _refuse_floats(node: Any, where: str) -> None:
    if isinstance(node, float):
        raise ValueError(f"{where}: a float in a rule pack (write rates and amounts as strings)")
    if isinstance(node, dict):
        for k, v in node.items():
            _refuse_floats(v, f"{where}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _refuse_floats(v, f"{where}[{i}]")


def load_yaml(path: Path) -> Any:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    _refuse_floats(data, path.name)
    return data


@cache
def vat_pack(root: Path = RULE_PACKS) -> VatPack:
    return VatPack.model_validate(load_yaml(root / "vat" / "fr.yaml"))


@cache
def remittance_pack(root: Path = RULE_PACKS) -> RemittancePack:
    return RemittancePack.model_validate(load_yaml(root / "remittance" / "fr.yaml"))
