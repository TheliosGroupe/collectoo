import type { ErrorCode } from "@/lib/boarding/forms";
import { type Notification, notificationState } from "@/lib/payments/allocation";
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
  // M2c: lines booked in the funds (bank_line_booking.kind)
  fee: "Frais bancaires (à la charge du cabinet)",
  top_up: "Approvisionnement par le compte propre",
  loss: "Retour au-delà du paiement : perte du cabinet",
  // M2c-1 review: a credit from the own account released as a debtor's payment (public.release_own_credit); a
  // client's credit released the same way reads « … relayé par le client » (decisionLabel)
  relayed_payment: "Paiement d'un débiteur relayé par le cabinet",
  duplicate: "Doublon confirmé (non comptabilisé)",
  released: "Libéré",
};

/** What a line looks like before anyone decided (bank_transaction.kind and direction). */
export function lineKindLabel(kind: string, direction: string): string {
  if (kind === "return") return direction === "debit" ? "Retour d'un paiement reçu" : "Crédit annulant un débit";
  if (kind === "refund_out") return "Remboursement émis (référence RFD)";
  if (kind === "other_debit") return "Frais ou autre débit";
  if (kind === "transfer_out") return "Virement émis par le cabinet";
  if (kind === "own_transfer_in") return "Virement reçu du compte propre";
  if (kind === "client_transfer_in") return "Virement reçu d'un client";
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
  // review M2b-6: a line the posting refused is left to ops with its code
  payment_changed: "Le paiement a changé pendant l'analyse : nouvel essai automatique.",
  payment_returned:
    "Remboursement revenu alors que son paiement a été retourné par la banque : rien n'est comptabilisé, la façon de le comptabiliser reste à décider.",
  before_previous_return:
    "Ligne antérieure à un retour déjà comptabilisé sur ce paiement, à une date plus récente : elle ne peut pas être liée à sa date.",
  posting_failed: "La comptabilisation a été refusée pour cette ligne : liez-la à un autre paiement ou signalez-la au support.",
  refund_amount_match: "Débit du montant d'un remboursement demandé sur ce compte : s'il s'agit de ce remboursement, liez-le.",
  // M2c-1: our own transfers and credits
  top_up_not_found:
    "Crédit venant du compte propre sans approvisionnement demandé : approvisionnement du cabinet, ou paiement d'un débiteur reçu par le cabinet et relayé sur ce compte (il devient alors un paiement à affecter). Ne le classez avec une explication que s'il n'est ni l'un ni l'autre.",
  top_up_differs:
    "Crédit portant la référence d'un approvisionnement, mais d'un autre montant ou sur un autre compte : vérifiez dans la banque.",
  client_credit:
    "Virement reçu du compte de reversement d'un client : règlement d'une facture du cabinet (à classer, comptabilisé avec les factures à venir), ou paiement d'un débiteur que le client relaie (il devient alors un paiement à affecter).",
  own_transfer_out:
    "Virement émis par le cabinet (reversement ou balayage) : comptabilisé avec les reversements ; à classer avec une explication d'ici là.",
};

/**
 * Whether « À classer » offers the M2b links on a line — a payment's return (« Retour du paiement … ») and our refunds
 * (« Remboursement … »): only on the lines M2b reads as such, a debit read as a return, our refund or another debit, and
 * a credit undoing a debit. Our own transfers out and the credits from our own account or from a client (M2c-1 kinds)
 * never: the database refuses those links (« debit link refused: not_a_return »; review M2c-1).
 */
export function offersPaymentLinks(o: { direction: string; kind: string }): boolean {
  if (o.direction === "debit") return o.kind === "return" || o.kind === "refund_out" || o.kind === "other_debit";
  return o.direction === "credit" && o.kind === "return";
}

/**
 * Whether « Paiement d'un débiteur relayé par le cabinet » is offered (review M2c-1): a credit from the own account
 * (`own_transfer_in`) that does not carry our `TOP…` reference — a credit carrying it is our top-up, never a debtor's
 * payment. The database checks the rest (unbooked, unlinked, on a dedicated account).
 */
export function relayable(o: { direction: string; kind: string; end_to_end_id: string | null }): boolean {
  return o.direction === "credit" && o.kind === "own_transfer_in" && !/^TOP[0-9A-F]{12}$/.test(o.end_to_end_id ?? "");
}

/**
 * Review M2c-2: whether « Paiement d'un débiteur relayé par le client » is offered — a credit from a client's confirmed
 * payout IBAN (`client_transfer_in`), e.g. the client forwarding a debtor's payment it received. It is released by
 * public.release_own_credit as an own credit is; the database checks the rest (unbooked, unlinked, on a dedicated
 * account).
 */
export function clientRelayable(o: { direction: string; kind: string }): boolean {
  return o.direction === "credit" && o.kind === "client_transfer_in";
}

/** The button and sheet title of a relayed debtor payment, by who relays it. */
export const RELAY_LABEL = {
  servicer: "Paiement d'un débiteur relayé par le cabinet",
  client: "Paiement d'un débiteur relayé par le client",
} as const;

/** What a decided line became, in French: a relayed payment says who relayed it (review M2c-2). */
export function decisionLabel(decision: string, kind: string): string {
  if (decision === "relayed_payment" && kind === "client_transfer_in") return RELAY_LABEL.client;
  return LINK_KIND[decision] ?? decision;
}

/**
 * Whether a line may be classified without booking (« Classer sans comptabiliser »): never our refund leaving the
 * account, nor a return whose references name one of our payments (review M2b-6: money out for a payment is always
 * booked; the database refuses it too). A return naming nothing of ours (a fee's direct debit the bank rejected) may be.
 */
export function explainable(o: { direction: string; kind: string; namesPayment: boolean }): boolean {
  if (o.direction !== "debit") return true;
  if (o.kind === "refund_out") return false;
  return !(o.kind === "return" && o.namesPayment);
}

/**
 * What a return does, before ops confirm it (full or partial). A payment on no file has nothing imputed, no receipt
 * and no client to tell (review M2b-6): the sheet says only that the return is booked. On a file, the return undoes
 * whatever was imputed or remitted (a held payment had neither) and records a notification for the client, never
 * « informed » before it is delivered (CPCE-06).
 */
export function returnEffect(o: { amount: string; left: string; full: boolean; dateFr: string; hasFile: boolean }): string {
  const head = o.hasFile
    ? `La banque reprend ${o.amount} sur ce paiement. Ses imputations et reversements, s'il y en a, seront annulés au ${o.dateFr} (date du retour) : les factures retrouvent leur solde. Notification enregistrée pour le client (envoi : à venir).`
    : `La banque reprend ${o.amount} sur ce paiement, rattaché à aucun dossier : le retour est comptabilisé au ${o.dateFr} (date du retour), sans quittance ni information d'un client.`;
  if (!o.full) return `${head} Il restera ${o.left} du paiement, en attente de votre décision (réimputer ou rembourser).`;
  return o.hasFile ? `${head} Le paiement sera « retourné » et sa quittance annulée.` : `${head} Le paiement sera « retourné ».`;
}

/**
 * The note on a returned payment, from what the page loaded (review M2b-6): the allocations and forwards the return
 * reversed (its `bank_return` notifications), the receipt's latest version, and the return's own notification in the
 * words of « Information du client » (recorded, or delivered: never « informed » before it is). A payment on no file
 * had no receipt and no client to tell.
 */
export function returnedNote(
  o: {
    hasFile: boolean;
    notifications: Notification[];
    latestReceiptKind: string | null; // null: no receipt version
  },
  when: (iso: string) => string,
): string {
  const parts = ["La banque a repris ce paiement."];
  const byReturn = (kind: string) => o.notifications.some((n) => n.kind === kind && n.reason === "bank_return");
  if (byReturn("payment_allocation_reversed"))
    parts.push("Ses imputations sont annulées à la date du retour : les factures retrouvent leur solde.");
  if (byReturn("payment_forward_reversed")) parts.push("Son reversement au client est annulé à la date du retour.");
  if (!o.hasFile) {
    parts.push("Il n'est rattaché à aucun dossier : ni quittance, ni information d'un client.");
    return parts.join(" ");
  }
  if (o.latestReceiptKind === "void") parts.push("Sa quittance est annulée.");
  else if (o.latestReceiptKind !== null) parts.push("L'annulation de sa quittance est en cours.");
  const told = [...o.notifications].reverse().find((n) => n.kind === "payment_returned");
  if (told) parts.push(`Information du client : ${notificationState(told, when)}.`);
  return parts.join(" ");
}

/**
 * What linking a line to one of our refunds does. A debit that does not carry the refund's RFD id as its end-to-end
 * reference (the bank read it as a plain debit, `other_debit`: review M2b-6) is linked on ops' word: the sheet asks
 * them to check the transfer in the bank first.
 */
export function linkRefundEffect(o: { direction: string; lineRef: string | null; refundRef: string; payee: string }): string {
  if (o.direction !== "debit")
    return `Le virement ${o.refundRef} est revenu impayé : le remboursement sera annulé à la date du crédit, et le montant redeviendra disponible sur le paiement.`;
  if (o.lineRef === o.refundRef)
    return `Le débit est le virement ${o.refundRef} à ${o.payee} : le remboursement sera comptabilisé à la date du débit.`;
  return `Le débit ne porte pas la référence ${o.refundRef} : vérifiez dans la banque qu'il s'agit bien du virement à ${o.payee}. Le remboursement sera comptabilisé à la date du débit.`;
}

/** M2c-1: what booking a debit as a bank fee does (the servicer's cost, founder #9). */
export function feeEffect(amount: string): string {
  return `Le débit de ${amount} sera comptabilisé en frais bancaires du compte dédié, à la charge du cabinet : la part du cabinet sur ce compte diminue d'autant, à compenser par un approvisionnement depuis le compte propre. Aucun client n'en supporte le coût.`;
}

/** M2c-1: what booking a credit from the own account as a top-up does (the servicer's own money). */
export function ownCreditEffect(amount: string): string {
  return `Le crédit de ${amount} venant du compte propre sera comptabilisé comme un approvisionnement du compte dédié par le cabinet, avec son propre argent. S'il s'agit du paiement d'un débiteur reçu par le cabinet et relayé sur ce compte, choisissez plutôt « Paiement d'un débiteur relayé par le cabinet ».`;
}

/**
 * M2c-1 review: what releasing a credit from the own account as a debtor's payment does (public.release_own_credit).
 * A debtor paid the servicer's own account and the servicer relays the money to the dedicated account: the line
 * becomes a payment, booked on the dedicated account at the line's date as a released duplicate credit is, on no file
 * yet, so it waits in « Paiements à traiter » for ops to assign it. The motif is required and kept.
 */
export function relayedPaymentEffect(o: { amount: string; dateFr: string }): string {
  return `Le crédit de ${o.amount} deviendra un paiement reçu, comptabilisé sur le compte de fonds de tiers au ${o.dateFr} (date de la ligne), payeur « Versement relayé par le cabinet ». Il attendra dans « Paiements à traiter » d'être affecté au dossier du débiteur, puis sera imputé comme tout paiement. Le motif est conservé : indiquez qui a payé le cabinet, et quand. À ne pas utiliser pour un approvisionnement par le cabinet.`;
}

/**
 * Review M2c-2: what releasing a client's credit as a debtor's payment does (public.release_own_credit on a
 * `client_transfer_in` line): the same as for an own credit — a payment on no file yet, booked at the line's date, that
 * waits in « Paiements à traiter ». Not for the client paying one of our invoices, nor for a payment already declared on
 * the file as made to the client directly (it would be counted twice).
 */
export function clientRelayedPaymentEffect(o: { amount: string; dateFr: string }): string {
  return `Le crédit de ${o.amount} venant du compte de reversement d'un client deviendra un paiement reçu, comptabilisé sur le compte de fonds de tiers au ${o.dateFr} (date de la ligne), payeur « Versement relayé par le client ». Il attendra dans « Paiements à traiter » d'être affecté au dossier du débiteur, puis sera imputé comme tout paiement. Le motif est conservé : indiquez quel débiteur a payé le client, et quand. À ne pas utiliser pour le règlement d'une facture du cabinet par le client, ni pour un paiement déjà déclaré sur la fiche du dossier comme reçu directement par le client.`;
}

/**
 * M2c-1 (OQ-34, founder #8): a return larger than what is left of its payment. The payment's return of what is left
 * (its imputations undone at the return date, as any return) and the excess, the servicer's loss — never the client's
 * nor another client's.
 */
export function lossEffect(o: { amount: string; left: string; excess: string; dateFr: string; noneLeft: boolean }): string {
  const loss = `l'excédent de ${o.excess} sera une perte à la charge du cabinet, jamais du client ni d'un autre client (question ouverte OQ-34 : recours contre le payeur).`;
  if (o.noneLeft) return `La banque reprend ${o.amount} alors que rien ne reste du paiement : ${loss}`;
  return `La banque reprend ${o.amount}, plus que ce qui reste du paiement (${o.left}). Le retour de ${o.left} sera comptabilisé sur le paiement au ${o.dateFr} (ses imputations et reversements annulés à cette date) ; ${loss}`;
}

/**
 * What « Libérer » does to a CSV line held as a suspected duplicate (review M2b-6): the line becomes what the import
 * read it as (`private.held_line_kind`), and only a debtor's credit (or an unsplit batch) becomes a payment. A credit
 * read as a return (« RETOUR VIR SEPA … » in its label) books nothing and goes with the debits; a debit too. When the
 * page is not told the reading (`heldKind` null), a credit's sheet says both outcomes rather than promise a payment.
 */
export function releaseEffect(o: { direction: string; heldKind: string | null; amount: string }): string {
  const payment = `La ligne deviendra un paiement reçu de ${o.amount} : comptabilisé sur le compte de fonds de tiers à la date du relevé, puis rapproché d'un dossier.`;
  const debits =
    "La ligne sera traitée comme un retour ou un remboursement : rapprochée automatiquement si ses références le permettent, sinon listée dans « À classer ». Aucun paiement n'est créé.";
  switch (o.heldKind) {
    case "debtor_credit":
    case "batch_unsplit":
      return payment;
    case "return":
    case "refund_out":
      return debits;
    case "other_debit":
      return "La ligne sera classée avec les frais et autres débits, à comptabiliser en frais bancaires ou à expliquer.";
    case "own_transfer_in":
    case "client_transfer_in":
    case "transfer_out":
      return "La ligne sera classée dans « À classer » avec les virements du cabinet : aucun paiement n'est créé.";
  }
  return o.direction === "credit"
    ? `La ligne reprendra la lecture faite à l'import. Lue comme un paiement du débiteur, elle deviendra un paiement reçu de ${o.amount}, comptabilisé sur le compte de fonds de tiers à la date du relevé puis rapproché d'un dossier ; lue comme un retour (libellé « RETOUR … »), elle sera traitée avec les débits et retours, sans paiement.`
    : "La ligne sera classée comme un débit à traiter (retour, remboursement ou frais).";
}

/** Codes of the nightly checks (payment_check_result.code), in French. */
export const CHECK_LABEL: Record<string, { label: string; help: string }> = {
  client_money_identity: {
    label: "Fonds de tiers déséquilibrés",
    help: "Le solde du compte dédié ne vaut pas les fonds à affecter, plus les sommes dues aux clients, plus la part du cabinet (I8).",
  },
  bank_cash_identity: {
    label: "Compte bancaire : trésorerie ≠ paiements",
    help: "La trésorerie comptable du compte ne vaut pas ce que ses paiements ont apporté, moins ce qui est ressorti, plus ce que ses autres lignes comptabilisées ont fait entrer ou sortir (frais, approvisionnements).",
  },
  own_fund_identity: {
    label: "Fonds du cabinet déséquilibrés",
    help: "Les comptes du cabinet (compte propre, commissions, avances, TVA, frais, pertes) ne s'équilibrent pas.",
  },
  fund_mirror: {
    label: "Part du cabinet ≠ créance du cabinet",
    help: "La part du cabinet sur le compte dédié (4679) ne reflète plus sa créance sur ce compte (4689).",
  },
  client_payable_debit: {
    label: "Somme due à un client en débit",
    help: "Ce qui est dû à un client serait négatif : l'argent d'un autre client ou du cabinet l'aurait couvert (I13).",
  },
  // M2c-1 review: the servicer owes the dedicated account (fees, losses) beyond the top-ups ordered (design §15)
  servicer_shortfall: {
    label: "Approvisionnement du compte dédié à demander",
    help: "Le cabinet doit de l'argent au compte dédié (frais bancaires, pertes) au-delà des approvisionnements demandés : approvisionnez-le depuis le compte propre (« Comptes bancaires »).",
  },
  remittance_completeness: {
    label: "Encaissements à reverser incomplets",
    help: "Ce qui est dû à un client ne vaut pas la somme de ses encaissements en attente de reversement.",
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
    help: "Aucun débit rapproché : vérifiez le virement dans la banque et sa référence RFD (« référence de bout en bout ») ; un débit sans cette référence se lie depuis « Débits et retours ».",
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
  // the job failed after its retries (review M2b-6: a dead-lettered direct payment is refused, never left « En cours »)
  failed: "Le traitement a échoué après plusieurs essais : contactez le support",
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
  if (message.includes("reason is required") || message.includes("refused: reason_required")) return "reason_required";
  if (message.includes("the payment changed") || message.includes("payment_changed")) return "payment_changed";
  if (message.includes("reason does not match")) return "refund_reason_mismatch";
  if (message.includes("more than what is left")) return "refund_too_much";
  if (message.includes("IBAN is required")) return "refund_iban_required";
  if (message.includes("payee's name is required")) return "refund_name_required";
  if (message.includes("invalid IBAN")) return "iban_invalid";
  if (message.includes("cannot be refunded from here")) return "refund_not_possible";
  if (message.includes("no longer pending")) return "refund_not_pending";
  if (message.includes("a refund is pending") || message.includes("debit link refused: refund_pending"))
    return "refund_pending";
  if (message.includes("already_linked")) return "already_linked";
  if (message.includes("already_booked")) return "already_booked";
  if (message.includes("not_a_fee")) return "not_a_fee";
  if (message.includes("not_an_own_credit")) return "not_an_own_credit";
  if (message.includes("own credit release refused: not_own_credit")) return "not_own_credit";
  if (message.includes("own_account_unknown")) return "own_account_unknown";
  if (message.includes("transfer_not_pending") || message.includes("bank booking refused: amount_differs"))
    return "top_up_differs";
  if (message.includes("not_a_loss")) return "not_a_loss";
  if (message.includes("not_explainable")) return "not_explainable";
  if (message.includes("before_previous_return")) return "link_before_return";
  if (message.includes("payment_returned")) return "link_payment_returned";
  if (message.includes("posting_failed")) return "link_posting_failed";
  if (message.includes("amount_exceeds") || message.includes("amount_differs")) return "link_amount";
  if (message.includes("debit link refused")) return "link_refused";
  if (message.includes("bank booking refused") || message.includes("own credit release refused")) return "booking_refused";
  if (message.includes("already decided")) return "already_decided";
  if (message.includes("client's statement is required")) return "direct_evidence";
  if (message.includes("before the servicing started")) return "direct_date";
  if (message.includes("invoices of this file only")) return "direct_items";
  if (message.includes("the file is not open")) return "file_not_open";
  if (message.includes("invalid amount")) return "amount_invalid";
  if (message.includes("lock") || message.includes("canceling statement")) return "allocation_busy";
  return "unknown";
}
