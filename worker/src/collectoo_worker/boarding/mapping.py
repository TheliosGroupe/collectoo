"""Mapping proposals (M1-08) and reusable mapping profiles (M1-10)."""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from typing import Any

from collectoo_worker.ai.gateway import Gateway
from collectoo_worker.boarding.targets import registry

REVIEW_BELOW = 0.75
JOIN_KEY_TARGETS = ("account.external_ref", "party.siren", "eba.f3_01_loan_identifier",
                    "eba.f1_02_counterparty_identifier")  # fmt: skip


@dataclass(frozen=True)
class Proposal:
    source_column: str
    target: str | None
    confidence: float
    rationale: str
    needs_review: bool
    origin: str  # llm | mock | profile


def header_signature(headers: list[str]) -> str:
    """Same as SQL: sha256 of the jsonb text of the headers sorted by code point."""
    text = json.dumps(sorted(headers), ensure_ascii=False)
    return hashlib.sha256(text.encode()).hexdigest()


def columns_payload(profile: dict[str, Any]) -> list[dict[str, Any]]:
    """What the model sees per column: header, detected patterns, a few sample values."""
    return [
        {
            "name": c["name"],
            "type_guess": c["type_guess"],
            "patterns": c["patterns"],
            "samples": [v["value"] for v in c.get("top_values", [])[:3]],
        }
        for c in profile["columns"]
    ]


def targets_payload() -> list[dict[str, Any]]:
    return [
        {
            "id": t.id,
            "description": t.description,
            "aliases": list(t.aliases),
            "value_types": list(t.value_types),
        }
        for t in registry()
    ]


def from_saved_profile(
    headers: list[str], mapping: dict[str, str | None], version: int
) -> list[Proposal]:
    return [
        Proposal(
            h,
            mapping.get(h),
            1.0,
            f"mapping validé v{version} réutilisé pour ce format de fichier",
            False,
            "profile",
        )
        for h in headers
    ]


def propose(
    gateway: Gateway, profile: dict[str, Any], *, batch_id: str | None = None
) -> list[Proposal]:
    payload = {"columns": columns_payload(profile), "targets": targets_payload()}
    out = gateway.run("mapping_proposal", payload, batch_id=batch_id)
    known = {t.id for t in registry()}
    origin = "mock" if gateway.provider.name == "mock" else "llm"
    proposals = []
    for p in out["proposals"]:
        target = p["target"] if p["target"] in known else None  # never trust an unknown id
        conf = float(p["confidence"]) if target else 0.0
        review = target is not None and conf < REVIEW_BELOW
        proposals.append(Proposal(p["source_column"], target, conf, p["rationale"], review, origin))
    return proposals


def join_keys(files: dict[str, list[Proposal]]) -> list[dict[str, Any]]:
    """Targets mapped in two or more files of a batch: the columns that link those files."""
    out = []
    for target in JOIN_KEY_TARGETS:
        cols = {
            fid: p.source_column
            for fid, props in files.items()
            for p in props
            if p.target == target
        }
        if len(cols) > 1:
            out.append({"target": target, "columns": cols})
    return out


def to_rows(proposals: list[Proposal]) -> list[dict[str, Any]]:
    return [asdict(p) for p in proposals]
