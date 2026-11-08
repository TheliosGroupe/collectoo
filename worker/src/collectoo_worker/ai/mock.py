"""Deterministic mock provider (no API key in this environment, BRIEF §5).

It implements each prompt's contract with heuristics, so the whole pipeline (and its eval
suite) runs offline and reproducibly. Real providers plug in behind the same gateway.
"""

from __future__ import annotations

import difflib
import re
import unicodedata
from typing import Any

from collectoo_worker.ai.gateway import Prompt

UNMAPPED_BELOW = 0.55
# Words that say little about a column's meaning on their own ("Référence bail" is about the lease).
GENERIC = {"reference", "ref", "numero", "num", "n", "no", "code", "date", "montant"} | {
    "de",
    "du",
    "d",
    "la",
    "le",
    "les",
    "des",
    "l",
    "a",
}


def normalise(label: str) -> str:
    text = unicodedata.normalize("NFKD", label).encode("ascii", "ignore").decode().lower()
    text = re.sub(r"^f\d+_\d+_", "", text)  # eba column prefix
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def _name_score(header: str, aliases: list[str]) -> tuple[float, str]:
    if header in aliases:  # verbatim column name (e.g. an EU-template tape)
        return 1.0, header
    h = normalise(header)
    h_tokens = set(h.split())
    best, best_alias = 0.0, ""
    for alias in aliases:
        a = normalise(alias)
        if not a:
            continue
        if h == a:
            return 0.98, alias
        a_tokens = set(a.split())
        h_content, a_content = h_tokens - GENERIC, a_tokens - GENERIC
        if h_content and h_content == a_content:
            score = 0.9  # same distinctive words
        elif a_tokens and (a_tokens <= h_tokens or h_tokens <= a_tokens):
            score = 0.85 * len(a_tokens & h_tokens) / max(len(a_tokens), len(h_tokens)) + 0.15
        else:
            score = 0.8 * difflib.SequenceMatcher(None, h, a).ratio()
        if score > best:
            best, best_alias = score, alias
    return best, best_alias


# Back-office copy is French (the rationale is shown to ops as is).
TYPE_FR = {
    "date_fr": "date jj/mm/aaaa",
    "date_iso": "date aaaa-mm-jj",
    "date_dotted": "date jj.mm.aaaa",
    "siret": "SIRET",
    "siren": "SIREN",
    "postcode_fr": "code postal",
    "iban": "IBAN",
    "email": "e-mail",
    "phone_fr": "téléphone",
    "integer": "nombre entier",
    "decimal_comma": "nombre décimal",
    "decimal_dot": "nombre décimal",
}


def _score(column: dict[str, Any], target: dict[str, Any]) -> tuple[float, str]:
    name, alias = _name_score(
        column["name"], [*target.get("aliases", []), target["id"].split(".")[-1]]
    )
    guess = column.get("type_guess", "text")
    value_types = target.get("value_types", [])
    why = f"en-tête « {column['name']} » proche de « {alias} »"
    if value_types and guess in value_types:
        name = min(1.0, name + 0.1)
        why += f" ; valeurs de type {TYPE_FR.get(guess, guess)}"
    elif value_types and guess != "text":
        name *= 0.6
        why += f" ; valeurs de type {TYPE_FR.get(guess, guess)}, inhabituel pour cette cible"
    return round(name, 3), why


EBA_COLUMN = re.compile(r"^f\d+_\d+_[a-z0-9_]+$")


def looks_like_eba_tape(columns: list[dict[str, Any]]) -> bool:
    """EU-template targets are only considered for files laid out as EU-template tapes."""
    return sum(1 for c in columns if EBA_COLUMN.match(c["name"])) >= max(1, len(columns) // 3)


def propose_mapping(payload: dict[str, Any]) -> dict[str, Any]:
    columns, targets = payload["columns"], payload["targets"]
    if not looks_like_eba_tape(columns):
        targets = [t for t in targets if not t["id"].startswith("eba.")]
    scored = sorted(
        (
            (s, why, c["name"], t["id"])
            for c in columns
            for t in targets
            for s, why in [_score(c, t)]
        ),
        key=lambda x: (-x[0], x[2], x[3]),
    )
    used_cols: dict[str, tuple[str, float, str]] = {}
    used_targets: set[str] = set()
    for s, why, col, tid in scored:
        if s < UNMAPPED_BELOW:
            break
        if col in used_cols or tid in used_targets:
            continue
        used_cols[col] = (tid, s, why)
        used_targets.add(tid)
    proposals = []
    for c in columns:
        if c["name"] in used_cols:
            tid, s, why = used_cols[c["name"]]
            proposals.append(
                {"source_column": c["name"], "target": tid, "confidence": s, "rationale": why}
            )
        else:
            proposals.append(
                {
                    "source_column": c["name"],
                    "target": None,
                    "confidence": 0.0,
                    "rationale": "aucune cible ne correspond : valeur conservée telle quelle",
                }
            )
    return {"proposals": proposals}


class MockProvider:
    name = "mock"
    model = "heuristics-v1"

    def complete(self, prompt: Prompt, payload: dict[str, Any]) -> dict[str, Any]:
        if prompt.id == "mapping_proposal":
            return propose_mapping(payload)
        raise NotImplementedError(f"mock has no implementation for prompt {prompt.id!r}")
