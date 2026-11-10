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
  | "none_selected"
  | "allocation_changed"
  | "payment_changed"
  | "amount_changed"
  | "proposal_changed"
  | "authorisation_required"
  | "request_required"
  | "not_same_debtor"
  | "not_forwardable"
  | "allocation_busy"
  | "already_reversed"
  | "file_held"
  | "refund_reason_mismatch"
  | "refund_too_much"
  | "refund_iban_required"
  | "refund_name_required"
  | "refund_not_possible"
  | "refund_not_pending"
  | "refund_pending"
  | "already_linked"
  | "link_amount"
  | "link_refused"
  | "not_explainable"
  | "link_before_return"
  | "link_payment_returned"
  | "link_posting_failed"
  | "already_decided"
  | "direct_evidence"
  | "direct_date"
  | "direct_items"
  | "file_not_open"
  | "amount_invalid"
  | "client_funds_exists"
  | "transfers_in_flight"
  | "top_up_accounts"
  | "top_up_not_pending"
  | "date_past"
  | "already_booked"
  | "not_a_fee"
  | "not_an_own_credit"
  | "not_own_credit"
  | "own_account_unknown"
  | "top_up_differs"
  | "not_a_loss"
  | "booking_refused"
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
  iban_taken:
    "Cet IBAN est déjà enregistré : dans cette devise, ou pour un autre usage (un IBAN est soit un compte de fonds de tiers, soit le compte propre du cabinet).",
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
  none_selected: "Cochez au moins un paiement.",
  allocation_changed: "L'imputation de ce paiement a changé entre-temps : rechargez la page.",
  payment_changed: "Ce paiement a changé entre-temps : rechargez la page.",
  amount_changed: "Le montant restant de ce paiement a changé entre-temps : rechargez la page.",
  proposal_changed: "La proposition d'avoir a changé entre-temps : rechargez la page.",
  authorisation_required: "Choisissez l'autorisation du juge, classée dans ce dossier.",
  request_required: "Choisissez la demande écrite du débiteur, classée dans l'un des deux dossiers.",
  not_same_debtor: "L'autre dossier doit être un dossier ouvert du même débiteur, chez le même client.",
  not_forwardable:
    "Ce paiement ne peut pas être reversé au client : seul un paiement sans imputation, sur un dossier rappelé ou antérieur à l'arrêté, peut l'être.",
  allocation_busy: "Une imputation est en cours pour ce servicer : réessayez dans un instant.",
  already_reversed: "Cette imputation a déjà été annulée entre-temps : rechargez la page.",
  file_held:
    "Le dossier est bloqué (surendettement ou procédure collective) : ni reversement au client ni compensation tant que le blocage est en place. Rechargez la page.",
  refund_reason_mismatch: "Ce motif de remboursement ne correspond pas à la situation du paiement : rechargez la page.",
  refund_too_much: "Le montant dépasse ce qui reste du paiement.",
  refund_iban_required: "La banque n'a pas transmis l'IBAN du payeur : saisissez l'IBAN du bénéficiaire.",
  refund_name_required:
    "La banque n'a pas transmis le nom du payeur : saisissez le nom du bénéficiaire (140 caractères au plus).",
  refund_not_possible:
    "Ce paiement ne peut pas être remboursé depuis ici (il attend son imputation, ou un remboursement est déjà demandé). Rechargez la page.",
  refund_not_pending: "Ce remboursement n'est plus en attente : rechargez la page.",
  refund_pending: "Un remboursement est demandé pour ce paiement : annulez-le d'abord.",
  already_linked: "Cette ligne a déjà été traitée : rechargez la page.",
  link_amount:
    "Le montant ne convient pas : il dépasse ce qui reste du paiement, ou n'est pas celui du remboursement demandé.",
  link_refused:
    "Ce rapprochement n'est pas possible pour cette ligne (sens, compte bancaire, date ou état) : vérifiez la ligne et rechargez la page.",
  not_explainable:
    "Ce retour nomme l'un de nos paiements (ou c'est notre remboursement) : il ne se classe pas sans comptabiliser, liez-le au paiement concerné.",
  link_before_return:
    "Cette ligne est antérieure à un retour déjà comptabilisé sur ce paiement : elle ne peut pas être liée à sa date.",
  link_payment_returned:
    "Le paiement de ce remboursement a été retourné par la banque : ce montant revenu ne peut pas encore être comptabilisé.",
  link_posting_failed: "La comptabilisation a été refusée pour cette ligne : vérifiez-la ou signalez-la au support.",
  already_decided: "Cette ligne a déjà été traitée : rechargez la page.",
  direct_evidence: "Choisissez le relevé du client, classé dans ce dossier.",
  direct_date: "La date doit être passée, et postérieure à la reprise du dossier.",
  direct_items: "Les factures désignées doivent appartenir à ce dossier.",
  file_not_open: "Le dossier n'est pas ouvert.",
  amount_invalid: "Montant invalide : saisissez un montant positif en euros (ex. 120,50).",
  client_funds_exists:
    "Un compte de fonds de tiers est déjà actif dans cette devise : le cabinet a choisi un seul compte dédié par devise pour recevoir et reverser les fonds des clients.",
  transfers_in_flight:
    "Un virement depuis ou vers ce compte est en cours (approvisionnement non encore crédité) : annulez-le ou attendez son crédit.",
  top_up_accounts:
    "L'approvisionnement part d'un compte propre actif vers le compte de fonds de tiers actif de la même devise.",
  top_up_not_pending: "Cet approvisionnement n'est plus en attente : rechargez la page.",
  date_past: "La date d'exécution demandée ne peut pas être passée.",
  already_booked: "Cette ligne est déjà comptabilisée : rechargez la page.",
  not_a_fee:
    "Seul un débit classé « Frais ou autre débit » se comptabilise en frais bancaires : un virement émis par le cabinet n'en est pas un.",
  not_an_own_credit: "Seul un crédit reçu du compte propre du cabinet se comptabilise en approvisionnement.",
  not_own_credit:
    "Seul un crédit reçu du compte propre du cabinet, ni comptabilisé ni classé, peut devenir le paiement d'un débiteur : rechargez la page.",
  own_account_unknown:
    "Ce crédit ne vient d'aucun compte propre enregistré : enregistrez le compte propre, ou classez la ligne avec une explication.",
  top_up_differs:
    "Ce crédit porte la référence d'un approvisionnement d'un autre montant ou d'un autre compte : annulez l'approvisionnement demandé, puis comptabilisez le crédit.",
  not_a_loss: "Ce retour ne dépasse pas ce qui reste du paiement : liez-le au paiement (retour total ou partiel).",
  booking_refused: "Cette comptabilisation n'est pas possible pour cette ligne : vérifiez-la et rechargez la page.",
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
