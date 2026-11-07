# ADR-0005: Rule packs as versioned data

- Status: Accepted
- Date: 2026-11-07

## Context
Interest, fees, caps, start events, capitalisation, prescription and allocation differ by claim type and legal regime, and change with the law (e.g. CCD2 from 20 Nov 2026, L441-10 versions). Code branches per claim type would be hard to audit and to date.

## Decision
- A **rule pack** is a YAML document (`worker/rule_packs/<id>/<effective_from>.yaml`) with effective dates, components, interest bases, start events, day count, capitalisation, caps, allowed fees, limitation periods, allocation order and **legal references for every component** (schema sketch in `docs/CALCULATION_RULES.md` §5).
- Packs are validated at load against a JSON Schema plus semantic rules. Examples: no capitalisation for consumer regimes; whitelisted components for consumer credit; no debtor-chargeable recovery fee without an enforceable title; non-overlapping version dates.
- Packs are loaded into `private.rule_pack_version` with a content hash. Every ledger entry posted by the engine records the pack version.
- One engine interprets all packs. Adding a claim type means adding a pack plus golden tests; the engine changes only when a new kind of rule appears.

## Consequences
- Rules are reviewable by the founder and counsel without reading Python.
- The engine needs a small, well-tested vocabulary of rule kinds. Unusual contracts may need a new kind (a code change with tests), never an ad-hoc branch.
