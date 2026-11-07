# ADR-0001: Record architecture decisions

- Status: Accepted
- Date: 2026-11-07

## Context
Collectoo is built by a small team steering an AI engineer across sessions that expire. Decisions must survive the sessions and be reviewable from a phone.

## Decision
Record each significant decision as a short ADR in `docs/adr/NNNN-title.md` (Michael Nygard format: Context, Decision, Consequences). ADRs are immutable once accepted; a change of mind is a new ADR that supersedes the old one. Diagrams are Mermaid.

## Consequences
- Every PR that changes a recorded decision adds or supersedes an ADR.
- `docs/ARCHITECTURE.md` describes the current system and links to the ADRs; it does not repeat their reasoning.
