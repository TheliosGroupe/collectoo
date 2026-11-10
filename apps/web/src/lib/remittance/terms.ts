import type { ErrorCode } from "@/lib/boarding/forms";
import { money } from "@/lib/payments/statements";

/**
 * M2c-2: what the identity, payout-account and mandate-terms pages say (design §17.4, §17.5, §17.7). The money terms
 * (commission-1, remittance-1, design §8.1–§8.2) are shown « in words », from the stored documents only: rates and
 * amounts are decimal and integer strings, turned into French text without floats. The database validates and decides
 * (private.commission_schedule_error, private.remittance_terms_error, the confirmation gate): these are words.
 */

export type Address = { line1: string; line2?: string | null; postcode: string; city: string; country: string };

/** The legal forms whose mentions the documents print (C. com. R123-238; R123-237 9° for EI). */
export const LEGAL_FORMS: readonly { value: string; label: string }[] = [
  { value: "SAS", label: "SAS – société par actions simplifiée" },
  { value: "SARL", label: "SARL – société à responsabilité limitée" },
  { value: "SA", label: "SA – société anonyme" },
  { value: "SA_DIRECTOIRE", label: "SA à directoire et conseil de surveillance" },
  { value: "SCA", label: "SCA – société en commandite par actions" },
  { value: "SE", label: "SE – société européenne" },
  { value: "SNC", label: "SNC – société en nom collectif" },
  { value: "SCS", label: "SCS – société en commandite simple" },
  { value: "EI", label: "EI – entrepreneur individuel" },
  { value: "OTHER", label: "Autre forme (non imprimée)" },
];

/** Why a portfolio cannot be confirmed yet (private.portfolio_confirmation_blockers, design §9.1). */
export const READINESS_LABEL: Readonly<Record<string, string>> = {
  no_active_mandate: "Aucun mandat en vigueur aujourd'hui (art. R124-3 CPCE)",
  insurance_clause_missing: "Clause de garantie du mandat non renseignée (R124-3 2°)",
  commission_schedule_missing: "Barème de commission absent (R124-3 3°)",
  commission_clause_missing: "Référence de la clause de rémunération absente (R124-3 3°)",
  remittance_terms_missing: "Conditions de reversement absentes (R124-3 4°)",
  remittance_clause_missing: "Référence de la clause de reversement absente (R124-3 4°)",
  terms_document_missing: "Mandat signé non joint aux conditions en vigueur",
  servicer_identity_incomplete: "Identité de facturation du cabinet incomplète",
  client_identity_incomplete: "Identité du client incomplète (SIREN, siège social)",
  client_not_professional: "Le client n'est pas un professionnel : seuls les professionnels sont servis",
  client_not_mainland_france: "Le client n'est pas établi en France métropolitaine",
  currency_not_eur: "Le lot contient des dossiers hors euro : seul l'euro est servi",
};

/** What an identity still lacks (private.billing_identity_gaps). */
export const GAP_LABEL: Readonly<Record<string, string>> = {
  organization: "organisation inconnue",
  identity: "identité de facturation non saisie",
  siren: "SIREN",
  legal_form: "forme juridique",
  share_capital: "capital social",
  rcs_city: "ville du greffe (RCS)",
  vat_number: "numéro de TVA",
  professional: "client professionnel",
  mainland_france: "établi en France métropolitaine",
};

export const PAYOUT_STATUS: Readonly<Record<string, string>> = {
  proposed: "En attente de confirmation",
  active: "Confirmé",
  returned: "Virement revenu impayé : à remplacer ou confirmer à nouveau",
  retired: "Retiré",
  rejected: "Refusé",
};

export const CONFIRMED_VIA: Readonly<Record<string, string>> = {
  client_portal: "par le client, dans son espace",
  second_admin: "par un second administrateur du cabinet",
};

export const EVENT_KIND: Readonly<Record<string, string>> = {
  proceeding_opened: "Ouverture d'une procédure collective",
  liquidation: "Liquidation judiciaire",
  death: "Décès",
  guardianship: "Tutelle ou curatelle",
  mandate_ended: "Fin du mandat",
};

export const DOCUMENT_KIND: Readonly<Record<string, string>> = {
  payout_rib: "RIB",
  mandate_document: "Mandat signé ou avenant",
  client_status_evidence: "Justificatif d'événement",
};

const FAMILY: Readonly<Record<string, string>> = {
  principal: "principal",
  interest: "intérêts",
  indemnity: "indemnités",
  charge: "frais",
  cost: "dépens",
  unclassified: "sommes non ventilées",
};

const WEEKDAY = ["", "lundi", "mardi", "mercredi", "jeudi", "vendredi"];

const COUNTRY: Readonly<Record<string, string>> = { FR: "France", BE: "Belgique", LU: "Luxembourg", MC: "Monaco", CH: "Suisse" };

/** A decimal rate string ("0.1500", "0.125", "1") as a French percentage ("15 %", "12,5 %", "100 %"). */
export function rateText(rate: string): string {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(rate);
  if (!m) return rate;
  const frac = (m[2] ?? "").padEnd(2, "0");
  const whole = (BigInt(m[1]) * BigInt(100) + BigInt(frac.slice(0, 2))).toString();
  const decimals = frac.slice(2).replace(/0+$/, "");
  return `${whole}${decimals ? `,${decimals}` : ""} %`;
}

/** An amount in euro cents (a string) as French money. */
function euros(minor: string): string {
  return money(minor, "EUR");
}

type Band = { bound: string | null; rate: string };

function bands(rows: unknown, key: string): Band[] {
  if (!Array.isArray(rows)) return [];
  return rows.map((r: Record<string, unknown>) => ({
    bound: typeof r?.[key] === "string" ? (r[key] as string) : null,
    rate: typeof r?.rate === "string" ? r.rate : "?",
  }));
}

/** A marginal grid: « 10 % jusqu'à 5 000,00 €, puis 6 % au-delà » (tiers on what the file brought in). */
function marginalText(tiers: Band[]): string {
  if (tiers.length === 1) return `${rateText(tiers[0].rate)} sur tout ce que le dossier rapporte`;
  const parts = tiers.map((t, i) => {
    const from = i > 0 ? tiers[i - 1].bound : null;
    if (t.bound === null) return `${rateText(t.rate)} au-delà de ${euros(from ?? "0")}`;
    if (from === null) return `${rateText(t.rate)} jusqu'à ${euros(t.bound)}`;
    return `${rateText(t.rate)} de ${euros(from)} à ${euros(t.bound)}`;
  });
  return `${parts.join(", ")} encaissés sur le dossier`;
}

/** A bracket grid: one rate for the whole file, chosen by an attribute fixed at boarding. */
function bracketText(attribute: string, brackets: Band[]): string {
  const what = attribute === "age_days_at_boarding" ? "l'ancienneté de la créance à la reprise" : "le montant repris";
  const limit = (b: string) => (attribute === "age_days_at_boarding" ? `${b} jours` : euros(b));
  const parts = brackets.map((b) =>
    b.bound === null ? `sinon ${rateText(b.rate)}` : `${rateText(b.rate)} si ${what} va jusqu'à ${limit(b.bound)}`,
  );
  return `${parts.join(", ")} (taux unique pour le dossier)`;
}

/** The commission schedule (commission-1) in words: one line for the basis, one per rule, in order. */
export function scheduleInWords(schedule: unknown, claimTypeLabels: Readonly<Record<string, string>> = {}): string[] {
  if (!schedule || typeof schedule !== "object") return [];
  const s = schedule as { basis?: Record<string, unknown>; rules?: unknown };
  const out: string[] = [];
  const basis = s.basis ?? {};
  const families = basis.families;
  out.push(
    families === "all" || !Array.isArray(families)
      ? "Base : toutes les sommes imputées sur les créances du client"
      : `Base : ${families.map((f) => FAMILY[String(f)] ?? String(f)).join(", ")} imputés`,
  );
  const forwards = (basis.forwards ?? {}) as Record<string, unknown>;
  const reasons = [
    forwards.file_recalled === true ? "dossier rappelé" : null,
    forwards.before_servicing_start === true ? "paiement antérieur à la reprise" : null,
    forwards.client_ratification === true ? "ratification du client" : null,
  ].filter((x): x is string => x !== null);
  if (reasons.length > 0) out.push(`Commission aussi sur les reversements sans imputation : ${reasons.join(", ")}`);
  out.push(
    basis.on_reversal === "keep"
      ? "Encaissement annulé ensuite : la commission reste due (clause du mandat)"
      : "Encaissement annulé ensuite : un avoir rectifie la commission",
  );
  for (const rule of Array.isArray(s.rules) ? s.rules : []) {
    const r = rule as Record<string, unknown>;
    const match = (r.match ?? {}) as Record<string, unknown>;
    const scope: string[] = [];
    if (Array.isArray(match.claim_types))
      scope.push(match.claim_types.map((c) => claimTypeLabels[String(c)] ?? String(c)).join(", "));
    if (Array.isArray(match.families)) scope.push(match.families.map((f) => FAMILY[String(f)] ?? String(f)).join(", "));
    if (Array.isArray(match.portfolio_ids)) scope.push(`${match.portfolio_ids.length} portefeuille(s) désigné(s)`);
    const rate = (r.rate ?? {}) as Record<string, unknown>;
    const how =
      rate.kind === "flat" && typeof rate.rate === "string"
        ? rateText(rate.rate)
        : rate.kind === "marginal"
          ? marginalText(bands(rate.tiers, "up_to_minor"))
          : rate.kind === "bracket"
            ? bracketText(String(rate.attribute), bands(rate.brackets, "up_to"))
            : "taux non reconnu";
    const min = typeof r.min_per_file_minor === "string" ? ` ; minimum ${euros(r.min_per_file_minor)} par dossier` : "";
    out.push(`${String(r.label_fr ?? r.id)}${scope.length ? ` (${scope.join(" ; ")})` : " (tout le reste)"} : ${how}${min}`);
  }
  return out;
}

/** The remittance terms (remittance-1) and the delay of the version, in words. */
export function termsInWords(terms: unknown, maxDays: number): string[] {
  if (!terms || typeof terms !== "object") return [];
  const t = terms as Record<string, unknown>;
  const clause = (c: unknown) =>
    c && typeof c === "object" && typeof (c as { clause_ref?: unknown }).clause_ref === "string"
      ? (c as { clause_ref: string }).clause_ref
      : null;
  const netting = clause(t.netting);
  const clawback = clause(t.clawback);
  const days = typeof t.invoice_payment_days === "number" ? t.invoice_payment_days : null;
  return [
    t.frequency === "weekly"
      ? `Reversements chaque semaine, le ${WEEKDAY[Number(t.weekday)] ?? "?"} (ou le jour ouvré suivant)`
      : "Reversements deux fois par mois, le 1er et le 16 (ou le jour ouvré suivant)",
    `Délai : au plus ${maxDays} jour${maxDays > 1 ? "s" : ""} après l'encaissement, et jamais plus d'un mois (art. R124-6 CPCE)`,
    netting
      ? `Commission compensée sur chaque reversement (${netting})`
      : `Pas de compensation : reversement brut, facture payable sous ${days ?? "?"} jours sur le compte propre du cabinet`,
    clawback
      ? `Avances du cabinet reprises sur les reversements suivants (${clawback})`
      : "Avances du cabinet : demande de remboursement (pas de clause de reprise)",
  ];
}

/** A postal address on one line: « 10 rue de la Bourse, 75002 Paris » (+ the country outside France). */
export function addressText(a: Address | null | undefined): string {
  if (!a) return "";
  const parts = [a.line1, a.line2, `${a.postcode} ${a.city}`];
  if (a.country !== "FR") parts.push(COUNTRY[a.country] ?? a.country);
  return parts.filter((p) => p).join(", ");
}

/** The address fields of a form (prefix_line1, prefix_line2, prefix_postcode, prefix_city, prefix_country). */
export function addressFromForm(formData: FormData, prefix: string): Address | null {
  const get = (k: string) => String(formData.get(`${prefix}_${k}`) ?? "").trim();
  const address: Address = {
    line1: get("line1"),
    postcode: get("postcode"),
    city: get("city"),
    country: (get("country") || "FR").toUpperCase(),
  };
  const line2 = get("line2");
  if (line2) address.line2 = line2;
  return address.line1 || address.postcode || address.city ? address : null;
}

export type BillingIdentity = {
  legal_form: string | null;
  share_capital_minor: number | string | null;
  rcs_city: string | null;
  registered_office: Address;
  billing_address: Address | null;
  vat_number: string | null;
  is_professional: boolean;
  in_liquidation: boolean;
  invoice_acceptance_ref: string | null;
  version: number;
};

const FORM_MENTION: Readonly<Record<string, string>> = {
  SA_DIRECTOIRE: "société anonyme à directoire et conseil de surveillance",
  OTHER: "",
};

/**
 * The issuer's mentions as receipts (quittance-fr-3) print them (C. com. R123-237: SIREN, « RCS » and the registry's
 * city, the registered office, « en liquidation »; R123-238: the legal form and the capital next to the name): the
 * same lines as the worker's `issuer_block`, for the settings page's preview.
 */
export function issuerLines(name: string, siren: string | null, identity: BillingIdentity | null): string[] {
  if (!identity || !siren) return [name];
  let head = name;
  const form = identity.legal_form ? (FORM_MENTION[identity.legal_form] ?? identity.legal_form) : "";
  if (form) head += ` ${form}`;
  if (identity.share_capital_minor !== null && identity.share_capital_minor !== undefined)
    head += ` au capital de ${money(String(identity.share_capital_minor), "EUR").replace(",00 ", " ")}`;
  if (identity.in_liquidation) head += " – en liquidation";
  const ids = `SIREN ${siren.slice(0, 3)} ${siren.slice(3, 6)} ${siren.slice(6, 9)}${identity.rcs_city ? ` · RCS ${identity.rcs_city}` : ""}`;
  return [head, ids, `Siège social : ${addressText(identity.registered_office)}`];
}

/** A SIREN typed with spaces (« 849 678 297 ») as nine digits. */
export function cleanSiren(text: string): string {
  return text.replace(/[\s  ]/g, "");
}

/** Code for an error of the M2c-2 commands (identities, settings, documents, payout accounts, events, terms). */
export function identityErrorCode(message: string): ErrorCode {
  const rules: [string, ErrorCode][] = [
    ["not allowed", "not_allowed"],
    ["changed since", "changed_since_read"],
    ["a legal name is required", "legal_name_required"],
    ["invalid SIREN", "siren_invalid"],
    ["invalid share capital", "capital_invalid"],
    ["invalid registered office", "address_invalid"],
    ["invalid billing address", "address_invalid"],
    ["VAT number does not match", "vat_mismatch"],
    ["servicer's identity is incomplete", "servicer_identity_incomplete"],
    ["too long", "text_too_long"],
    ["the own account must be", "settings_own_account"],
    ["a cut-off is", "cutoff_invalid"],
    ["invoice prefix", "prefix_invalid"],
    ["named in the billing settings", "own_account_in_settings"],
    ["not uploaded yet", "document_not_uploaded"],
    ["document: invalid", "document_invalid"],
    ["not at a key of this client", "document_invalid"],
    ["client's RIB is required", "rib_required"],
    ["holder's name is required", "holder_required"],
    ["already waits for confirmation", "payout_pending"],
    ["one of the servicer's own bank accounts", "payout_own_iban"],
    ["another client's payout account", "payout_other_client"],
    ["no longer waiting for confirmation", "payout_not_pending"],
    ["cannot confirm it", "payout_same_person"],
    ["IBAN typed is not the one proposed", "payout_iban_mismatch"],
    ["not the current account", "payout_not_current"],
    ["invalid IBAN", "iban_invalid"],
    ["invalid BIC", "bic_invalid"],
    ["cannot be in the future", "event_future"],
    ["the evidence is required", "evidence_required"],
    ["only a court-appointed", "court_account_only"],
    ["never starts before today", "terms_past"],
    ["already starts that day", "terms_start_taken"],
    ["invalid commission schedule", "schedule_invalid"],
    ["invalid remittance terms", "terms_invalid"],
    ["clause references are required", "clauses_required"],
    ["signed document is required", "terms_document_required"],
    ["unknown claim type", "claim_type_unknown"],
    ["a portfolio of another mandate", "portfolio_other_mandate"],
    ["remittance delay is 1 to 30 days", "max_days_invalid"],
    ["the clause reference is required", "clause_required"],
    ["a reason is required", "reason_required"],
    ["invalid", "unknown"],
  ];
  for (const [needle, code] of rules) if (message.includes(needle)) return code;
  return "unknown";
}
