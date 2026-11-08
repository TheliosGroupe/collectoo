# ADR-0007: Channel adapters with capability descriptors; CPaaS vs direct decided per channel

- Status: Proposed (provider choices to be confirmed by the founder per channel)
- Date: 2026-11-07

## Context
We want every channel that has an API, with no single point of failure, and with platform-policy risk accepted by the founder (`docs/CHANNELS.md`). Prices differ a lot between aggregators and direct providers (FR SMS around €0.045 at Brevo vs around $0.08 at Twilio).

## Decision
- One adapter interface (`send`, `parse_inbound`, `parse_status`, `fetch_proof`, `verify_webhook`) and one versioned **capability descriptor** per (channel, provider). Adding a channel = adapter + descriptor + contract tests + mock.
- **Per-channel sourcing** (from `CHANNELS.md` §7):
  - Direct:
    - email and SMS: Brevo, plus a standby provider
    - WhatsApp: Meta Cloud API
    - Telegram: Bot API
    - Messenger and Instagram: Graph API
    - web push: VAPID
    - letters and LRAR: hybrid-mail API
    - LRE: a qualified provider
  - Aggregator, MSP or CPaaS:
    - RCS, Viber, voice/IVR
    - Apple Messages for Business, where an MSP is mandatory
  - In-house: portal chat (Supabase Realtime).
- **Resilience:** channel health states, provider failover before channel fallback, and per-client sender identities to limit blast radius. Every send, including fallbacks, passes the same guardrail.
- Brevo's policy lists debt collection as high-risk. Before go-live we declare the use case to them in writing, and a standby email/SMS provider is integrated from M4.

## Consequences
- More adapters to maintain than a single CPaaS, but lower unit cost and no lock-in.
- The descriptor drives decisioning, simulation costs and guardrails, so the platform has no channel-specific branches outside adapters.
