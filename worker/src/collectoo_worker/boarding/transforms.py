"""Declarative, versioned transformations (M1-11) and normalisers (M1-12).

A transformation is a list of steps applied to one source value. Each step is a pure function:
str -> value, raising TransformError when the value cannot be converted (the row then gets a
validation issue; nothing is guessed). Spec (YAML, versioned):

    version: 1
    defaults:              # chain per target type, used unless the mapping overrides it
      date: [trim, {parse_date: {formats: auto}}]
    overrides:             # optional, per target id
      claim_item.kind: [trim, upper, {lookup: {table: document_kind}}]

Values are transformed once per distinct value (cached), so a 1M-row tape costs one pass per
distinct value, not per row.
"""

from __future__ import annotations

import datetime as dt
import re
from collections.abc import Callable
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from functools import cache
from importlib import resources
from typing import Any

import phonenumbers
import polars as pl
import yaml

from collectoo_worker.synth.ids import iban_valid, luhn_valid

DATE_FORMATS = {"date_fr": "%d/%m/%Y", "date_iso": "%Y-%m-%d", "date_dotted": "%d.%m.%Y"}
_DATE_SHAPES = {
    "date_fr": re.compile(r"^(\d{2})/(\d{2})/(\d{4})$"),
    "date_iso": re.compile(r"^(\d{4})-(\d{2})-(\d{2})$"),
    "date_dotted": re.compile(r"^(\d{2})\.(\d{2})\.(\d{4})$"),
}
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")
_SPACES = re.compile(r"[\s\u00a0\u202f]+")


class TransformError(ValueError):
    """A value that cannot be converted; reported as a validation issue for the row."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


Step = Callable[[Any], Any]


# --- Steps ------------------------------------------------------------------------------------


def trim(v: Any) -> Any:
    return _SPACES.sub(" ", v).strip() if isinstance(v, str) else v


def upper(v: Any) -> Any:
    return v.upper() if isinstance(v, str) else v


def lower(v: Any) -> Any:
    return v.lower() if isinstance(v, str) else v


def digits_only(v: Any) -> Any:
    return re.sub(r"\D", "", v) if isinstance(v, str) else v


def parse_date(formats: str | list[str] = "auto") -> Step:
    """French (dd/mm/yyyy), ISO and dotted dates; `auto` accepts any of them (mixed files)."""
    names = list(DATE_FORMATS) if formats == "auto" else list(formats)

    def step(v: Any) -> dt.date:
        for name in names:
            m = _DATE_SHAPES[name].match(v)
            if not m:
                continue
            a, b, c = (int(x) for x in m.groups())
            y, mo, d = (a, b, c) if name == "date_iso" else (c, b, a)
            try:
                return dt.date(y, mo, d)
            except ValueError as exc:
                raise TransformError("impossible_date", f"{v!r} is not a calendar date") from exc
        raise TransformError("bad_date", f"{v!r} is not a date in {names}")

    return step


def parse_decimal(decimal: str = "auto") -> Step:
    """'1 234,56' / '1.234,56' / '1234.56' -> Decimal. `auto`: the last ',' or '.' is decimal."""

    def step(v: Any) -> Decimal:
        s = _SPACES.sub("", v).replace("'", "")
        sep = decimal
        if sep == "auto":  # the last separator is the decimal mark if it appears once
            last = max(s.rfind(","), s.rfind("."))
            sep = s[last] if last >= 0 and s.count(s[last]) == 1 else ""
        if sep == ",":
            s = s.replace(".", "").replace(",", ".")
        elif sep == ".":
            s = s.replace(",", "")
        else:
            s = s.replace(",", "").replace(".", "")
        if not re.fullmatch(r"-?\d+(\.\d+)?", s):
            raise TransformError("bad_amount", f"{v!r} is not an amount")
        try:
            return Decimal(s)
        except InvalidOperation as exc:  # pragma: no cover - guarded by the regex
            raise TransformError("bad_amount", f"{v!r} is not an amount") from exc

    return step


def to_minor(exponent: int = 2) -> Step:
    """Decimal major units -> integer minor units, rounded half-up (never floats)."""
    quantum = Decimal(1).scaleb(-exponent)

    def step(v: Any) -> int:
        return int(v.quantize(quantum, rounding=ROUND_HALF_UP).scaleb(exponent))

    return step


def lookup(table: str, default: str | None = None) -> Step:
    entries = lookup_tables()[table]

    def step(v: Any) -> Any:
        key = v.upper() if isinstance(v, str) else v
        if key in entries:
            return entries[key]
        if default is not None:
            return default
        raise TransformError("unknown_value", f"{v!r} is not in lookup table {table}")

    return step


def default(value: Any) -> Step:
    def step(v: Any) -> Any:
        return value if v in (None, "") else v

    return step


def zero_pad(width: int) -> Step:
    def step(v: Any) -> Any:
        return v.zfill(width) if isinstance(v, str) and v.isdigit() else v

    return step


def e164(region: str = "FR") -> Step:
    def step(v: Any) -> str:
        try:
            num = phonenumbers.parse(v, region)
        except phonenumbers.NumberParseException as exc:
            raise TransformError("bad_phone", f"{v!r} is not a phone number") from exc
        if not phonenumbers.is_valid_number(num):
            raise TransformError("bad_phone", f"{v!r} is not a valid phone number")
        return phonenumbers.format_number(num, phonenumbers.PhoneNumberFormat.E164)

    return step


_CHECKS: dict[str, Callable[[str], bool]] = {
    "siren": lambda s: len(s) == 9 and s.isdigit() and luhn_valid(s),
    "siret": lambda s: len(s) == 14 and s.isdigit() and luhn_valid(s),
    "iban": iban_valid,
    "email": lambda s: bool(_EMAIL.match(s)),
    "postcode_fr": lambda s: bool(re.fullmatch(r"\d{5}", s)),
    "currency": lambda s: bool(re.fullmatch(r"[A-Z]{3}", s)),
}


def check(kind: str) -> Step:
    """Validators that keep the value: siren, siret, iban, email, postcode_fr, currency."""
    valid = _CHECKS[kind]

    def step(v: Any) -> Any:
        if not valid(v):
            raise TransformError(f"invalid_{kind}", f"{v!r} is not a valid {kind}")
        return v

    return step


def no_spaces(v: Any) -> Any:
    return _SPACES.sub("", v) if isinstance(v, str) else v


SIMPLE_STEPS: dict[str, Step] = {
    "trim": trim,
    "upper": upper,
    "lower": lower,
    "digits_only": digits_only,
    "no_spaces": no_spaces,
}
PARAM_STEPS: dict[str, Callable[..., Step]] = {
    "parse_date": parse_date,
    "parse_decimal": parse_decimal,
    "to_minor": to_minor,
    "lookup": lookup,
    "default": default,
    "zero_pad": zero_pad,
    "e164": e164,
    "check": check,
}


# --- Specs ---------------------------------------------------------------------------------------


@dataclass(frozen=True)
class TransformSpec:
    version: int
    defaults: dict[str, list[Any]]
    overrides: dict[str, list[Any]]
    target_types: dict[str, str]

    def chain_for(self, target: str) -> list[Step]:
        raw = self.overrides.get(target) or self.defaults.get(
            self.target_types.get(target, "text"), []
        )
        return [build_step(s) for s in raw]


def build_step(raw: Any) -> Step:
    if isinstance(raw, str):
        return SIMPLE_STEPS[raw]
    ((name, params),) = raw.items()
    if isinstance(params, dict):
        return PARAM_STEPS[name](**params)
    return PARAM_STEPS[name](params)


@cache
def lookup_tables() -> dict[str, dict[str, Any]]:
    raw = yaml.safe_load(_spec_text("lookups.yaml"))
    return {name: {str(k).upper(): v for k, v in table.items()} for name, table in raw.items()}


def _spec_text(name: str) -> str:
    return resources.files("collectoo_worker.boarding.specs").joinpath(name).read_text()


@cache
def load_spec(version: int = 1) -> TransformSpec:
    from collectoo_worker.boarding.targets import registry  # noqa: PLC0415 - avoid import cycle

    raw = yaml.safe_load(_spec_text(f"transforms.v{version}.yaml"))
    return TransformSpec(
        version=int(raw["version"]),
        defaults=raw["defaults"],
        overrides=raw.get("overrides", {}),
        target_types={t.id: t.type for t in registry()},
    )


# --- Application ----------------------------------------------------------------------------------


def apply_chain(chain: list[Step], value: str | None) -> tuple[Any, TransformError | None]:
    if value is None or value.strip() == "":
        return None, None
    v: Any = value
    try:
        for step in chain:
            v = step(v)
    except TransformError as err:
        return None, err
    return (None if v == "" else v), None


def _dtype(sample: Any) -> pl.DataType:
    if isinstance(sample, bool):
        return pl.Boolean()
    if isinstance(sample, int):
        return pl.Int64()
    if isinstance(sample, dt.date):
        return pl.Date()
    return pl.Utf8()  # text, and Decimal amounts in major units kept as exact strings


def transform_column(
    series: pl.Series, chain: list[Step]
) -> tuple[pl.Series, dict[int, TransformError]]:
    """Transform a column once per distinct value.

    Returns a typed series (null where empty or invalid) and the errors by row index. Memory
    stays proportional to the column, not to Python objects per row.
    """
    uniques = series.unique().to_list()
    results = {raw: apply_chain(chain, raw) for raw in uniques}
    sample = next((v for v, _ in results.values() if v is not None), None)
    dtype = _dtype(sample)
    keys = [k for k in results if k is not None]
    values = [
        str(results[k][0]) if isinstance(results[k][0], Decimal) else results[k][0] for k in keys
    ]
    if dtype == pl.Utf8 and series.dtype == pl.Utf8 and keys == values:
        out = series  # already clean text: share the column instead of copying it
    elif keys:
        out = series.replace_strict(keys, values, default=None, return_dtype=dtype)
    else:
        out = pl.Series(series.name, [None] * len(series), dtype=dtype)
    errors: dict[int, TransformError] = {}
    bad = {k: err for k, (_, err) in results.items() if err is not None}
    if bad:
        for i in series.is_in(list(bad)).arg_true().to_list():
            errors[i] = bad[series[i]]
    return out, errors
