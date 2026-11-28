"""The prepare job's own mechanics (M2c-7f-2 review round 2, VC-3): the cyclic garbage collector
paused while a draft is loaded, priced and written, the array literals its reads pass, the line kind
read from its text. No database: the job's three steps are stand-ins."""

from __future__ import annotations

import gc
from contextlib import nullcontext
from dataclasses import dataclass
from typing import Any

import pytest

import collectoo_worker.jobs.remittances as job
from collectoo_worker.remittance.commission import LineKind


@dataclass
class _Draft:
    lines: tuple[Any, ...] = ()


class _Conn:
    """What run_prepare touches of a connection: its transaction, and the failure's statement."""

    def __init__(self) -> None:
        self.executed: list[str] = []

    def transaction(self) -> Any:
        return nullcontext()

    def execute(self, query: str, params: Any = None) -> Any:
        self.executed.append(query)
        return self


@pytest.fixture
def collector_on() -> Any:
    was = gc.isenabled()
    gc.enable()
    yield
    if not was:  # pragma: no cover - pytest runs with the collector on
        gc.disable()


def test_the_prepare_loads_prices_and_writes_with_the_cyclic_collector_paused(
    monkeypatch: pytest.MonkeyPatch, collector_on: None
) -> None:
    seen: dict[str, bool] = {}

    def load(conn: Any, run: str, token: str) -> object:
        seen["load"] = gc.isenabled()
        return object()

    def price(facts: object) -> _Draft:
        seen["price"] = gc.isenabled()
        return _Draft()

    def write(conn: Any, run: str, token: str, draft: _Draft) -> bool:
        seen["write"] = gc.isenabled()
        return True

    monkeypatch.setattr(job, "load_facts", load)
    monkeypatch.setattr(job, "prepare_run", price)
    monkeypatch.setattr(job, "write_draft", write)
    assert job.run_prepare(_Conn(), {"run_id": "r", "token": "t"}) == "prepared"  # type: ignore[arg-type]
    assert seen == {"load": False, "price": False, "write": False}
    assert gc.isenabled()  # on again once the job is done


def test_the_collector_runs_again_after_a_prepare_that_fails(
    monkeypatch: pytest.MonkeyPatch, collector_on: None
) -> None:
    def price(facts: object) -> _Draft:
        assert not gc.isenabled()
        raise ValueError("no VAT rate today")

    monkeypatch.setattr(job, "load_facts", lambda conn, run, token: object())
    monkeypatch.setattr(job, "prepare_run", price)
    conn = _Conn()
    assert job.run_prepare(conn, {"run_id": "r", "token": "t"}) == "failed"  # type: ignore[arg-type]
    assert gc.isenabled()
    assert any("remittance_prepare_failed" in q for q in conn.executed)

    def boom(facts: object) -> _Draft:
        raise RuntimeError("not a data error")

    monkeypatch.setattr(job, "prepare_run", boom)
    with pytest.raises(RuntimeError):
        job.run_prepare(_Conn(), {"run_id": "r", "token": "t"})  # type: ignore[arg-type]
    assert gc.isenabled()


def test_a_collector_paused_already_stays_paused(collector_on: None) -> None:
    gc.disable()
    try:
        with job.gc_paused():
            assert not gc.isenabled()
        assert not gc.isenabled()  # the caller's pause is the caller's to end
    finally:
        gc.enable()
    with job.gc_paused():
        assert not gc.isenabled()
    assert gc.isenabled()


def test_the_array_literals() -> None:
    ids = ["0b6f3c2e-8f61-4d7a-9a51-3a2f1d1e0c11", "f0e1d2c3-b4a5-4968-8776-655443322110"]
    assert job._uuids(ids) == "{" + ids[0] + "," + ids[1] + "}"
    assert job._uuids([]) == "{}"
    assert job._uuids(iter(ids)) == job._uuids(ids)  # any iterable, in its order
    assert job._texts(["file", 'a "b", {c}\\d', ""]) == '{"file","a \\"b\\", {c}\\\\d",""}'
    assert job._texts([]) == "{}"


def test_a_line_kind_from_its_text() -> None:
    assert all(job._kind(k.value) is k for k in LineKind)
    with pytest.raises(ValueError, match="not_a_kind"):
        job._kind("not_a_kind")  # as LineKind(value): the prepare records it as a failure
