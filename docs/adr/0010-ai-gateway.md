# ADR-0010: Provider-agnostic AI gateway with mocks and eval suites

- Status: Accepted
- Date: 2026-11-07

## Context
LLMs are used for tape mapping, document extraction, inbound triage, the portal assistant, copy variants and a collector copilot. No real API key is available yet. LLMs must never be the source of amounts, dates or legal text (BRIEF §2, §5).

## Decision
- One gateway in the worker: `complete(task, prompt_version, input, output_schema)`. Providers are pluggable: a **mock provider** (deterministic, fixture-driven) by default, real providers added when a key is supplied.
- Prompts are versioned files. Outputs are **schema-validated** (Pydantic), with one retry, then failure. A confidence threshold per task routes low-confidence results to human review.
- Every call is logged in `private.ai_call_log`: task, prompt version, provider/model, masked input hash, output, latency, cost.
- Inputs are minimised (masked PII, sampled values). A non-EU provider needs a recorded GDPR chapter V transfer basis.
- **Eval suites** in `worker/evals/` (golden datasets for mapping and triage) run in CI against the mock and nightly against a real model once a key exists.
- AI decision nodes choose only from a pre-approved set of non-significant actions (GDPR art. 22).

## Consequences
- Features are buildable and testable now. Real quality is measured once keys exist.
- Switching provider is a configuration change, checked by the eval suite.
