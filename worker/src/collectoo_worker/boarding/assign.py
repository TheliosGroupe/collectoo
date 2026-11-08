"""Claim type and legal regime assignment (M1-14), from specs/claim_types.v1.yaml."""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from functools import cache
from importlib import resources
from typing import Any

import yaml


@dataclass(frozen=True)
class Assignment:
    claim_type: str | None
    legal_regime: str | None
    reason: str


@cache
def rules(version: int = 1) -> dict[str, Any]:
    text = (
        resources.files("collectoo_worker.boarding.specs")
        .joinpath(f"claim_types.v{version}.yaml")
        .read_text()
    )
    raw: dict[str, Any] = yaml.safe_load(text)
    return raw


def file_claim_type(
    mapped_targets: set[str], portfolio_default: str | None
) -> tuple[str | None, str]:
    """Claim type for a whole civil/commercial file."""
    if portfolio_default:
        return portfolio_default, "portfolio default"
    for signal in rules()["file_signals"]:
        if signal["target"] in mapped_targets:
            return signal["claim_type"], f"file has {signal['target']}"
    return None, "no rule matched"


def eba_claim_type(
    instrument: str | None, asset_class: str | None, portfolio_default: str | None
) -> tuple[str | None, str]:
    r = rules()["eba"]
    if instrument and instrument in r["by_instrument"]:
        return r["by_instrument"][instrument], f"instrument {instrument}"
    if asset_class and asset_class in r["by_asset_class"]:
        return r["by_asset_class"][asset_class], f"asset class {asset_class}"
    if portfolio_default:
        return portfolio_default, "portfolio default"
    return None, "no rule matched"


def legal_regime(claim_type: str | None, contract_date: dt.date | None) -> str | None:
    if claim_type is None:
        return None
    rule = rules()["legal_regime"].get(claim_type)
    if rule != "by_contract_date":
        return str(rule) if rule else None
    if contract_date is None:
        return None  # cannot tell pre-CCD2 from CCD2: blocking issue
    ccd2_from = rules()["ccd2_from"]
    return "consumer_credit_ccd2" if contract_date >= ccd2_from else "consumer_credit_pre_ccd2"
