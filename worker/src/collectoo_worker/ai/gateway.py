"""Provider-agnostic LLM gateway (M1-07).

Prompts are versioned files in `ai/prompts`. Every call: input hashed, output validated against
the prompt's JSON Schema, and logged in `private.llm_call` (provider, model, prompt version,
input hash, output, latency). Outputs that fail the schema are rejected, never used.
LLMs never compute amounts, dates or legal mentions (BRIEF §5): the mapping prompt only picks
target ids from a closed list.
"""

from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass
from functools import cache
from importlib import resources
from typing import Any, Protocol

import jsonschema
import psycopg
import yaml
from psycopg.types.json import Jsonb


@dataclass(frozen=True)
class Prompt:
    id: str
    version: int
    system: str
    user_template: str
    output_schema: dict[str, Any]


@cache
def load_prompt(prompt_id: str, version: int = 1) -> Prompt:
    name = f"{prompt_id}.v{version}.yaml"
    raw = yaml.safe_load(resources.files("collectoo_worker.ai.prompts").joinpath(name).read_text())
    return Prompt(
        id=raw["id"],
        version=int(raw["version"]),
        system=raw["system"],
        user_template=raw["user_template"],
        output_schema=raw["output_schema"],
    )


class Provider(Protocol):
    name: str
    model: str

    def complete(self, prompt: Prompt, payload: dict[str, Any]) -> dict[str, Any]: ...


class InvalidOutputError(ValueError):
    """The provider's output does not match the prompt's output schema."""


def canonical_json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


@dataclass
class Gateway:
    provider: Provider
    conn: psycopg.Connection[Any] | None = None

    def run(
        self,
        prompt_id: str,
        payload: dict[str, Any],
        *,
        version: int = 1,
        batch_id: str | None = None,
    ) -> dict[str, Any]:
        prompt = load_prompt(prompt_id, version)
        input_hash = hashlib.sha256(canonical_json(payload).encode()).hexdigest()
        started = time.monotonic()
        output: dict[str, Any] | None = None
        status, error = "ok", None
        try:
            output = self.provider.complete(prompt, payload)
            jsonschema.validate(output, prompt.output_schema)
        except jsonschema.ValidationError as exc:
            status, error = "invalid_output", exc.message
        except Exception as exc:  # provider failure: logged, then re-raised
            status, error = "error", f"{type(exc).__name__}: {exc}"
        latency_ms = int((time.monotonic() - started) * 1000)
        self._log(
            prompt,
            input_hash=input_hash,
            output=output,
            status=status,
            error=error,
            latency_ms=latency_ms,
            batch_id=batch_id,
        )
        if status == "invalid_output":
            raise InvalidOutputError(error)
        if status == "error":
            raise RuntimeError(error)
        assert output is not None  # noqa: S101 - narrowed by status
        return output

    def _log(  # noqa: PLR0913 - one row of the call log
        self,
        prompt: Prompt,
        *,
        input_hash: str,
        output: dict[str, Any] | None,
        status: str,
        error: str | None,
        latency_ms: int,
        batch_id: str | None,
    ) -> None:
        if self.conn is None:
            return
        self.conn.execute(
            """insert into private.llm_call
                 (prompt_id, prompt_version, provider, model, input_sha256,
                  output, status, error, latency_ms, batch_id)
               values (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
            (
                prompt.id, prompt.version, self.provider.name, self.provider.model, input_hash,
                Jsonb(output) if output is not None else None, status, error, latency_ms, batch_id,
            ),
        )  # fmt: skip
