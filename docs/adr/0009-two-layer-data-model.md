# ADR-0009: Two-layer data model (EU NPL template layer + operational layer)

- Status: Accepted
- Date: 2026-11-07

## Context
The EU NPL data template (Implementing Regulation (EU) 2023/2083, 135 fields; see `docs/reference/eba_field_catalogue.csv`) is a sale-time snapshot for bank portfolios. Servicing needs much more: events after cut-off, rule packs, contacts with consent, communications, plans, holds, mandates, ownership history. Civil and commercial claims don't fit the bank template at all.

## Decision
- **Layer 1 (`eba` schema, not exposed):** staging tables mirroring templates T1–T5, typed from the generated catalogue/JSON Schema. Used when a bank tape is boarded, and to **export** a compliant tape at any date via views over Layer 2 plus the mapping.
- **Layer 2 (`public`/`private`):** the canonical operational model, a superset of the template (`docs/DOMAIN.md`, gap analysis in `docs/reference/eba_gap_analysis.md`). The platform runs only on Layer 2.
- Mappings in both directions are versioned data (template → operational on boarding, operational → template on export). Non-bank claims board through the generic mapper straight into Layer 2.
- Phase C needs are modelled now: claim ownership history, servicer ≠ owner, mandates, fund organisations.

## Consequences
- Bank tapes keep their exact template meaning (field ids preserved), and exports are reproducible.
- Some duplication between layers, limited to boarding and export.
