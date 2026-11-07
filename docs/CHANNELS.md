# Channels

Status: Phase 0 draft, 2026-11-07. Implements brief §3.6.
Prices and platform policies change often. Every figure below has a source and a retrieval date; re-check before signing a provider.
**Platform policies are information only** (brief §3.6). They are a business risk the founder accepts, not a blocker. Legal rules are in `docs/COMPLIANCE.md`, not here.

> Note: this session's network allowlist blocks most provider sites, so policies were checked through web search results (third-party copies included). Items marked *(verify)* need a direct read of the official page.

## 1. Catalogue

| # | Channel | Direction | Business can start? | Notes |
|---|---|---|---|---|
| 1 | Email | out + in | Yes | Transactional ESP. No open-tracking pixels by default (consent required, see COMPLIANCE). |
| 2 | SMS | out + in | Yes | Alphanumeric sender for out; a virtual number is needed to receive replies. |
| 3 | RCS (RBM) | out + in | Yes | Verified sender, rich cards, buttons. Aggregators fall back to SMS when the handset isn't RCS-capable. |
| 4 | WhatsApp (Cloud API) | out + in | Yes, templates only | Pre-approved templates outside the 24 h customer service window. |
| 5 | Telegram (Bot API) | out + in | **No** | Debtor must start the bot first (portal deep link `t.me/<bot>?start=<token>`). |
| 6 | Facebook Messenger | out + in | **No** (user-initiated) | 24 h window; message tags / one-time notification outside it. |
| 7 | Instagram messaging | out + in | **No** (user-initiated) | Same Meta platform rules as Messenger. |
| 8 | Apple Messages for Business | in (+ reply) | **No** | Customer-initiated only; needs an Apple-approved messaging service provider and live agents. |
| 9 | Viber Business Messages | out + in | Yes | Per-message fee plus monthly minimum commitment. |
| 10 | Voice: outbound agent call | out + in | Yes | Click-to-call from the collector workspace; call recording is a separate GDPR question. |
| 11 | Voice: IVR / voicebot | out + in | Yes | Automated payment line, promise-to-pay capture; voicebot never states amounts on its own (brief §5). |
| 12 | Push (web push, PWA) | out | Yes, after opt-in | Browser permission on the debtor portal. Native app push later if there is an app. |
| 13 | Portal web chat | in + out | No (debtor in session) | In-house, Supabase Realtime. AI assistant + human handover. |
| 14 | Simple postal letter (hybrid) | out | Yes | PDF → print/mail provider API. |
| 15 | Registered letter, LRAR (hybrid) | out | Yes | Proof of sending and receipt (AR). Fallback for LRE without consent. |
| 16 | Qualified LRE (eIDAS) | out | Yes, **consent needed for non-professionals** | CPCE art. L100. Legal-grade proof. |

Considered and excluded:
- Google Business Messages: shut down by Google in 2024.
- Signal: no official business API.
- Snapchat and LINE: no business messaging API relevant in France.

## 2. Capability matrix

Legend: ✅ yes · ❌ no · ◐ partial. Cost = indicative unit price in France, excl. VAT, retrieved 2026-11-07.

| Channel | Opt-in needed (technical/platform) | Templates / window | Rich content + pay link | Delivery receipt | Read receipt | Inbound | Indicative unit cost | Candidate providers (EU/FR first) | Provider sandbox |
|---|---|---|---|---|---|---|---|---|---|
| Email | ❌ | ❌ | ✅ HTML + link | ◐ (accepted/bounce) | ❌ (no pixels) | ✅ (inbound parse) | < €0.001 (plan-based) *(verify)* | Brevo (FR) [chosen], Scaleway TEM (FR), AWS SES eu-west-3 | Mock adapter; provider test modes vary |
| SMS | ❌ | ❌ | ◐ link only, 160 chars/segment | ✅ DLR | ❌ | ✅ with virtual number | Brevo ≈ €0.045 [1]; Octopush €0.034–0.049, SMSFactor €0.04–0.066, Allmysms €0.045 [2]; Twilio $0.0798 [3] | Brevo [chosen], Octopush, SMSFactor, Allmysms (FR) | Mock adapter |
| RCS | ❌ (agent must be verified/launched with carriers) | ❌ | ✅ cards, buttons, links | ✅ | ✅ | ✅ | Not published for FR; quote needed. ~84% of FR smartphones RCS-capable [4] | Digital Virgo (FR), Infobip, Sinch, Twilio (Orange partnership) [5] | Google RBM test agent; mock |
| WhatsApp | ◐ (platform expects opt-in for business-initiated) | ✅ templates outside 24 h window | ✅ buttons, links | ✅ | ✅ | ✅ | Utility ≈ €0.0248, marketing ≈ €0.0712 per message (per-message pricing since 1 Jul 2025) [6] *(verify on Meta rate card)* | Meta Cloud API direct; BSPs (Infobip, Sinch, Brevo) | Cloud API test number; mock |
| Telegram | ✅ user must /start the bot | ❌ | ✅ buttons, links | ❌ | ❌ | ✅ | Free | Bot API direct | Telegram test environment; mock |
| Messenger | ✅ user-initiated | ✅ 24 h window + tags | ✅ | ✅ | ✅ | ✅ | No per-message fee for standard messaging *(verify)* | Graph API direct | Test page; mock |
| Instagram | ✅ user-initiated | ✅ 24 h window | ✅ | ✅ | ✅ | ✅ | No per-message fee *(verify)* | Graph API direct | Test account; mock |
| Apple MfB | ✅ customer-initiated | ◐ | ✅ incl. Apple Pay | ✅ | ✅ | ✅ | Apple fee none known; MSP fee | Approved MSPs: Infobip, Sinch, CM.com, Zendesk [7] | MSP sandbox; mock |
| Viber | ◐ | ◐ promo vs transactional | ✅ | ✅ | ✅ | ✅ | Per message + €115–200/month minimum (resellers) [8] | Infobip, Sinch | Mock |
| Voice agent call | ❌ | ❌ | ❌ | ✅ call status | n/a | ✅ | Per minute, quote needed | Twilio, Vonage, Telnyx; FR: Axialys, Diabolocom, Ringover *(verify)* | Mock |
| IVR / voicebot | ❌ | ❌ | ❌ (pay by DTMF/SMS link) | ✅ | n/a | ✅ | Per minute + TTS/STT | Same as above | Mock |
| Web push | ✅ browser permission | ❌ | ◐ title + link | ◐ | ❌ | ❌ | Free | In-house (VAPID) | Mock |
| Portal chat | n/a | ❌ | ✅ | ✅ | ✅ | ✅ | Infra only | In-house | n/a |
| Simple letter | ❌ | ❌ | ◐ QR code to portal | ◐ (production/posting status) | ❌ | ❌ (paper replies scanned) | ~€1–2 per letter *(quote needed)* | Maileva (La Poste group), Merci Facteur, Docaposte | Maileva sandbox [9]; mock |
| LRAR | ❌ | ❌ | ◐ QR | ✅ posting proof + AR | ✅ (AR signed) | ❌ | La Poste 2026 public price ≈ €6.11–7.56 (sources differ) [10] + provider fee | Maileva, Merci Facteur, AR24 (hybrid) | Maileva sandbox; mock |
| Qualified LRE | ✅ **legal consent for non-professionals** (CPCE L100) | ❌ | ◐ attachments | ✅ qualified proof of sending | ✅ proof of receipt/refusal | ❌ | ≈ €3–6.5 *(dated figure, quote needed)* [11] | AR24 (Docaposte), La Poste e-LRE; other FR qualified providers [11] | Mock |

**Cost note:** the founder chose Brevo for email + SMS because its FR SMS price (~€0.045) beats Twilio's (~$0.0798). French SMS aggregators are in the same range. See the policy risk in §3.

## 3. Platform-policy status for debt collection (information only)

| Provider / platform | Status for third-party debt collection | What it means for us | Source |
|---|---|---|---|
| **WhatsApp Business** | **Prohibited**: debt collection is listed in the Business Messaging Policy's prohibited list, "irrespective of licences" *(verify on official page)* | Risk of WABA restriction / number ban. Founder accepts. Isolate blast radius (see §4.3). | [12] |
| **Brevo** (email + SMS) | **Restricted / high-risk**: Appendix 7 (anti-spam policy) lists "Debt collection" among activities that "generate very bad signals"; non-compliance can lead to immediate suspension *(verify)* | **Our chosen email+SMS provider flags our use case.** Recommend declaring the use case to Brevo up front and getting a written OK, and keeping a hot standby provider. | [13] |
| Mailjet (Sinch) | **Prohibited**: sending policy lists "debt collection agencies" | Don't use. | [14] |
| Twilio (SMS) | **Prohibited in US/CA** (carrier rules: third-party debt collection; first-party with direct consent allowed). FR rules not stated. Voice not subject to the same carrier rules. | Avoid for SMS; voice usable. | [15] |
| Viber | **Prohibited for third-party agencies** (allowed only for licensed banks and essential utilities) | Low priority; account rejection likely. | [16] |
| Google RCS (RBM) | AUP applies; no FR-specific debt-collection rule found. US carriers disallow third-party collection. | Agent launch review may reject; ask aggregator before investing. | [17] |
| Meta Messenger / Instagram | No explicit debt-collection rule found. Message-tag misuse leads to restrictions. | Use only inside the 24 h window or with allowed tags. | [18] |
| Apple Messages for Business | No debt-collection rule found. Live-agent access required during business hours; bot-only not allowed. Customer-initiated only. | Inbound support channel only; needs human staffing. | [7] |
| Telegram | No debt-collection rule found in Bot Developer ToS. Bots can't start conversations (403 "bot can't initiate conversation"). | Opt-in through portal deep link only. | [19] |
| AWS SES | No explicit rule found; SES is meant for messages the recipient requested. | Possible standby ESP; ask AWS first. | [20] |
| Scaleway TEM | Transactional email only; anti-spam policy not readable from here. | Possible standby ESP (FR, Paris DC); ask Scaleway first. | [21] |
| Octopush / SMSFactor / Allmysms | No restriction found (marketing-oriented FR aggregators; account validation step). | Standby SMS provider candidates; ask before signing. | [2] |
| Postal / LRAR / LRE providers | Regulated postal / trust services; no use-case restriction found. | Lowest policy risk. | — |

**Takeaway:** platform risk is not limited to WhatsApp. Email and SMS providers flag debt collection too. So the "no single point of failure" rule (brief §3.6) applies at **two levels**:
- **provider failover**: same channel, second provider
- **channel fallback**: next allowed channel

## 4. Fallback rules

### 4.1 Guardrails before any send, including a fallback send (flows cannot override)
Each outbound attempt, whether first try or fallback, goes through the same pre-send gate:
1. **Hold check:** no outbound if the account has an active hold (dispute, surendettement, procédure collective, deceased, wrong party, recalled). Legal basis in COMPLIANCE.
2. **Contact point valid** for that channel: not marked invalid, not opted out, within validity dates.
3. **Consent where the law or the channel requires it:**
   - **LRE to a non-professional** needs prior consent (CPCE L100). Without it, fall back to **paper LRAR**, never to another electronic channel.
   - Opt-in channels (Telegram, push, user-initiated Meta/Apple): only if the debtor opened the conversation or opted in.
4. **Locked legal blocks** required for this message type are present and render on the target channel. If a mandatory block (e.g. the R124-4 first-letter mentions) can't fit the channel, that channel is not eligible for that message type.
5. **Business settings** of the flow (frequency caps, sending windows, budget). These are business choices, not legal rules.
6. **Idempotency:** one send per (step, account, message type). A fallback reuses the step's idempotency key with a channel suffix, so a step never double-sends.

A fallback never weakens a guardrail. If no channel passes the gate, the step ends as `no_eligible_channel` and creates an ops task.

### 4.2 Restriction / failure detection signals
| Signal | Example | Health effect |
|---|---|---|
| Provider auth/account errors | HTTP 401/403 on the provider API, "account suspended" | channel+provider → `restricted`, alert ops |
| Platform status webhooks | WhatsApp template `REJECTED`/`PAUSED`, phone number quality `RED`/`FLAGGED`, WABA restriction | template or number → `restricted` |
| Hard per-recipient errors | Telegram 403 "bot was blocked by the user", email hard bounce, SMS invalid number | contact point → `invalid` (does not affect channel health) |
| Rate anomalies | bounce > 5% or complaint > 0.1% (email), SMS DLR failure > 20% over 1 h | → `degraded`, alert ops *(thresholds are starting points, tune later)* |
| Timeouts / 5xx | provider outage | circuit breaker opens for N minutes → `down`, retry with backoff |

Channel health is stored per (tenant, channel, provider, sender identity). States: `healthy` → `degraded` → `restricted` / `down`. Changing state emits an event, sends an ops alert, and is visible in the back-office.

### 4.3 Fallback order
1. **Provider failover first** (same channel, same content): e.g. Brevo SMS → standby FR SMS aggregator; Brevo email → standby ESP.
2. **Channel fallback** (next eligible channel), default chains per message intent. Each flow node can override the order:
   - *Reminder / nudge:* WhatsApp → RCS → SMS → email → push
   - *Payment link:* RCS → WhatsApp → SMS → email
   - *Formal notice / first letter (legal-grade):* LRE (if consent) → LRAR (paper). Email/SMS only as an *additional* notice, never a replacement.
   - *Inbound conversation reply:* reply on the channel the debtor used, inside its window. Otherwise send a template on the same channel, else SMS/email.
3. **Blast-radius isolation:**
   - WhatsApp: one WABA / sender number per client brand where possible, so one restriction doesn't stop every tenant.
   - Email: separate sending sub-domains per client.

## 5. Capability descriptor (sketch)

One descriptor per (channel, provider), stored as versioned config. The decisioning layer and the pre-send gate read it, so no channel-specific `if`s outside the adapter.

```yaml
channel: whatsapp
provider: meta_cloud_api
version: 3
business_initiated: true
requires_opt_in: platform_expected        # none | platform_expected | user_must_initiate | legal_consent
legal_consent_rule: null                  # e.g. "cpce_l100_non_professional" for LRE
conversation_window_hours: 24
templates_required_outside_window: true
template_approval: platform               # none | platform | carrier
content:
  max_length: 1024
  rich: [buttons, links, documents]
  payment_link: true
  can_render_locked_blocks: [gdpr_art14_link]   # legal blocks this channel can carry
receipts: {delivery: true, read: true}
inbound: true
proof: {type: provider_status_log, legal_grade: false}
unit_cost: {currency: EUR, amount_minor: 248, scale: 4, unit: message, category: utility,
            source: "https://www.engagelab.com/fr_FR/blog/whatsapp-api-pricing", retrieved: 2026-11-07}
data_residency: outside_eu                # GDPR ch. V transfer basis required
platform_policy:
  debt_collection: prohibited             # allowed | restricted | prohibited | unknown
  source: "https://business.whatsapp.com/policy"
  checked: 2026-11-07
health_signals: [template_status_webhook, phone_quality_webhook, http_403]
sandbox: {provider: test_number, mock_adapter: true}
```

The adapter interface (send, inbound, status webhook, proof, cost) is in `docs/ARCHITECTURE.md`. Every adapter ships with a mock and contract tests (brief §6, §7).

## 6. Proposed priority

**Wave 1 (fixed by brief, M4/M6):** email, SMS, WhatsApp, simple letter, LRAR + LRE, portal chat.

**Proposed order after wave 1** (reach in France, cost, policy risk). *Founder to confirm.*

| Order | Channel | Why |
|---|---|---|
| 1 | Voice: IVR + outbound agent call | Universal reach; needed by collectors (M7); IVR payment line is cheap self-service; no carrier-style debt ban found for voice. |
| 2 | RCS | ~84% of FR smartphones capable [4], branded and verified sender (trust, anti-phishing), rich payment button, SMS fallback built in. Policy review risk → ask aggregator first. |
| 3 | Web push | Free; re-engages debtors who already used the portal. |
| 4 | Voicebot | After IVR; reuses telephony; needs the AI gateway and guardrails. |
| 5 | Messenger | ~49% of FR population [22], but user-initiated only → mainly an inbound channel. |
| 6 | Instagram | Same adapter family as Messenger; younger debtors; user-initiated only. |
| 7 | Apple Messages for Business | User-initiated, needs live agents during business hours and an MSP. Inbound support only. |
| 8 | Telegram | Free, but opt-in only and low reach. Cheap to build (Bot API). |
| 9 | Viber | Low reach in France, monthly minimum, third-party collection explicitly prohibited. |

## 7. CPaaS vs direct (feeds ADR "CPaaS vs direct channels")

| Channel | Recommendation | Reason |
|---|---|---|
| Email | **Direct ESP** (Brevo) + standby ESP | Commodity; CPaaS adds nothing. |
| SMS | **Direct** (Brevo) + standby FR aggregator | FR aggregators ≈ €0.035–0.05 vs US CPaaS ≈ $0.08. |
| WhatsApp | **Direct Meta Cloud API** | No BSP markup; one adapter. BSP only if Meta onboarding fails. |
| RCS | **Aggregator** (Digital Virgo / Infobip / Sinch) | Agent launch goes through carriers; aggregator handles it and SMS fallback. |
| Telegram | **Direct** Bot API | Free, simple. |
| Messenger / Instagram | **Direct** Graph API | Same Meta app as WhatsApp. |
| Apple MfB | **MSP** (required by Apple) | No direct option. |
| Viber | **Aggregator** | Viber sells through partners. |
| Voice / IVR | **CPaaS** (programmable voice) | Telephony numbering + media; build only flows. |
| Web push | **Direct** (VAPID) | Free, standard. |
| Portal chat | **In-house** | Supabase Realtime. |
| Letters / LRAR | **Direct** hybrid-mail API (Maileva or Merci Facteur) | One API, PDF in, tracking out. |
| LRE | **Direct** qualified provider (AR24 / La Poste) | Legal-grade proof must come from a qualified provider. |

## 8. Open questions

**For the founder:**
- **Brevo flags debt collection in its anti-spam policy.** Default: keep Brevo, declare the use case to them in writing before go-live, and build a standby provider from day one. Alternative: pick a provider that explicitly accepts collection.
- **WhatsApp:** one WABA per client brand, or one Collectoo WABA? Default: per brand where the client agrees.

**For counsel (not built until confirmed, see COMPLIANCE):**
- Can the R124-4 first letter be sent by email/LRE, or must it be paper?
- Is any legal limit on contact hours/frequency applicable to amicable collection? None identified. Sending windows are business settings for now.

## Sources (retrieved 2026-11-07, via web search)
1. Brevo SMS pricing (4.5 credits/FR SMS, €0.01/credit): https://getkanal.com/fr/blog/brevo-prix
2. FR SMS aggregators pricing: https://digitiz.fr/logiciels-envoyer-sms-en-masse/ ; https://blog.hubspot.fr/service/logiciel-envoi-sms-masse-entreprise ; https://www.appvizer.fr/marketing/sms-marketing/allmysms
3. Twilio SMS France: https://www.twilio.com/en-us/sms/pricing/fr
4. RCS compatibility in France: https://fr.themedialeader.com/80-des-smartphones-en-france-sont-desormais-compatibles-avec-le-rcs/ ; https://mobileecosystemforum.com/2026/03/03/kpn-netherlands-launch-sees-universal-domestic-reach-of-rcs-spreading-across-europe/
5. Twilio × Orange RCS France: https://investors.twilio.com/news-releases/news-release-details/twilio-and-orange-bring-secure-and-interactive-rcs-messaging/ ; Digital Virgo: https://www.digitalvirgo.com/blog/rcs-is-no-longer-a-future-vision-its-happening-now-the-2025-comeback-of-rich-messaging-paving-the-way-for-the-next-generation-messaging-standard-in-2026/
6. WhatsApp pricing: https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing ; FR rates: https://www.engagelab.com/fr_FR/blog/whatsapp-api-pricing ; https://getkanal.com/fr/blog/guide-tarifs-whatsapp-business.md
7. Apple Messages for Business: https://register.apple.com/resources/messages/messaging-documentation/go-live ; https://infobip.com/docs/apple-messages-for-business/compliance-guidelines
8. Viber pricing: https://www.infobip.com/viber-business/pricing ; https://smsbat.com/it/pricing/viber-business-messages/france/
9. Maileva API sandbox (via SDK docs): https://packagist.org/packages/ceddyg/maileva-sdk-php
10. LRAR 2026 prices: https://www.tarif-lettre.com/tarif-lettre-recommandee-2026 ; https://laposte.fr/tarif-lettre-recommandee
11. Qualified LRE providers / AR24: https://www.lafabriquedunet.fr/logiciels/gestion/envoi-recommande-en-ligne ; https://www.lettre-resiliation.com/aide/lettre-recommandee-electronique/service-envoi-ar24.html ; https://www.lapostegroupe.com/assets/media/le-groupe-laposte/4196f9b9-3fb6-44e2-9912-0434fee1f26d_CP+Docaposte+AR24_vDEF.pdf
12. WhatsApp Business Messaging Policy: https://business.whatsapp.com/policy (official, not readable from this session) ; copies: https://learn.rasayel.io/en/books/whatsapp/whatsapp-business/whatsapp-business-messaging-policy ; https://docs.apifycloud.io/guides/whatsapp/compliance
13. Brevo anti-spam policy (Appendix 7): https://www.brevo.com/legal/antispampolicy/
14. Mailjet sending policy: https://www.mailjet.com/fr/legal/sending-policy/
15. Twilio: https://support.twilio.com/hc/en-us/articles/360045004974-Forbidden-Message-Categories-for-SMS-and-MMS-in-the-US-and-Canada ; https://www.twilio.com/docs/api/errors/30943
16. Viber SMS Partners Guidelines (June 2025): https://www.viber.com/app/uploads/Viber-SMS-Partners-Guidelines_June-2025.pdf
17. Google RCS for Business ToS: https://developers.google.com/rcs-business-messaging/support/tos/
18. Meta Messenger Platform policy: https://developers.facebook.com/documentation/business-messaging/messenger-platform/policy ; https://developers.facebook.com/docs/messenger-platform/send-messages
19. Telegram Bot Developer ToS: https://telegram.org/tos/bot-developers ; behaviour: https://github.com/python-telegram-bot/python-telegram-bot/wiki/Introduction-to-the-API
20. AWS AUP / SES enforcement: https://aws.amazon.com/aup ; https://docs.aws.amazon.com/ses/latest/DeveloperGuide/faqs-enforcement.html
21. Scaleway TEM FAQ: https://www.scaleway.com/en/docs/transactional-email/faq/
22. Messenger users in France (Sep 2026): https://napoleoncat.com/stats/messenger-users-in-france/
