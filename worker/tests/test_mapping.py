"""M1-06 target registry, M1-07 gateway, M1-08 proposals (unit level, mock provider)."""

import json
from pathlib import Path
from typing import Any

import pytest

from collectoo_worker.ai.gateway import Gateway, InvalidOutputError, Prompt
from collectoo_worker.ai.mock import MockProvider
from collectoo_worker.boarding.mapping import Proposal, header_signature, join_keys, propose
from collectoo_worker.boarding.profile import profile_frame
from collectoo_worker.boarding.readers import scan_csv
from collectoo_worker.boarding.targets import export_json, registry
from collectoo_worker.synth.civil import DIALECTS, KINDS, write_civil
from collectoo_worker.synth.eba import generate_eba, write_tape


class FakeConn:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple[Any, ...]]] = []

    def execute(self, sql: str, params: tuple[Any, ...]) -> None:
        self.calls.append((sql, params))


class FixedProvider:
    name = "fixed"
    model = "test"

    def __init__(self, output: dict[str, Any]) -> None:
        self.output = output

    def complete(self, prompt: Prompt, payload: dict[str, Any]) -> dict[str, Any]:
        return self.output


def _profile(columns: dict[str, list[str]]) -> dict[str, Any]:
    import polars as pl  # noqa: PLC0415

    return profile_frame(pl.DataFrame(columns).lazy())


def test_registry_targets_are_described_and_typed() -> None:
    targets = registry()
    ids = [t.id for t in targets]
    assert len(ids) == len(set(ids))
    assert all(t.type and t.description for t in targets)
    assert sum(1 for i in ids if i.startswith("eba.")) == 135
    assert len(json.loads(export_json())) == len(targets)


def test_gateway_rejects_and_logs_invalid_outputs() -> None:
    conn = FakeConn()
    bad = FixedProvider({"proposals": [{"source_column": "x", "target": "y"}]})  # missing fields
    with pytest.raises(InvalidOutputError):
        Gateway(bad, conn).run("mapping_proposal", {"columns": [], "targets": []})  # type: ignore[arg-type]
    sql, params = conn.calls[-1]
    assert "private.llm_call" in sql
    assert params[0:4] == ("mapping_proposal", 1, "fixed", "test")
    assert params[6] == "invalid_output"


def test_gateway_logs_every_call_with_input_hash() -> None:
    conn = FakeConn()
    gw = Gateway(MockProvider(), conn)  # type: ignore[arg-type]
    payload: dict[str, Any] = {"columns": [], "targets": []}
    gw.run("mapping_proposal", payload)
    gw.run("mapping_proposal", payload)
    hashes = {c[1][4] for c in conn.calls}
    assert len(conn.calls) == 2 and len(hashes) == 1  # same input, same hash
    assert {c[1][6] for c in conn.calls} == {"ok"}


def test_unknown_target_ids_from_a_model_are_dropped() -> None:
    made_up = {"source_column": "Montant", "target": "invented.field", "confidence": 0.99}
    out = {"proposals": [{**made_up, "rationale": "made up"}]}
    proposals = propose(Gateway(FixedProvider(out)), _profile({"Montant": ["12,50"]}))
    assert proposals[0].target is None and proposals[0].confidence == 0.0


def test_mock_is_deterministic_and_flags_weak_matches() -> None:
    profile = _profile(
        {
            "Échéance": ["05/03/2026", "06/04/2026"],
            "Commercial": ["J. Morel", "A. Petit"],
            "Mt TTC": ["12,50", "40,00"],  # abbreviation: weak match
        }
    )
    first = propose(Gateway(MockProvider()), profile)
    assert first == propose(Gateway(MockProvider()), profile)
    by_col = {p.source_column: p for p in first}
    assert by_col["Échéance"].target == "claim_item.due_date"
    assert not by_col["Échéance"].needs_review
    assert by_col["Commercial"].target is None
    assert by_col["Mt TTC"].target == "claim_item.amount"
    assert by_col["Mt TTC"].needs_review


@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("dialect", DIALECTS)
def test_every_column_of_the_synthetic_files_gets_a_proposal(
    tmp_path: Path, kind: str, dialect: str
) -> None:
    path = write_civil(kind, dialect, 80, 5, tmp_path)  # type: ignore[arg-type]
    profile = profile_frame(scan_csv(path)[0])
    proposals = propose(Gateway(MockProvider()), profile)
    assert {p.source_column for p in proposals} == {c["name"] for c in profile["columns"]}
    assert all(p.target for p in proposals)
    targets = [p.target for p in proposals]
    assert len(targets) == len(set(targets))  # one column per target


def test_eba_tape_columns_map_to_their_template_fields(tmp_path: Path) -> None:
    write_tape(generate_eba(30, 2), tmp_path)
    profile = profile_frame(scan_csv(tmp_path / "t3_loan.csv")[0])
    proposals = propose(Gateway(MockProvider()), profile)
    assert all(p.target == f"eba.{p.source_column}" for p in proposals)


def test_join_keys_link_files_mapping_the_same_key() -> None:
    files = {
        "debtors": [Proposal("Code client", "account.external_ref", 0.9, "", False, "mock")],
        "invoices": [Proposal("Compte", "account.external_ref", 0.8, "", False, "mock")],
    }
    assert join_keys(files) == [
        {
            "target": "account.external_ref",
            "columns": {"debtors": "Code client", "invoices": "Compte"},
        }
    ]


def test_header_signature_is_order_independent() -> None:
    assert header_signature(["b", "Échéance", "a"]) == header_signature(["a", "b", "Échéance"])
    assert len(header_signature(["a"])) == 64


def test_ui_target_list_is_up_to_date() -> None:
    """The back-office review offers exactly the registry's targets. Regenerate with:
    uv run python -m collectoo_worker.boarding.targets > ../apps/web/src/lib/boarding/targets.json
    """
    from pathlib import Path  # noqa: PLC0415

    from collectoo_worker.boarding.targets import export_ui_json  # noqa: PLC0415

    ui = Path(__file__).parents[2] / "apps/web/src/lib/boarding/targets.json"
    assert ui.read_text(encoding="utf-8") == export_ui_json()
