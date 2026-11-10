"""M2c-2 (M2-13 data, design §8.1, §8.2, §8.5): the money terms of a mandate version, without the
database — the design's examples are valid, each rule refuses what it should, the committed JSON
Schemas are the models', and the generated corpus of the parity test holds both verdicts."""

import copy
from typing import Any

import pytest
from terms_cases import schedules, terms

from collectoo_worker.remittance.terms import (
    SCHEMAS,
    commission_schedule_error,
    commission_schedule_valid,
    json_schemas,
    legacy_schedule,
    remittance_terms_error,
    remittance_terms_valid,
)
from collectoo_worker.synth.seed import REMITTANCE, SCHEDULES

# §8.1's example (the clause reference is the version's commission_clause_ref column)
LILAS: dict[str, Any] = {
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
            "id": "b2b",
            "tier_key": "b2b",
            "label_fr": "Factures entre professionnels",
            "match": {"claim_types": ["b2b_invoice"]},
            "rate": {"kind": "flat", "rate": "0.1500"},
        },
        {
            "id": "autres",
            "tier_key": "autres",
            "label_fr": "Autres créances",
            "match": {},
            "rate": {
                "kind": "marginal",
                "tiers": [
                    {"up_to_minor": "500000", "rate": "0.1000"},
                    {"up_to_minor": None, "rate": "0.0600"},
                ],
            },
            "min_per_file_minor": "3000",
        },
    ],
}
# §8.2's example
TERMS: dict[str, Any] = {
    "schema": "remittance-1",
    "frequency": "twice_monthly",
    "netting": {"clause_ref": "art. 7.2"},
    "clawback": {"clause_ref": "art. 7.4"},
    "invoice_payment_days": 30,
    "holdback": [],
}


def with_(doc: dict[str, Any], path: tuple[Any, ...], value: Any) -> dict[str, Any]:
    out = copy.deepcopy(doc)
    node: Any = out
    for key in path[:-1]:
        node = node[key]
    if value is DELETE:
        del node[path[-1]]
    else:
        node[path[-1]] = value
    return out


DELETE = object()


def test_the_design_examples_and_the_seed_are_valid() -> None:
    assert commission_schedule_error(LILAS) is None
    assert remittance_terms_error(TERMS) is None
    bracket = with_(
        LILAS,
        ("rules", 0, "rate"),
        {
            "kind": "bracket",
            "attribute": "age_days_at_boarding",
            "brackets": [{"up_to": "365", "rate": "0.12"}, {"up_to": None, "rate": "0.2"}],
        },
    )
    assert commission_schedule_valid(bracket)
    weekly = TERMS | {"frequency": "weekly", "weekday": 2, "netting": None, "clawback": None}
    assert remittance_terms_valid(weekly)
    assert all(commission_schedule_valid(s) for s in SCHEDULES.values())
    assert all(remittance_terms_valid(t) for t in REMITTANCE.values())
    assert commission_schedule_valid(legacy_schedule("0.15"))


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("clause_ref",), "art. 6"),  # the clause reference is a column of the version
        (("schema",), "commission-2"),
        (("basis", "families"), []),
        (("basis", "families"), ["principal", "principal"]),
        (("basis", "families"), ["fees"]),
        (("basis", "forwards", "file_recalled"), 0),
        (("basis", "forwards", "client_ratification"), DELETE),
        (("basis", "on_reversal"), "refund"),
        (("rules",), []),
        (("rules", 0, "id"), "B2B"),
        (("rules", 1, "id"), "b2b"),  # ids repeat
        (("rules", 1, "tier_key"), "b2b"),  # tier keys repeat
        (("rules", 0, "label_fr"), " \t "),
        (("rules", 0, "label_fr"), "x" * 201),
        (("rules", 0, "match", "claim_types"), None),
        (("rules", 0, "match", "claim_types"), []),
        (("rules", 0, "match", "portfolio_ids"), ["not-a-uuid"]),
        (("rules", 0, "match", "debtors"), ["x"]),
        (("rules", 1, "match"), {"families": ["principal"]}),  # the last rule must match everything
        (("rules", 0, "rate", "rate"), "1.5"),
        (("rules", 0, "rate", "rate"), "0.12345"),
        (("rules", 0, "rate", "rate"), 0.15),  # a number, not a string: no float anywhere
        (("rules", 0, "rate", "kind"), "whole_tiers"),  # whole-rate tiers are refused (§8.1)
        (("rules", 1, "rate", "tiers", 0, "up_to_minor"), None),  # only the last tier is unbounded
        (("rules", 1, "rate", "tiers", 1, "up_to_minor"), "900000"),  # the last one is unbounded
        (("rules", 1, "rate", "tiers", 0, "up_to_minor"), "0"),
        (("rules", 1, "rate", "tiers", 0, "up_to_minor"), 500000),
        (("rules", 1, "min_per_file_minor"), "-3000"),
        (("rules", 1, "min_per_file_minor"), None),
    ],
)
def test_a_schedule_is_refused(path: tuple[Any, ...], value: Any) -> None:
    assert commission_schedule_error(with_(LILAS, path, value)) is not None


def test_tiers_ascend() -> None:
    tiers: list[dict[str, str | None]] = [
        {"up_to_minor": "500000", "rate": "0.10"},
        {"up_to_minor": "200000", "rate": "0.08"},
        {"up_to_minor": None, "rate": "0.06"},
    ]
    assert not commission_schedule_valid(with_(LILAS, ("rules", 1, "rate", "tiers"), tiers))
    tiers[1]["up_to_minor"] = "900000"
    assert commission_schedule_valid(with_(LILAS, ("rules", 1, "rate", "tiers"), tiers))


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("clause_ref",), "art. 7"),
        (("schema",), "remittance-2"),
        (("frequency",), "monthly"),  # not offered (design §9.3)
        (("weekday",), 2),  # only with a weekly frequency
        (("netting",), {}),
        (("netting",), {"clause_ref": ""}),
        (("netting",), DELETE),  # required, null when there is none
        (("clawback",), {"clause_ref": "art. 7.4", "days": 30}),
        (("invoice_payment_days",), 46),  # L441-10 I: ≤ 45 days after issue
        (("invoice_payment_days",), 30.0),
        (("invoice_payment_days",), True),
        (("holdback",), [{"kind": "card", "days": 60}]),  # reserved for M5
        (("holdback",), None),
    ],
)
def test_remittance_terms_are_refused(path: tuple[Any, ...], value: Any) -> None:
    assert remittance_terms_error(with_(TERMS, path, value)) is not None


def test_a_weekly_frequency_names_a_business_weekday() -> None:
    weekly = TERMS | {"frequency": "weekly"}
    assert not remittance_terms_valid(weekly)
    for day, ok in ((0, False), (1, True), (5, True), (6, False), (True, False), ("2", False)):
        assert remittance_terms_valid(weekly | {"weekday": day}) is ok


def test_the_committed_json_schemas_are_the_models() -> None:
    for name, text in json_schemas().items():
        assert (SCHEMAS / name).read_text(encoding="utf-8") == text, (
            f"regenerate: uv run python -m collectoo_worker.remittance.terms ({name})"
        )


def test_the_parity_corpus_holds_both_verdicts_and_is_deterministic() -> None:
    s, t = schedules(2_000, seed=3), terms(2_000, seed=3)
    assert s == schedules(2_000, seed=3)
    for docs, valid in ((s, commission_schedule_valid), (t, remittance_terms_valid)):
        n = sum(valid(d) for d in docs)
        assert 400 < n < 1_600
