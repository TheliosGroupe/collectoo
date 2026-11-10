"""Generated money-terms documents for the validator parity test (design §8.5): valid
`commission-1` schedules and `remittance-1` terms, and mutations of them (unknown and missing keys,
wrong JSON types, nulls, boundary rates and amounts, tiers out of order, rules that repeat or leave
the last one non catch-all, weekdays and payment days out of range…). Deterministic per seed."""

from __future__ import annotations

import copy
import random
import uuid
from collections.abc import Callable
from typing import Any

FAMILIES = ["principal", "interest", "indemnity", "charge", "cost", "unclassified"]
CLAIM_TYPES = [
    "b2b_invoice",
    "b2c_invoice",
    "rent",
    "professional_loan",
    "judgment_debt",
    "overdraft",
]
LABELS = [
    "Factures entre professionnels",
    "Autres créances",
    "Loyers et charges — échus",
    "Prêts professionnels (intérêts compris)",
    "Créances < 5 000 €",
    "Œuvres & cie",
]
WEIRD: list[Any] = [None, 0, 1, -1, 1.5, 30.0, True, False, "", " ", "x", [], {}, [1], {"a": 1}]
BAD_RATES: list[Any] = [
    "1.5",
    "0.12345",
    "-0.1",
    ".5",
    "0.1 ",
    "01",
    "1.0001",
    "2",
    "0,15",
    0.15,
    1,
    None,
]
BAD_MINOR: list[Any] = ["007", "-1", "1e3", "1234567890123456", "", " 1", 10, 1.0, None, "0x10"]
BAD_IDS: list[Any] = ["A", "", "a" * 41, "é", "-a", "a b", 1, None, "_x"]
BAD_TEXT: list[Any] = ["", "   ", "\t\n", "x" * 201, 1, None, ["x"]]


def rate(rng: random.Random) -> str:
    return rng.choice(
        [
            "0",
            "1",
            "1.0",
            "1.0000",
            f"0.{rng.randint(0, 9)}",
            f"0.{rng.randint(0, 99):02d}",
            f"0.{rng.randint(0, 9999):04d}",
            f"0.{rng.randint(0, 999):03d}",
        ]
    )


def minor(rng: random.Random, low: int = 0) -> str:
    return str(rng.randint(low, rng.choice([10**3, 10**6, 10**9, 10**15 - 1])))


def _bands(rng: random.Random, key: str) -> list[dict[str, Any]]:
    n = rng.randint(1, 4)
    bounds = sorted(rng.sample(range(1, 10**7), n - 1))
    out: list[dict[str, Any]] = [{key: str(b), "rate": rate(rng)} for b in bounds]
    return [*out, {key: None, "rate": rate(rng)}]


def _rate_doc(rng: random.Random) -> dict[str, Any]:
    kind = rng.choice(["flat", "flat", "marginal", "bracket"])
    if kind == "flat":
        return {"kind": "flat", "rate": rate(rng)}
    if kind == "marginal":
        return {"kind": "marginal", "tiers": _bands(rng, "up_to_minor")}
    return {
        "kind": "bracket",
        "attribute": rng.choice(["boarded_amount", "age_days_at_boarding"]),
        "brackets": _bands(rng, "up_to"),
    }


def _match(rng: random.Random) -> dict[str, Any]:
    out: dict[str, Any] = {}
    if rng.random() < 0.5:
        out["claim_types"] = rng.sample(CLAIM_TYPES, rng.randint(1, 3))
    if rng.random() < 0.4:
        out["families"] = rng.sample(FAMILIES, rng.randint(1, 3))
    if rng.random() < 0.2:
        out["portfolio_ids"] = [
            str(uuid.UUID(int=rng.getrandbits(128))) for _ in range(rng.randint(1, 3))
        ]
    return out


def valid_schedule(rng: random.Random) -> dict[str, Any]:
    n = rng.randint(1, 5)
    rules = []
    for i in range(n):
        rule: dict[str, Any] = {
            "id": f"r{i}-{rng.randint(0, 999)}",
            "tier_key": f"t{i}_{rng.choice(['b2b', 'autres', 'x'])}",
            "label_fr": rng.choice(LABELS),
            "match": _match(rng) if i < n - 1 else {},
            "rate": _rate_doc(rng),
        }
        if rng.random() < 0.3:
            rule["min_per_file_minor"] = minor(rng)
        rules.append(rule)
    return {
        "schema": "commission-1",
        "basis": {
            "families": "all" if rng.random() < 0.6 else rng.sample(FAMILIES, rng.randint(1, 6)),
            "forwards": {
                "file_recalled": rng.random() < 0.3,
                "before_servicing_start": rng.random() < 0.3,
                "client_ratification": rng.random() < 0.3,
            },
            "on_reversal": rng.choice(["credit", "credit", "keep"]),
        },
        "rules": rules,
    }


def valid_terms(rng: random.Random) -> dict[str, Any]:
    weekly = rng.random() < 0.3
    doc: dict[str, Any] = {
        "schema": "remittance-1",
        "frequency": "weekly" if weekly else "twice_monthly",
        "netting": {"clause_ref": rng.choice(["art. 7.2", "Art. 6.3 — compensation"])}
        if rng.random() < 0.7
        else None,
        "clawback": {"clause_ref": "art. 7.4"} if rng.random() < 0.5 else None,
        "invoice_payment_days": rng.randint(0, 45),
    }
    if weekly:
        doc["weekday"] = rng.randint(1, 5)
    if rng.random() < 0.3:
        doc["holdback"] = []
    return doc


# -- mutations ---------------------------------------------------------------------------------


def _pick(rng: random.Random, pool: list[Any]) -> Any:
    """A fresh copy (the pools hold lists and dicts: a shared one would end up inside itself)."""
    return copy.deepcopy(rng.choice(pool))


def _nodes(doc: Any, path: tuple[Any, ...] = ()) -> list[tuple[tuple[Any, ...], Any]]:
    out = [(path, doc)]
    if isinstance(doc, dict):
        for k, v in doc.items():
            out += _nodes(v, (*path, k))
    elif isinstance(doc, list):
        for i, v in enumerate(doc):
            out += _nodes(v, (*path, i))
    return out


def _set(doc: Any, path: tuple[Any, ...], value: Any) -> Any:
    if not path:
        return value
    parent = doc
    for key in path[:-1]:
        parent = parent[key]
    parent[path[-1]] = value
    return doc


def _generic(rng: random.Random, doc: Any) -> Any:
    nodes = _nodes(doc)
    path, node = rng.choice(nodes)
    choice = rng.random()
    if isinstance(node, dict) and choice < 0.35:
        if node and rng.random() < 0.6:
            del node[rng.choice(list(node))]
        else:
            node[rng.choice(["extra", "Schema", "rate", "id", "kind"])] = _pick(rng, WEIRD)
        return doc
    if isinstance(node, list) and choice < 0.35:
        if node and rng.random() < 0.5:
            node.pop(rng.randrange(len(node)))
        elif node:
            node.append(copy.deepcopy(rng.choice(node)))
        else:
            node.append(_pick(rng, WEIRD))
        return doc
    return _set(doc, path, _pick(rng, WEIRD))


def _bad_string(rng: random.Random, doc: Any) -> Any:
    """A string leaf replaced by a near miss of its kind."""
    leaves = [(p, v) for p, v in _nodes(doc) if p and isinstance(v, str)]
    if not leaves:
        return doc
    path, _value = rng.choice(leaves)
    key = path[-1]
    pool = (
        BAD_RATES
        if key == "rate"
        else BAD_MINOR
        if key in ("up_to_minor", "up_to", "min_per_file_minor")
        else BAD_IDS
        if key in ("id", "tier_key")
        else BAD_TEXT
        if key in ("label_fr", "clause_ref")
        else [*WEIRD, "commission-2", "remittance-0", "monthly", "flat ", "Flat"]
    )
    return _set(doc, path, _pick(rng, pool))


def _bands_out_of_order(rng: random.Random, doc: Any) -> Any:
    rules = doc.get("rules") if isinstance(doc, dict) else None
    for rule in rules if isinstance(rules, list) else []:
        r = rule.get("rate") if isinstance(rule, dict) else None
        if not isinstance(r, dict):
            continue
        for key, bound in (("tiers", "up_to_minor"), ("brackets", "up_to")):
            bands = r.get(key)
            if isinstance(bands, list) and bands and all(isinstance(b, dict) for b in bands):
                op = rng.choice(["swap", "middle_null", "last_bound", "zero", "repeat"])
                if op == "swap" and len(bands) > 2:
                    bands[0], bands[1] = bands[1], bands[0]
                elif op == "middle_null" and len(bands) > 1:
                    bands[0][bound] = None
                elif op == "last_bound":
                    bands[-1][bound] = "99999999"
                elif op == "zero":
                    bands[0][bound] = "0"
                elif op == "repeat" and len(bands) > 2:
                    bands[1][bound] = bands[0][bound]
                return doc
    return doc


def _rules(rng: random.Random, doc: Any) -> Any:
    rules = doc.get("rules") if isinstance(doc, dict) else None
    if not isinstance(rules, list) or not rules or not all(isinstance(r, dict) for r in rules):
        return doc
    op = rng.choice(["dup_id", "dup_tier", "last_match", "empty", "many"])
    if op == "dup_id" and len(rules) > 1:
        rules[-1]["id"] = rules[0]["id"]
    elif op == "dup_tier" and len(rules) > 1:
        rules[0]["tier_key"] = rules[-1]["tier_key"]
    elif op == "last_match":
        rules[-1]["match"] = {"claim_types": ["rent"]}
    elif op == "empty":
        doc["rules"] = []
    elif op == "many":
        template = rules[-1]
        doc["rules"] = [
            {**copy.deepcopy(template), "id": f"m{i}", "tier_key": f"k{i}"} for i in range(51)
        ]
    return doc


def _terms(rng: random.Random, doc: Any) -> Any:
    if not isinstance(doc, dict):
        return doc
    op = rng.choice(["weekday", "days", "holdback", "netting"])
    if op == "weekday":
        if doc.get("frequency") == "weekly":
            if rng.random() < 0.4:
                doc.pop("weekday", None)
            else:
                doc["weekday"] = rng.choice([0, 6, 7, "2", 2.0, True, None, -1, 3])
        else:
            doc["weekday"] = rng.choice([1, 3, None])
    elif op == "days":
        doc["invoice_payment_days"] = rng.choice([46, -1, 30.0, "30", True, 45, 0, 60, None])
    elif op == "holdback":
        doc["holdback"] = rng.choice([[1], {}, None, [], [{"kind": "card"}], "none"])
    else:
        doc[rng.choice(["netting", "clawback"])] = rng.choice(
            [
                {},
                {"clause_ref": ""},
                {"clause_ref": 1},
                {"clause_ref": "x", "other": 1},
                "art. 7",
                [],
                None,
            ]
        )
    return doc


def _families(rng: random.Random, doc: Any) -> Any:
    basis = doc.get("basis") if isinstance(doc, dict) else None
    if isinstance(basis, dict):
        basis["families"] = rng.choice(
            [
                [],
                ["principal", "principal"],
                ["fees"],
                "All",
                "principal",
                [*FAMILIES, "x"],
                list(FAMILIES),
            ]
        )
    return doc


SCHEDULE_MUTATIONS: list[Callable[[random.Random, Any], Any]] = [
    _generic,
    _bad_string,
    _bad_string,
    _bands_out_of_order,
    _rules,
    _families,
]
TERMS_MUTATIONS: list[Callable[[random.Random, Any], Any]] = [_generic, _bad_string, _terms, _terms]


def schedules(n: int, seed: int = 1) -> list[Any]:
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        doc: Any = valid_schedule(rng)
        if rng.random() < 0.6:
            for _ in range(rng.choice([1, 1, 2])):
                doc = rng.choice(SCHEDULE_MUTATIONS)(rng, doc)
        out.append(doc)
    return out


def terms(n: int, seed: int = 1) -> list[Any]:
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        doc: Any = valid_terms(rng)
        if rng.random() < 0.6:
            for _ in range(rng.choice([1, 1, 2])):
                doc = rng.choice(TERMS_MUTATIONS)(rng, doc)
        out.append(doc)
    return out
