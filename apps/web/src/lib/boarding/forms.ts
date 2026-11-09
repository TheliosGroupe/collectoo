/**
 * Pure helpers for the boarding review forms (unit-tested, no floats for money).
 */

const MAX_BIGINT = BigInt("9223372036854775807"); // Postgres bigint

/**
 * Parses an amount typed in euros ("12 345,67", "12345.6", "1 000") into integer minor units.
 * Returns null when the text is not an amount or does not fit a bigint. Never goes through a float.
 */
export function parseEurosToMinor(text: string): bigint | null {
  const compact = text.replace(/[\s  €]/g, "");
  const match = /^(-?)(\d+)(?:[.,](\d{1,2}))?$/.exec(compact);
  if (!match) return null;
  const [, sign, units, decimals = ""] = match;
  const minor = BigInt(units) * BigInt(100) + BigInt(decimals.padEnd(2, "0") || "0");
  if (minor > MAX_BIGINT) return null;
  return sign === "-" ? -minor : minor;
}

export type Proposal = { file_id: string; source_column: string; target: string | null };

/** Field name of the select for one proposal in the mapping form. */
export function mappingField(fileId: string, column: string): string {
  return `map:${fileId}:${encodeURIComponent(column)}`;
}

/**
 * Overrides for `approve_mapping`: {file_id: {source_column: target | ""}} for every select whose
 * value differs from the proposal ("" = not mapped).
 */
export function mappingOverrides(
  proposals: Proposal[],
  values: (field: string) => string | null,
): Record<string, Record<string, string>> {
  const out: Record<string, Record<string, string>> = {};
  for (const p of proposals) {
    const chosen = values(mappingField(p.file_id, p.source_column));
    if (chosen === null) continue;
    if (chosen === (p.target ?? "")) continue;
    (out[p.file_id] ??= {})[p.source_column] = chosen;
  }
  return out;
}

/**
 * Errors of the back-office commands (boarding, bank accounts), as codes: raw database text never
 * reaches the page.
 */
export type ErrorCode =
  | "not_allowed"
  | "totals_mismatch"
  | "reason_required"
  | "mandate_missing"
  | "duplicate_target"
  | "name_taken"
  | "already_submitted"
  | "unsupported_type"
  | "missing_upload"
  | "state_changed"
  | "cut_off_required"
  | "cut_off_future"
  | "opening_mismatch"
  | "opening_plan_missing"
  | "ledger_rejected"
  | "iban_invalid"
  | "close_confirmation"
  | "bic_invalid"
  | "iban_taken"
  | "label_required"
  | "opened_future"
  | "account_holds_money"
  | "already_closed"
  | "already_matched"
  | "file_not_confirmed"
  | "split_not_available"
  | "unknown_file"
  | "not_matched"
  | "payment_allocated"
  | "busy"
  | "designation_invalid"
  | "unknown";

const ERROR_TEXT: Record<ErrorCode, string> = {
  not_allowed: "Action non autorisée pour votre rôle.",
  totals_mismatch:
    "Les totaux ne concordent pas avec ceux du cédant : indiquez un motif pour intégrer quand même.",
  reason_required: "Indiquez un motif.",
  mandate_missing:
    "Aucun mandat actif ne couvre ce portefeuille (art. R124-3 CPCE) : la confirmation est impossible.",
  duplicate_target: "Deux colonnes d'un même fichier ont la même cible.",
  name_taken: "Un autre fichier porte déjà ce nom dans ce lot : renommez-le.",
  already_submitted: "Ce lot a déjà été déposé. Ouvrez-le depuis la liste des reprises.",
  unsupported_type: "Type de fichier non pris en charge (CSV, Excel, largeur fixe ou zip).",
  missing_upload: "Un fichier n'a pas été envoyé. Réessayez.",
  state_changed: "Le lot a changé d'état entre-temps. Rechargez la page.",
  cut_off_required:
    "La date d'arrêté du portefeuille est obligatoire et ne peut pas être dans le futur : abandonnez ce lot et créez-en un avec une date d'arrêté passée.",
  cut_off_future: "La date d'arrêté ne peut pas être dans le futur : le fichier décrit le portefeuille à une date passée.",
  opening_mismatch:
    "Les soldes d'ouverture ne correspondent pas au rapport qualité : abandonnez ce lot et déposez à nouveau le fichier.",
  opening_plan_missing:
    "Ce lot a été intégré avant la comptabilisation des soldes d'ouverture : annulez l'intégration, puis déposez à nouveau le fichier.",
  ledger_rejected: "La comptabilité a refusé l'opération. Contactez le support.",
  iban_invalid: "IBAN invalide : vérifiez la saisie (27 caractères pour un compte en France).",
  close_confirmation: "Pour confirmer la clôture, saisissez les 4 derniers caractères de l'IBAN de ce compte.",
  bic_invalid: "BIC invalide : 8 ou 11 caractères (lettres et chiffres).",
  iban_taken: "Cet IBAN est déjà enregistré dans cette devise.",
  label_required: "Indiquez un libellé (100 caractères au plus).",
  opened_future: "La date d'ouverture ne peut pas être dans le futur.",
  account_holds_money:
    "Ce compte détient encore des fonds de tiers : il ne peut pas être clôturé tant que son solde n'est pas nul.",
  already_closed: "Ce compte est déjà clôturé. Rechargez la page.",
  already_matched: "Ce paiement est déjà affecté à un dossier : désaffectez-le d'abord. Rechargez la page.",
  file_not_confirmed:
    "Ce dossier n'est pas encore confirmé : le paiement lui sera rapproché automatiquement à la confirmation du lot.",
  split_not_available:
    "Un paiement est affecté à un seul dossier pour l'instant : la répartition sur plusieurs dossiers viendra avec l'imputation.",
  unknown_file: "Dossier introuvable pour ce servicer.",
  not_matched: "Ce paiement n'est affecté à aucun dossier. Rechargez la page.",
  payment_allocated: "Une partie de ce paiement est déjà imputée : annulez d'abord l'imputation.",
  busy: "Ce paiement est en cours de rapprochement automatique : réessayez dans un instant.",
  designation_invalid: "Les factures désignées doivent appartenir à ce dossier.",
  unknown: "L'action a échoué. Réessayez ; si le problème persiste, contactez le support.",
};

/** Code for an error raised by a boarding command (order matters: most specific first). */
export function commandErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("cut-off date is required")) return "cut_off_required";
  if (message.includes("cut-off date cannot be in the future")) return "cut_off_future";
  if (message.includes("roll it back and board the file again")) return "opening_plan_missing";
  if (message.includes("opening balances do not reconcile") || message.includes("without an opening plan"))
    return "opening_mismatch";
  if (message.includes("do not reconcile")) return "totals_mismatch";
  if (message.includes("reason is required")) return "reason_required";
  if (message.includes("CPCE R124-3")) return "mandate_missing";
  if (message.includes("same target")) return "duplicate_target";
  if (message.includes("another file with this name")) return "name_taken";
  if (message.includes("only be added to a draft batch") || message.includes("control totals can only change"))
    return "already_submitted";
  if (message.includes("unsupported file type")) return "unsupported_type";
  if (message.includes("not uploaded yet")) return "missing_upload";
  if (message.includes("expected") || message.includes("cannot be abandoned") || message.includes("only a committed"))
    return "state_changed";
  if (message.startsWith("ledger:")) return "ledger_rejected";
  return "unknown";
}

export function errorText(code: ErrorCode): string {
  return ERROR_TEXT[code] ?? ERROR_TEXT.unknown;
}

/** Result of a server action called from an ActionForm. */
export type ActionResult = { ok: true } | { error: ErrorCode };

/** Percentages in French notation: 0.925 -> "92,5 %". */
export function formatPct(ratio: number): string {
  return new Intl.NumberFormat("fr-FR", { style: "percent", maximumFractionDigits: 1 }).format(ratio);
}
