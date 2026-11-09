import type { ErrorCode } from "@/lib/boarding/forms";
import type { Tone } from "@/lib/payments/statements";

/**
 * M2b-6: money leaving the client-funds account, on the back-office. Bank returns and chargebacks (the payment's
 * allocations reversed at the return date, founder #13), refunds to the payer (founder #8, #9, #11, #12), refunds that
 * come back, lines ops explain (fees: founder #20), CSV suspected duplicates, payments made to the client directly, and
 * the nightly checks. Pure helpers, unit-tested; amounts arrive as text (integer minor units) and never pass through a
 * JS number. Every action is a SQL command that checks again what the page showed.
 */

/** Why a refund is asked (refund_request.reason_code), with the payment reasons each one fits (the SQL checks it). */
export const REFUND_REASON: Record<string, { label: string; fits: (status: string, review: string | null) => boolean }> = {
  overpayment: {
    label: "Trop-perçu : restitué au payeur",
    fits: (_s, r) => r === "overpayment" || r === "nothing_due",
  },
  currency_mismatch: { label: "Devise différente de la créance", fits: (_s, r) => r === "currency_mismatch" },
  no_mandate: { label: "Lot annulé : paiement sans mandat", fits: (_s, r) => r === "no_mandate" },
  unidentified: {
    label: "Paiement non identifié",
    fits: (s, r) => s === "unmatched" && (r === "no_match" || r === "ambiguous"),
  },
  held_file: {
    label: "Dossier bloqué (surendettement, procédure collective)",
    fits: (_s, r) => r === "hold_blocks_allocation",
  },
  account_closed: { label: "Dossier clos", fits: (_s, r) => r === "account_closed" },
  partial_return: { label: "Reste d'un retour partiel", fits: (_s, r) => r === "partial_return" },
  other: { label: "Autre motif (précisez)", fits: () => true },
};

/** The reason codes that fit a payment, the most specific first ("other" last). */
export function refundReasons(status: string, review: string | null): string[] {
  return Object.keys(REFUND_REASON).filter((k) => REFUND_REASON[k].fits(status, review));
}

/** Whether « Rembourser » is offered: something is left, the payment does not wait for its allocation, no refund
 * is pending (one at a time). */
export function refundable(p: { status: string; review_reason: string | null }, unallocatedMinor: string): boolean {
  if (BigInt(unallocatedMinor) <= BigInt(0)) return false;
  return (
    p.status === "unmatched" ||
    ((p.status === "matched" || p.status === "partially_allocated") && p.review_reason !== null)
  );
}

export const REFUND_STATUS: Record<string, { label: string; tone: Tone }> = {
  requested: { label: "À exécuter dans la banque", tone: "action" },
  executed: { label: "Exécuté", tone: "ok" },
  cancelled: { label: "Annulé", tone: "neutral" },
  bounced: { label: "Revenu impayé", tone: "error" },
};

/** What a bank line linked to a payment is (bank_debit_link.kind), plus ops' decisions on duplicates. */
export const LINK_KIND: Record<string, string> = {
  return: "Retour du paiement par la banque",
  refund: "Remboursement exécuté",
  refund_returned: "Remboursement revenu impayé",
  explained: "Expliqué (non comptabilisé)",
  duplicate: "Doublon confirmé (non comptabilisé)",
  released: "Libéré",
};

/** What a line looks like before anyone decided (bank_transaction.kind and direction). */
export function lineKindLabel(kind: string, direction: string): string {
  if (kind === "return") return direction === "debit" ? "Retour d'un paiement reçu" : "Crédit annulant un débit";
  if (kind === "refund_out") return "Remboursement émis (référence RFD)";
  if (kind === "other_debit") return "Frais ou autre débit";
  if (kind === "suspected_duplicate") return "Doublon possible";
  return kind;
}

/** Why the debit job left a line to ops (bank_debit_review.reason). */
export const DEBIT_REVIEW: Record<string, string> = {
  no_candidate: "Aucun paiement ni remboursement ne porte ses références.",
  ambiguous: "Plusieurs paiements correspondent : choisissez.",
  amount_differs: "Le montant ne correspond pas à ce qui reste du paiement ou au remboursement demandé.",
  partial_return: "Retour partiel : à confirmer (le reste du paiement attendra votre décision).",
  refund_not_pending: "Le remboursement nommé n'est plus en attente.",
  already_returned: "Le paiement nommé est déjà retourné ou remboursé.",
  changed: "Le paiement a changé pendant l'analyse : nouvel essai automatique.",
};

/** What a return does, before ops confirm it (full or partial). */
export function returnEffect(o: { amount: string; left: string; full: boolean; dateFr: string }): string {
  const head = `La banque reprend ${o.amount} sur ce paiement. Ses imputations seront annulées au ${o.dateFr} (date du retour) : les factures retrouvent leur solde, et le client en sera informé.`;
  return o.full
    ? `${head} Le paiement sera « retourné » et sa quittance annulée.`
    : `${head} Il restera ${o.left} du paiement, en attente de votre décision (réimputer ou rembourser).`;
}

/** Codes of the nightly checks (payment_check_result.code), in French. */
export const CHECK_LABEL: Record<string, { label: string; help: string }> = {
  client_money_identity: {
    label: "Fonds de tiers déséquilibrés",
    help: "Le solde du compte dédié ne vaut pas les fonds à affecter plus les sommes dues aux clients (I8).",
  },
  bank_cash_identity: {
    label: "Compte bancaire : trésorerie ≠ paiements",
    help: "La trésorerie comptable du compte ne vaut pas ce que ses paiements ont apporté moins ce qui est ressorti.",
  },
  cash_in_statement: {
    label: "Encaissement d'un jour ≠ ses paiements",
    help: "L'encaissement comptabilisé pour un jour de relevé ne vaut pas la somme de ses paiements (I11).",
  },
  payment_position: {
    label: "État d'un paiement ≠ comptabilité",
    help: "Le statut du paiement ne correspond pas à ce que la comptabilité dit de lui (imputé, non imputé, restitué).",
  },
  payment_negative_allocation: {
    label: "Imputation négative",
    help: "Le montant net imputé d'un paiement sur un dossier est négatif.",
  },
  receivable_negative: {
    label: "Créance en dessous de zéro",
    help: "Une créance diminuée par un paiement ou un avoir est passée sous zéro (I6).",
  },
  item_negative: {
    label: "Facture en dessous de zéro",
    help: "Une facture payée vaut moins que zéro, toutes composantes confondues.",
  },
  owner_claim_mirror: {
    label: "Créances du propriétaire ≠ créances des débiteurs",
    help: "Par portefeuille et composante, la créance du propriétaire ne reflète plus celle des débiteurs.",
  },
  receipt_missing: { label: "Quittance manquante", help: "Un paiement rattaché à un dossier n'a pas de quittance." },
  receipt_numbers: { label: "Plusieurs numéros de quittance", help: "Un paiement a plusieurs numéros de quittance." },
  receipt_not_void: {
    label: "Quittance non annulée",
    help: "Un paiement retourné par la banque garde une quittance en vigueur.",
  },
  receipt_stale: {
    label: "Quittance d'un autre dossier",
    help: "La version en vigueur de la quittance ne porte pas sur le dossier du paiement.",
  },
  notification_missing: {
    label: "Information du client manquante",
    help: "Une imputation, un reversement, un retour ou un paiement retenu n'a pas sa notification (R124-5).",
  },
  statement_gap: {
    label: "Relevé manquant",
    help: "Le solde d'ouverture d'un relevé ne reprend pas le solde de clôture du relevé précédent.",
  },
  bank_balance_gap: {
    label: "Écart avec le solde bancaire",
    help: "Le solde de clôture du dernier relevé ne vaut pas la trésorerie comptable plus les lignes non comptabilisées.",
  },
  unmatched_ageing: {
    label: "Paiements sans dossier depuis 20 jours ou plus",
    help: "Fonds à identifier : à rapprocher ou à rembourser (reversement au client dans le mois, art. R124-6 CPCE).",
  },
  unallocated_ageing: {
    label: "Paiements non imputés depuis 20 jours ou plus",
    help: "Paiements rattachés à un dossier mais en attente d'une décision.",
  },
  refund_pending_ageing: {
    label: "Remboursements en attente depuis 5 jours ou plus",
    help: "Le débit n'apparaît sur aucun relevé : vérifiez le virement dans la banque.",
  },
  debit_unclassified: {
    label: "Débits à classer depuis 3 jours ou plus",
    help: "Retours et remboursements que la comptabilité attend.",
  },
  duplicate_unresolved: {
    label: "Doublons possibles non traités depuis 3 jours ou plus",
    help: "Lignes CSV retenues : à libérer ou à confirmer comme doublons.",
  },
  direct_payment_waiting: {
    label: "Paiements directs non traités",
    help: "Des paiements déclarés par le client attendent leur comptabilisation depuis plus d'une heure.",
  },
};

export function checkLabel(code: string): { label: string; help: string } {
  return CHECK_LABEL[code] ?? { label: code, help: "" };
}

/** Why a payment made to the client directly was refused (direct_payment.refusal_code). */
export const DIRECT_REFUSAL: Record<string, string> = {
  more_than_due: "Montant supérieur à ce que doit le dossier à cette date",
  nothing_due: "Rien n'est dû sur ces factures à cette date",
  before_servicing_start: "Date antérieure à la reprise du dossier",
  file_closed: "Dossier clos",
};

export const DIRECT_STATUS: Record<string, { label: string; tone: Tone }> = {
  requested: { label: "En cours", tone: "busy" },
  posted: { label: "Comptabilisé", tone: "ok" },
  refused: { label: "Refusé", tone: "error" },
};

/** Integer minor units (text) as an amount field shows it: « 1234,50 » (2 decimals, no grouping). */
export function minorToInput(minor: string): string {
  if (!/^\d+$/.test(minor)) return "";
  const padded = minor.padStart(3, "0");
  return `${padded.slice(0, -2).replace(/^0+(?=\d)/, "")},${padded.slice(-2)}`;
}

/** A French IBAN as typed (spaces, lower case) to the form the commands take; null if empty. */
export function normaliseIban(text: string): string | null {
  const v = text.replace(/[\s ]/g, "").toUpperCase();
  return v === "" ? null : v;
}

/** Errors of the M2b-6 commands, as codes (order matters: most specific first). */
export function debitErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("reason is required")) return "reason_required";
  if (message.includes("the payment changed") || message.includes("payment_changed")) return "payment_changed";
  if (message.includes("reason does not match")) return "refund_reason_mismatch";
  if (message.includes("more than what is left")) return "refund_too_much";
  if (message.includes("IBAN is required")) return "refund_iban_required";
  if (message.includes("invalid IBAN")) return "iban_invalid";
  if (message.includes("cannot be refunded from here")) return "refund_not_possible";
  if (message.includes("no longer pending")) return "refund_not_pending";
  if (message.includes("a refund is pending") || message.includes("debit link refused: refund_pending"))
    return "refund_pending";
  if (message.includes("already_linked")) return "already_linked";
  if (message.includes("amount_exceeds") || message.includes("amount_differs")) return "link_amount";
  if (message.includes("debit link refused")) return "link_refused";
  if (message.includes("already decided")) return "already_decided";
  if (message.includes("client's statement is required")) return "direct_evidence";
  if (message.includes("before the servicing started")) return "direct_date";
  if (message.includes("invoices of this file only")) return "direct_items";
  if (message.includes("the file is not open")) return "file_not_open";
  if (message.includes("invalid amount")) return "amount_invalid";
  if (message.includes("lock") || message.includes("canceling statement")) return "allocation_busy";
  return "unknown";
}
