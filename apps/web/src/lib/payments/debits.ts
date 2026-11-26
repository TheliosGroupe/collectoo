import {
  type ErrorCode,
  FILE_BOOKED_WHEN,
  REFUND_BOOKED_WHEN,
  REFUND_NOT_EXECUTED,
  REFUND_NOT_EXECUTED_ON,
  REFUND_RETURNED,
} from "@/lib/boarding/forms";
import {
  type Notification,
  notificationState,
} from "@/lib/payments/allocation";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { type Tone, money } from "@/lib/payments/statements";
import {
  claimsToDeclareHelp,
  payoutAfterLiquidationHelp,
  postOpeningUnpaidHelp,
} from "@/lib/remittance/declarations";

/**
 * M2b-6: money leaving the client-funds account, on the back-office. Bank returns and chargebacks (the payment's
 * allocations reversed at the return date, founder #13), refunds to the payer (founder #8, #9, #11, #12), refunds that
 * come back, lines ops explain (fees: founder #20), CSV suspected duplicates, payments made to the client directly, and
 * the nightly checks. Pure helpers, unit-tested; amounts arrive as text (integer minor units) and never pass through a
 * JS number. Every action is a SQL command that checks again what the page showed.
 */

/** Why a refund is asked (refund_request.reason_code), with the payment reasons each one fits (the SQL checks it). */
export const REFUND_REASON: Record<
  string,
  { label: string; fits: (status: string, review: string | null) => boolean }
> = {
  overpayment: {
    label: "Trop-perçu : restitué au payeur",
    fits: (_s, r) => r === "overpayment" || r === "nothing_due",
  },
  currency_mismatch: {
    label: "Devise différente de la créance",
    fits: (_s, r) => r === "currency_mismatch",
  },
  no_mandate: {
    label: "Lot annulé : paiement sans mandat",
    fits: (_s, r) => r === "no_mandate",
  },
  unidentified: {
    label: "Paiement non identifié",
    fits: (s, r) =>
      s === "unmatched" && (r === "no_match" || r === "ambiguous"),
  },
  held_file: {
    label: "Dossier bloqué (surendettement, procédure collective)",
    fits: (_s, r) => r === "hold_blocks_allocation",
  },
  account_closed: {
    label: "Dossier clos",
    fits: (_s, r) => r === "account_closed",
  },
  partial_return: {
    label: "Reste d'un retour partiel",
    fits: (_s, r) => r === "partial_return",
  },
  other: { label: "Autre motif (précisez)", fits: () => true },
};

/** The reason codes that fit a payment, the most specific first ("other" last). */
export function refundReasons(status: string, review: string | null): string[] {
  return Object.keys(REFUND_REASON).filter((k) =>
    REFUND_REASON[k].fits(status, review),
  );
}

/** Whether « Rembourser » is offered: something is left, the payment does not wait for its allocation, no refund
 * is pending (one at a time). */
export function refundable(
  p: { status: string; review_reason: string | null },
  unallocatedMinor: string,
): boolean {
  if (BigInt(unallocatedMinor) <= BigInt(0)) return false;
  return (
    p.status === "unmatched" ||
    ((p.status === "matched" || p.status === "partially_allocated") &&
      p.review_reason !== null)
  );
}

export const REFUND_STATUS: Record<string, { label: string; tone: Tone }> = {
  requested: { label: "À exécuter dans la banque", tone: "action" },
  // M2c-6a: a refund in the transfer file (execution_mode 'file'): never executed by hand
  requested_file: { label: "Dans le fichier de virements", tone: "action" },
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
  if (kind === "return")
    return direction === "debit"
      ? "Retour d'un paiement reçu"
      : "Crédit annulant un débit";
  if (kind === "refund_out") return "Remboursement émis (référence RFD)";
  if (kind === "other_debit") return "Frais ou autre débit";
  if (kind === "transfer_out") return "Virement émis par le cabinet";
  if (kind === "own_transfer_in") return "Virement reçu du compte propre";
  if (kind === "client_transfer_in") return "Virement reçu d'un client";
  if (kind === "suspected_duplicate") return "Doublon possible";
  // review M2c-6b-2d round 1 (pages-e2e-2): an entry the bank kept unsplit, never its code (« Relevés » words the
  // credit so: statements.ts)
  if (kind === "batch_unsplit")
    return direction === "debit" ? "Écriture groupée de la banque (non ventilée)" : "Remise groupée non ventilée";
  return kind;
}

/** Why the debit job left a line to ops (bank_debit_review.reason). */
export const DEBIT_REVIEW: Record<string, string> = {
  no_candidate: "Aucun paiement ni remboursement ne porte ses références.",
  ambiguous: "Plusieurs paiements correspondent : choisissez.",
  amount_differs:
    "Le montant ne correspond pas à ce qui reste du paiement ou au remboursement demandé.",
  partial_return:
    "Retour partiel : à confirmer (le reste du paiement attendra votre décision).",
  refund_not_pending: "Le remboursement nommé n'est plus en attente.",
  already_returned: "Le paiement nommé est déjà retourné ou remboursé.",
  changed: "Le paiement a changé pendant l'analyse : nouvel essai automatique.",
  // review M2b-6: a line the posting refused is left to ops with its code
  payment_changed:
    "Le paiement a changé pendant l'analyse : nouvel essai automatique.",
  payment_returned:
    "Remboursement revenu alors que son paiement a été retourné par la banque : rien n'est comptabilisé, la façon de le comptabiliser reste à décider.",
  before_previous_return:
    "Ligne antérieure à un retour déjà comptabilisé sur ce paiement, à une date plus récente : elle ne peut pas être liée à sa date.",
  posting_failed:
    "La comptabilisation a été refusée pour cette ligne : liez-la à un autre paiement ou signalez-la au support.",
  refund_amount_match:
    "Débit du montant d'un remboursement demandé sur ce compte : s'il s'agit de ce remboursement, liez-le.",
  // M2c-1: our own transfers and credits
  top_up_not_found:
    "Crédit venant du compte propre sans approvisionnement demandé : approvisionnement du cabinet, ou paiement d'un débiteur reçu par le cabinet et relayé sur ce compte (il devient alors un paiement à affecter). Ne le classez avec une explication que s'il n'est ni l'un ni l'autre.",
  top_up_differs:
    "Crédit portant la référence d'un approvisionnement, mais d'un autre montant ou sur un autre compte : vérifiez dans la banque.",
  // M2c-7e-1 ([critic] M7-MONEY-4): its one exit, « Comptabiliser comme approvisionnement » (no transfer)
  // (review round 1, TUI-2: booked, it pays what the servicer owes — the hour's re-order is then beyond it)
  top_up_cancelled_credit:
    "Approvisionnement annulé puis exécuté par la banque : c'est l'argent du cabinet. Comptabilisez-le comme approvisionnement : il règle ce que le cabinet doit au compte dédié. Si Collectoo a recommandé cet approvisionnement entre-temps, annulez la nouvelle commande (« Virements », « Annuler ») si elle n'est pas exécutée ; sinon le surplus revient au cabinet avec la prochaine quote-part.",
  // M2c-7c-1 (plan §5.5): « Règlement d'une facture ou d'une avance du cabinet » books it
  client_credit:
    "Virement reçu du compte de reversement d'un client : règlement d'une facture ou d'une avance du cabinet (« Règlement du client »), ou paiement d'un débiteur que le client relaie (il devient alors un paiement à affecter).",
  // M2c-6b-2c (plan §4.3): the screen books it
  // review 6b-2c (pages-4): a sweep of its amount in flight is booked as that sweep's debit (the sheet's « Débit de la
  // quote-part du cabinet »; the command refuses « Virement au compte propre » then: sweep_in_flight_matches)
  own_transfer_out:
    "Virement émis vers l'un de nos comptes sans ordre de Collectoo : après vérification dans la banque, comptabilisez-le avec « Comptabiliser… » (débit de la quote-part du cabinet en cours de ce montant s'il y en a une, sinon « Virement au compte propre »).",
  // M2c-6b-1 (plan §2.3): our payouts' and sweeps' debits and returns the job does not book
  // M2c-6b-2c (plan §4.3): the screen books them as « Virement hors reversement » (a cancelled transfer whose run is still
  // in flight: CANCELLED_TRANSFER_LIVE_RUN, critic2 ML-4)
  // M2c-6b-3a-2 (T14): kind-aware, both ways — a payout's (its run in flight: its payout, the late predecessor;
  // CANCELLED_TRANSFER_LIVE_RUN), a sweep's (CANCELLED_SWEEP_DEBITED), a refund's (CANCELLED_REFUND_DEBITED)
  cancelled_transfer_debited:
    "Débit d'un virement annulé dans Collectoo : la banque l'a exécuté. Rien n'est comptabilisé : vérifiez dans la banque, puis comptabilisez-le avec « Comptabiliser… » : comme le débit de son reversement s'il est encore en cours, sinon comme « Virement hors reversement » (risque de double paiement).",
  transfer_debited_twice:
    "Second débit d'un virement déjà comptabilisé : la banque l'a peut-être exécuté deux fois. Vérifiez avec la banque, puis comptabilisez ce second débit comme « Virement hors reversement ».",
  transfer_not_handed_out:
    "Débit d'un virement dont le fichier n'a jamais été téléchargé : rien n'est comptabilisé ; vérifiez dans la banque d'où vient cet ordre.",
  transfer_unknown:
    "Débit portant une référence de virement du cabinet (RMT, SWP) ou un lot que Collectoo ne connaît pas : rien n'est comptabilisé ; vérifiez dans la banque.",
  transfer_differs:
    "Débit d'un virement du cabinet, mais d'un autre montant ou sur un autre compte : si la banque a prélevé ses frais sur la même ligne, comptabilisez-la comme « Débit d'un reversement » et frais ; sinon, vérifiez dans la banque.",
  run_not_in_flight:
    "Débit d'un reversement dont le reversement n'est plus en cours dans Collectoo : rien n'est comptabilisé ; vérifiez dans la banque.",
  batch_partial:
    "Lot débité pour un autre montant que ses virements en cours (un virement manque, a été rejeté, ou un virement déjà débité l'a été de nouveau) : « Débit d'un lot » le comptabilise si une seule combinaison de ses virements fait ce montant ; sinon, demandez le détail à la banque.",
  batch_mixed:
    "Lot mêlant des virements de natures différentes : rien n'est comptabilisé ; demandez à la banque le détail du lot.",
  // review round 4 (N1): also a second return of a transfer already returned (the job's `return_differs` either way);
  // review round 6 (R1): and a return read from a camt.053 entry the bank kept unsplit (its total, not this transfer's
  // return: less than it, with another movement in the batch, or several of our transfers in it)
  return_differs:
    "Retour d'un virement du cabinet pour plus que son montant, d'un virement déjà revenu, ou dans un lot de la banque qui ne se détaille pas (son total n'est pas exactement le montant de ce seul virement) : rien n'est comptabilisé ; vérifiez dans la banque.",
  // review M2c-6b-1 (T4, K5): also a return dated before its debit (the ledger never dates a reversal before its entry)
  return_before_debit:
    "Retour d'un virement du cabinet sans débit comptabilisé avant lui. Si le débit n'est pas encore comptabilisé, le retour est repris automatiquement à l'import d'un relevé, une fois le débit comptabilisé. S'il est daté d'avant le débit, rien n'est comptabilisé : vérifiez les deux lignes dans la banque et prévenez le support.",
  // M2c-6b-2a (plan §2.6; critic2 CSO2-14, ML-3): the job's two returns it never books — M2c-6b-2c (plan §4.3) rewords
  // both with « Virement revenu », the screen that books them
  unplanned_payout_return:
    "Retour d'un virement du cabinet (reversement ou quote-part) qui a aussi été exécuté hors de son ordre (virement annulé exécuté quand même, ou exécuté deux fois) : rien n'est comptabilisé automatiquement. Comptabilisez-le avec « Virement revenu » : c'est le retour du virement exécuté hors ordre.",
  // review M2c-6b-2a (M1): that debit may be a copy held in « Doublons possibles » (private.transfer_late_lines counts a
  // held line, never one decided a duplicate; public.resolve_duplicate then queues the debit job)
  return_debit_pending:
    "Retour d'un virement du cabinet dont un autre débit, ou celui d'un autre virement du même reversement (second débit, ou débit après annulation), figure sur un relevé sans être encore comptabilisé : rien n'est comptabilisé automatiquement. Si ce débit attend dans « Doublons possibles », décidez-le d'abord : reconnu comme doublon, il ne compte plus et le retour est repris automatiquement. Comptabilisez d'abord ce débit (« Virement hors reversement ») ; ce retour se comptabilisera ensuite avec « Virement revenu ».",
  // M2c-6b-2a (S20, OQ-84 (i)): the M2b pass's own reason — a link it decided, refused because the line is ours; review
  // M2c-6b-2a (T6): no screen promised while none books these lines
  own_transfer_line:
    "Ligne de l'un de nos propres virements (reversement, quote-part du cabinet, lot de nos fichiers) : elle ne se rattache à aucun paiement ni remboursement, et rien n'est comptabilisé automatiquement. Collectoo ne peut pas encore la comptabiliser depuis cet écran : prévenez le support.",
  // M2c-6b-2c (plan §4.1; critic2 CSO2-13): « À classer »'s own reasons for a debit without our reference, found from the
  // line by rule 3b's keyed probe (public.debit_queue) — it is booked with « Comptabiliser… », never a fee nor explained
  // review 6b-2c round 3: a candidate in flight among them (a payout, a sweep or a refund in a file handed out); with
  // only payouts returned or cancelled, debitReviewText words it PAYOUT_AMOUNT_MATCH_ENDED
  payout_amount_match:
    "Débit sans notre référence du montant d'un virement du cabinet en cours (ou d'un reversement annulé ou revenu que la banque a pu exécuter) : s'il s'agit de ce virement, comptabilisez-le comme son débit avec « Comptabiliser… ».",
  client_payout_iban:
    "Débit vers le compte de reversement d'un client, sans référence du cabinet : virement hors reversement (ou débit d'un reversement en cours sans sa référence).",
};

/**
 * Review 6b-2c (cs-1): « Débits et retours » when the database could not read the tab (its time limit, or another
 * error) — never « Aucune ligne » with a count of 0, which would hide the lines waiting.
 */
export const QUEUE_UNREAD =
  "Cette liste n'a pas pu être lue pour l'instant (délai dépassé ou erreur) : actualisez la page dans un instant ; si cela se répète, prévenez le support.";

/**
 * Review 6b-2c round 3 (other-debit-return-blocked-by-returned-payout-twin): « À classer »'s payout_amount_match when
 * every candidate is a payout returned, or cancelled with its run ended (rule 3b's (iii)) — never « en cours »; and, when
 * public.debit_link_options says « Lier » takes a payment's return there (return_guard null), that the line may also be
 * a debtor's payment the bank takes back without flagging it.
 */
export const PAYOUT_AMOUNT_MATCH_ENDED =
  "Débit sans notre référence du montant d'un reversement annulé ou revenu dont la banque a reçu le fichier : s'il s'agit de ce virement, exécuté par la banque malgré son annulation ou de nouveau après son retour, comptabilisez-le avec « Comptabiliser… ».";
export const PAYOUT_AMOUNT_MATCH_RETURN =
  "Ce peut aussi être le paiement d'un débiteur que sa banque reprend sans que le relevé le signale comme un retour (chèque impayé, contre-passation) : après vérification dans la banque, liez-le à ce paiement avec « Retour du paiement … ».";

/**
 * M2c-6b-3a (K): a debit without our reference whose only candidate is a sweep cancelled out of a downloaded file
 * (« Comptabiliser… » proposes it as that sweep's late debit), or a refund cancelled so (nothing to book yet: S25).
 */
export const CANCELLED_SWEEP_MATCH =
  "Débit sans notre référence du montant d'une quote-part du cabinet annulée après téléchargement : la banque l'a peut-être exécutée en retard. Après vérification dans la banque, comptabilisez-le comme le débit de cette quote-part (« Comptabiliser… », puis « Virement au compte propre » de cette quote-part) : aucune nouvelle quote-part n'est virée d'ici là.";
export const CANCELLED_REFUND_MATCH =
  "Débit sans notre référence du montant d'un remboursement (ou d'une quote-part) annulé après téléchargement : la banque l'a peut-être exécuté en retard. Il ne peut pas encore être comptabilisé ; ne refaites pas ce remboursement, demandez à la banque le détail de ce débit et prévenez le support.";
/** Review round 1 (pages-texts-9): only cancelled sweeps, several of them — the line cannot be told apart. */
export const CANCELLED_SWEEPS_MATCH =
  "Débit sans notre référence du montant de plusieurs quotes-parts du cabinet annulées après téléchargement : la banque a peut-être exécuté l'une d'elles en retard, sans qu'on sache laquelle. Il ne peut pas être comptabilisé tel quel ; demandez à la banque le détail de ce débit : aucune nouvelle quote-part n'est virée d'ici là.";
/**
 * Review round 1 (pages-texts-2): a sweep's own late debit (its SWP id, or the job's review naming a cancelled sweep) —
 * « Comptabiliser… » proposes it as that sweep's, never « Virement hors reversement ».
 */
export const CANCELLED_SWEEP_DEBITED =
  "Débit d'une quote-part du cabinet annulée dans Collectoo : la banque l'a exécutée en retard. Rien n'est comptabilisé : vérifiez dans la banque, puis comptabilisez-le comme le débit de cette quote-part (« Comptabiliser… », puis « Virement au compte propre » de cette quote-part) ; aucune nouvelle quote-part n'est virée d'ici là.";
/**
 * Review round 1 (pages-texts-4): a debit without our reference at a requested refund's amount that « Lier » does not
 * offer — another transfer of ours of that amount may be that debit: one in flight (link_debit_guard's payout_candidate,
 * the switch off or on) or, once cancellation after download is on, one cancelled after download (H-PAY, review round 1).
 */
export const REFUND_AMOUNT_MATCH_BARRED =
  "Débit sans notre référence du montant d'un remboursement demandé, mais un autre virement du cabinet de ce montant — en cours, ou annulé après téléchargement et peut-être exécuté en retard — peut être ce débit : il ne peut pas être lié à ce remboursement. Attendez la ligne portant sa référence RFD ou celle de son lot (relevé camt.053) ; sinon demandez à la banque le détail de ce débit et prévenez le support.";

/**
 * critic2 ML-4: a cancelled transfer whose run is still approved or sent — this debit is that run's payout. M2c-6b-3a-2
 * (E, T13): « Comptabiliser… » books it as its run's payout (the late predecessor; what it does to the re-issue, the
 * sheet says by case); hedged — a line without our reference may be another debit.
 */
export const CANCELLED_TRANSFER_LIVE_RUN =
  "Débit d'un virement annulé dans Collectoo : la banque l'a peut-être exécuté en retard. Son reversement est toujours en cours : si ce débit est bien ce virement (vérifiez-le auprès de la banque quand la ligne ne porte pas sa référence), comptabilisez-le avec « Comptabiliser… » comme « Débit d'un reversement » : le reversement est comptabilisé comme payé. Si son virement de remplacement est déjà dans un fichier téléchargé, « Comptabiliser… » dit d'abord quoi faire de ce fichier.";
/** M2c-6b-3a-2 (T14): a refund's late debit after its cancellation — no booking kind for it yet (S25, OQ-81 (b)). */
export const CANCELLED_REFUND_DEBITED =
  "Débit d'un remboursement annulé : il ne peut pas encore être comptabilisé ; ne refaites pas ce remboursement, voyez avec la banque et prévenez le support.";

/** The reasons that may mean money left twice or without an order (P0, first in « À classer »; plan §2.3). */
export const P0_DEBIT_REVIEWS = new Set([
  "cancelled_transfer_debited",
  "transfer_debited_twice",
  "transfer_not_handed_out",
  "transfer_unknown",
]);

/** « À classer » order: the P0 reasons first, then the others as the database lists them. */
export function debitReviewRank(reason: string | null): number {
  return reason !== null && P0_DEBIT_REVIEWS.has(reason) ? 0 : 1;
}

/** Our payouts' and sweeps' end-to-end ids, and our files' PmtInfIds (as the worker writes them). */
const OUR_TRANSFER_ID = /^(RMT|SWP)[0-9A-F]{12}$/;
const OUR_PMT_INF = /^TF-[0-9]{4}-[0-9]{6,}-[0-9]+$/;

/**
 * M2c-6b-1 (plan §2.4 rule 5; review money-1, K1): a line of our payouts or sweeps, as the database reads it — a line
 * whose own end-to-end id, or original one, is our RMT/SWP id (whatever its direction and the kind the statement gives
 * it: a debit of our payout or sweep, the payee's bank's return credit of one, a debit « return » naming one; review
 * round 2, L4, as private.post_debit_links reads it), and a debit with no end-to-end id carrying one of our files'
 * PmtInfIds (a batch line: the database also checks the PmtInf is one of that account's files). Such a line is only ever
 * booked from the statement (the debit job, or ops in M2c-6b-2): never a payment's return or its loss, a refund, a
 * refund come back or an explanation — the database refuses each (`own_transfer_line`), but on our batch line the
 * refunds of that PmtInf handed out to the bank (offersOwnBatchRefunds).
 */
export function isOurTransferLine(o: {
  direction: string;
  kind: string;
  end_to_end_id?: string | null;
  original_end_to_end_id?: string | null;
  payment_info_id?: string | null;
}): boolean {
  return (
    OUR_TRANSFER_ID.test(o.end_to_end_id ?? "") ||
    OUR_TRANSFER_ID.test(o.original_end_to_end_id ?? "") ||
    (o.direction === "debit" && !o.end_to_end_id && OUR_PMT_INF.test(o.payment_info_id ?? ""))
  );
}

/**
 * M2c-6b-1 (review money-1, K1 as the database implements it): the one link a batch line of one of our files takes — a
 * debit with no end-to-end id carrying one of our PmtInfIds. A refund whose transfer is in a file handed out to the
 * bank (downloaded or sent) is linked there: private.refund_transfer_follow (M2c-6a round 6, G2) executes it only by a
 * batch line of its own PmtInf in that file (`reissue_in_downloaded_file` otherwise), as ops did from this page in
 * M2c-6a (a refunds PmtInf's line of one refund's amount); a manual refund, or one whose transfer is not handed out, is
 * refused (`own_transfer_line`). So « À classer » offers such a line the refunds of its amount (« Remboursement … ») and
 * nothing else — never a payment's return, its loss or an explanation (a PmtInf of one refund alone is linked by the
 * job's M2b pass).
 */
export function offersOwnBatchRefunds(o: {
  direction: string;
  end_to_end_id?: string | null;
  payment_info_id?: string | null;
  unsplit_ours?: number | null;
}): boolean {
  return (
    o.direction === "debit" &&
    !o.end_to_end_id &&
    OUR_PMT_INF.test(o.payment_info_id ?? "") &&
    !holdsOursUnsplit(o)
  );
}

/**
 * Review M2c-6b-1 round 7 (S2, verdict new:debit-entry-unsplit-with-our-details-explainable): a line read from a
 * camt.053 entry the bank kept unsplit holding a detail of ours (`unsplit_ours` > 0 on the row « À classer » loads,
 * the parser's count — since round 8, T2, of every id we issue: our payouts', sweeps', refunds' and top-ups'), whatever
 * its direction — the entry's total, not one transaction's (our payout's return netted into an outgoing debit, our
 * debits in one entry, our payout's debit beside a debtor's credit). It takes no link of any kind and no explanation
 * (private.post_debit_links, the top-up, the relay: own_transfer_line), is never booked automatically and waits for the
 * team's booking (M2c-6b-2; COMPLIANCE OQ-84 (h)): « À classer » offers nothing on it and says so (UNSPLIT_OURS_NOTE).
 * With none of ours (0), the general rules.
 */
export function holdsOursUnsplit(o: { unsplit_ours?: number | null }): boolean {
  return (o.unsplit_ours ?? 0) > 0;
}

/**
 * Whether « À classer » offers the M2b links on a line — a payment's return (« Retour du paiement … », and its excess
 * as the servicer's loss) and our refunds (« Remboursement … », « Remboursement revenu … »): only on the lines M2b reads
 * as such, a debit read as a return, our refund or another debit, and a credit undoing a debit. Our own transfers out
 * and the credits from our own account or from a client (M2c-1 kinds) never: the database refuses those links
 * (« debit link refused: not_a_return »; review M2c-1). Nor our payouts' and sweeps' lines (review M2c-6b-1 money-1:
 * `own_transfer_line`, isOurTransferLine). Review round 5 (Q1): nor a credit naming one of our lots with no end-to-end id
 * (isOurTransferCredit) — its one link, the refund its lot held alone, is offersOwnLotRefundBack's; review round 6
 * (R2): whatever its end-to-end id (namesOurLot). Review round 7 (S2): nor a line of an unsplit entry holding ours
 * (holdsOursUnsplit).
 */
export function offersPaymentLinks(o: LineIds): boolean {
  if (holdsOursUnsplit(o) || isOurTransferLine(o) || isOurTransferCredit(o) || namesOurLot(o)) return false;
  if (o.direction === "debit")
    return (
      o.kind === "return" || o.kind === "refund_out" || o.kind === "other_debit"
    );
  return o.direction === "credit" && o.kind === "return";
}

/** Whether « À classer » reads public.debit_link_options for a line: only for a line it may offer links on. */
export function readsLinkOptions(o: LineIds): boolean {
  return offersPaymentLinks(o) || offersOwnBatchRefunds(o) || offersOwnLotRefundBack(o);
}

/**
 * Review M2c-6b-1 round 5 (Q1): the one link a credit naming one of our lots with no end-to-end id takes, read as a
 * `return` (isOurTransferCredit, not isOurTransferLine: our RMT/SWP lines take none) — « Remboursement revenu » of the
 * refund that lot held alone, executed, of the line's amount (private.pmt_inf_refund_back; COMPLIANCE OQ-84's
 * default), the one refund public.debit_link_options lists there. private.post_debit_links refuses every other link
 * and the explanation on such a credit (`own_transfer_line`). Review round 6 (R2): whatever its end-to-end id
 * (namesOurLot: one that is not ours included).
 */
export function offersOwnLotRefundBack(o: LineIds): boolean {
  return (
    o.direction === "credit" && o.kind === "return" && namesOurLot(o) && !isOurTransferLine(o) && !holdsOursUnsplit(o)
  );
}

/**
 * The links « À classer » offers on a line, from the payments the job named and public.debit_link_options listed
 * (`payments`, a payment the job named marked `named`) and the refunds that function listed (`refunds`):
 *   - « Retour du paiement … » on a debit M2b reads as a payment's return or another debit: the payments of which at
 *     least the line's amount is left (5 for a return, 2 for another debit);
 *   - « Retour au-delà du paiement … (perte du cabinet) » on a debit read as a return: the payments the job named of
 *     which less is left than the line takes back (M2c-1, OQ-34);
 *   - « Remboursement … » / « Remboursement revenu … »: the refunds listed.
 * Review round 2 (L4, money-1 / K1 in depth): on our lines exactly what debit_link_options lists there, which is only
 * what private.post_debit_links accepts — on our batch line the refunds it lists (that PmtInf's file-mode refunds of the
 * line's amount handed out to the bank; none while a member is cancelled and not returned), never a payment's return or
 * its loss, whatever the job named; on our RMT/SWP lines and their returns nothing (their options are not even read).
 */
export function linkOffers<
  P extends { left_minor: string; named?: boolean },
  R,
>(
  row: LineIds & { amount_minor: string; review_reason?: string | null; bookable_as?: string | null },
  payments: P[],
  refunds: R[],
  returnGuard?: string | null,
): { returns: P[]; losses: P[]; refunds: R[] } {
  // review M2c-1: no return or refund link on our own transfers and credits (the database refuses them); review
  // M2c-6b-1 (money-1): nor on our payouts' and sweeps' lines (own_transfer_line) — the loss included; review 6b-2c
  // (money-1, money-2): nor a payment's return or loss on a debit « Comptabiliser… » books (paymentLinksGuarded:
  // link_debit refuses payout_candidate, client_payout_line — round 3: but where debit_link_options' return_guard says
  // it takes the return)
  const linkable = offersPaymentLinks(row) && !paymentLinksGuarded(row, returnGuard);
  const amount = BigInt(row.amount_minor);
  const isReturn = row.direction === "debit" && row.kind !== "refund_out";
  return {
    returns:
      linkable && row.direction === "debit"
        ? payments.filter((p) => BigInt(p.left_minor) >= amount).slice(0, isReturn ? 5 : 2)
        : [],
    losses:
      linkable && row.direction === "debit" && row.kind === "return"
        ? payments.filter((p) => p.named === true && BigInt(p.left_minor) < amount)
        : [],
    // … but our batch line takes a refund of its PmtInf in a file handed out (offersOwnBatchRefunds), and a credit
    // naming our lot the refund that lot held alone (offersOwnLotRefundBack, round 5): what is listed; on a guarded
    // line, the refunds public.debit_link_options still lists there — it lists only those private.link_debit_guard
    // lets through: on a debit, a reference-less line of a refund whose own transfer is its only candidate (N1 (b));
    // round 3, on the credit « Comptabiliser… » books, the refund sent to the IBAN it comes back from
    refunds: offersPaymentLinks(row) || offersOwnBatchRefunds(row) || offersOwnLotRefundBack(row) ? refunds : [],
  };
}

/** A payment « À classer » may link a line to: a candidate the job named, or one public.debit_link_options listed. */
export type LinkPayment = {
  payment_id: string;
  amount_minor: string;
  booking_date: string;
  payer_name: string | null;
  left_minor: string;
  file_reference: string | null;
  /** the line's references name it (the job's candidate), else only same account and amount */
  named?: boolean;
};

/**
 * The payments linkOffers chooses « Retour du paiement … » and its loss from on a line « À classer » shows: the
 * payments the job's review named (`candidates` naming a payment, not a refund, with what is left of it: `named`),
 * then those public.debit_link_options listed (`listed`) that the job did not name. One list for the buttons and the
 * text that names them (6b-2d, ended-twin-return-sentence-without-payment).
 */
export function linkPayments(
  candidates: readonly Record<string, unknown>[] | null | undefined,
  listed: readonly LinkPayment[] | null | undefined,
): LinkPayment[] {
  const out = new Map<string, LinkPayment>();
  const text = (v: unknown): string | null => (typeof v === "string" ? v : null);
  for (const c of candidates ?? []) {
    const id = text(c.payment_id);
    const left = text(c.left_minor);
    if (!id || c.refund_request_id || !left) continue;
    out.set(id, {
      named: true,
      payment_id: id,
      amount_minor: text(c.amount_minor) ?? "0",
      booking_date: text(c.booking_date) ?? "",
      payer_name: text(c.payer_name),
      left_minor: left,
      file_reference: text(c.file_reference),
    });
  }
  for (const p of listed ?? []) if (!out.has(p.payment_id)) out.set(p.payment_id, p);
  return [...out.values()];
}

/**
 * A line's ids as isOurTransferLine reads them (the credit's own end-to-end id, the original one it returns), and what
 * the database says of it on the row « À classer » loads (public.debit_queue; review round 7): how many details of
 * ours the unsplit entry it was read from holds (`unsplit_ours`), and whether a credit names one of our lots of its
 * account (`names_our_lot`).
 */
type LineIds = {
  direction: string;
  kind: string;
  end_to_end_id?: string | null;
  original_end_to_end_id?: string | null;
  payment_info_id?: string | null;
  unsplit_ours?: number | null;
  names_our_lot?: boolean | null;
};

/**
 * Review M2c-6b-1 round 3 (M1, M2; integration): a credit that is one of our own transfers coming back, as
 * public.release_own_credit and private.post_bank_bookings' top-up rule read it — our RMT/SWP id as its own end-to-end
 * id or as the original it returns (isOurTransferLine), or, with no end-to-end id, one of our files' PmtInfIds (a lot
 * of one of our files coming back as one line). Neither relayed as a debtor's payment nor booked as a top-up: both
 * refuse it (`own_transfer_line`).
 */
export function isOurTransferCredit(o: LineIds): boolean {
  return (
    o.direction === "credit" &&
    (isOurTransferLine(o) || (!o.end_to_end_id && OUR_PMT_INF.test(o.payment_info_id ?? "")))
  );
}

/**
 * Review M2c-6b-1 round 6 (R2, verdict new:tf-lot-credit-with-foreign-e2e): a credit naming one of our files' PmtInfIds
 * whatever its end-to-end id — our lot, or a transfer of it, coming back, the bank possibly giving it an end-to-end id
 * that is not ours (whether it does is unknown: COMPLIANCE OQ-84). private.post_debit_links refuses on it the explanation
 * and « Remboursement revenu » of any refund but the one its lot held alone (it reads the PmtInfId of a file of the
 * line's account handed out: private.names_our_lot), and offers only what debit_link_options lists. Review round 7
 * (S3, and round 6's minor web edge): the database's word, never the PmtInfId's form — debit_queue's names_our_lot,
 * computed by private.names_our_lot under the servicer's rights: a TF-shaped id of another account or of no file keeps
 * the general rules and no lot note. Such an own or a client's credit is neither relayed nor a top-up either
 * (public.release_own_credit, the top-up rule: own_transfer_line).
 */
export function namesOurLot(o: LineIds): boolean {
  return o.direction === "credit" && o.names_our_lot === true;
}

/**
 * Whether « Approvisionnement par le compte propre » is offered (M2c-1): a credit from the own account
 * (`own_transfer_in`). Review M2c-6b-1 round 3 (M2, L4): never on a credit carrying our payout's or sweep's RMT/SWP id,
 * as its own or as the original it returns, nor on one naming our PmtInfId without an end-to-end id
 * (isOurTransferCredit) — one of our own transfers coming back that the feed did not flag as a return (a CSV label
 * missing RETURN_RE); private.post_bank_bookings' top_up rule refuses it (`own_transfer_line`), it is booked from the
 * statement (ops in M2c-6b-2). Review round 7: (S3) nor one naming one of our lots of its account whatever its
 * end-to-end id (namesOurLot); (S2) nor a line of an unsplit entry holding ours (holdsOursUnsplit).
 */
export function offersTopUp(o: LineIds): boolean {
  return (
    o.direction === "credit" &&
    o.kind === "own_transfer_in" &&
    !isOurTransferCredit(o) &&
    !namesOurLot(o) &&
    !holdsOursUnsplit(o)
  );
}

/**
 * Whether « Paiement d'un débiteur relayé par le cabinet » is offered (review M2c-1): a credit from the own account
 * (`own_transfer_in`) that does not carry our `TOP…` reference — a credit carrying it is our top-up, never a debtor's
 * payment. Review M2c-6b-1 round 3 (M1): nor one carrying our RMT/SWP id, nor one naming our PmtInfId without an
 * end-to-end id (isOurTransferCredit) — our payout, sweep or lot coming back, never a debtor's payment
 * (public.release_own_credit refuses it: `own_transfer_line`). The database checks the rest (unbooked, unlinked, on a
 * dedicated account). Review round 7 (S3, S2): nor one naming one of our lots of its account (namesOurLot), nor a line
 * of an unsplit entry holding ours (holdsOursUnsplit).
 */
export function relayable(o: LineIds & { end_to_end_id: string | null }): boolean {
  return (
    o.direction === "credit" &&
    o.kind === "own_transfer_in" &&
    !/^TOP[0-9A-F]{12}$/.test(o.end_to_end_id ?? "") &&
    !isOurTransferCredit(o) &&
    !namesOurLot(o) &&
    !holdsOursUnsplit(o)
  );
}

/**
 * Review M2c-2: whether « Paiement d'un débiteur relayé par le client » is offered — a credit from a client's confirmed
 * payout IBAN (`client_transfer_in`), e.g. the client forwarding a debtor's payment it received. It is released by
 * public.release_own_credit as an own credit is; the database checks the rest (unbooked, unlinked, on a dedicated
 * account). Review M2c-6b-1 round 3 (M1, pre-existing:relay-of-our-returned-transfer): never one carrying our RMT/SWP
 * id, nor one naming our PmtInfId without an end-to-end id (isOurTransferCredit) — the client's payout coming back from
 * its IBAN, unflagged by a CSV feed; relayed, it would credit a debtor's file with money the debtor never paid (and be
 * remitted again). The database refuses it. Review round 7 (S3, S2): nor one naming one of our lots of its account
 * (namesOurLot: the client's payout of that lot coming back), nor a line of an unsplit entry holding ours.
 */
export function clientRelayable(o: LineIds): boolean {
  return (
    o.direction === "credit" &&
    o.kind === "client_transfer_in" &&
    !isOurTransferCredit(o) &&
    !namesOurLot(o) &&
    !holdsOursUnsplit(o)
  );
}

/**
 * Review M2c-6b-1 round 3 (M1): what « À classer » says of a credit carrying our RMT/SWP id that the bank did not flag
 * as a return (an own or a client's credit, read so by a CSV feed whose label misses RETURN_RE) — in place of the job's
 * review, which reads it as a top-up or a client's credit (top_up_not_found, top_up_differs, client_credit) and
 * suggests a relay the database refuses. The return the bank flags (kind `return`) and our debits keep their review.
 */
export const OUR_TRANSFER_CREDIT_NOTE =
  "Crédit portant la référence de l'un de nos virements (reversement ou quote-part du cabinet) : c'est ce virement qui revient, sans que la banque l'ait signalé comme un retour. Comptabilisez-le avec « Virement revenu » pour son montant exact (s'il est inférieur, demandez le détail à la banque) ; il ne devient ni le paiement d'un débiteur ni un approvisionnement.";

/**
 * Review M2c-6b-1 round 4 (N3): what « À classer » says of a credit naming one of our files' PmtInfIds with no
 * end-to-end id (one of our lots coming back as one line: isOurTransferCredit, not isOurTransferLine) — an own or a
 * client's credit, or a `return` (the import's reading of such a credit since round 4, N1) — in place of the job's
 * review, which suggests a top-up, a relay or an explanation (top_up_not_found, client_credit, no_candidate). The
 * database refuses the relay and the top-up (own_transfer_line); COMPLIANCE OQ-84: ops do not classify it without
 * booking, they tell support.
 */
export const OUR_LOT_CREDIT_NOTE =
  "Crédit portant la référence de l'un des lots de nos fichiers de virements (sans référence de bout en bout) : c'est ce lot, ou des virements de ce lot, qui reviennent ; il ne devient ni le paiement d'un débiteur ni un approvisionnement. Ne le classez pas sans comptabiliser : « Virement revenu » propose les virements du lot dont les montants font seuls celui de la ligne ; sinon, demandez à la banque le détail du retour et prévenez le support.";

/**
 * Review M2c-6b-1 round 6 (R2): what « À classer » says of a credit read as a return that names one of our lots with an
 * end-to-end id (namesOurLot, not isOurTransferCredit) — in place of the job's review (no_candidate, amount_differs,
 * changed), the explanation and every other refund being refused on it (own_transfer_line; COMPLIANCE OQ-84). Round 8's
 * verifier: since T1 that end-to-end id can be one of ours (a refund's RFD id), so the note claims nothing of it.
 */
export const OUR_LOT_FOREIGN_E2E_NOTE =
  "Crédit portant la référence de l'un des lots de nos fichiers de virements, quelle que soit sa référence de bout en bout : c'est peut-être ce lot, ou des virements de ce lot, qui reviennent. Ne le classez pas sans comptabiliser et ne le rattachez à aucun autre remboursement : « Virement revenu » propose les virements du lot dont les montants font seuls celui de la ligne ; sinon, demandez à la banque le détail du retour et prévenez le support.";

/**
 * Review M2c-6b-1 round 7 (S3): what « À classer » says of an own or a client's credit naming one of our lots of its
 * account with an end-to-end id that is not ours (namesOurLot) — in place of the job's review, which suggests a top-up
 * or a relay the database refuses (own_transfer_line; COMPLIANCE OQ-84 (g)).
 */
export const OUR_LOT_OWN_CREDIT_NOTE =
  "Crédit portant la référence de l'un des lots de nos fichiers de virements de ce compte, même s'il vient du compte propre ou du compte d'un client : c'est ce lot, ou des virements de ce lot, qui reviennent ; il ne devient ni le paiement d'un débiteur ni un approvisionnement. Ne le classez pas sans comptabiliser : « Virement revenu » propose les virements du lot dont les montants font seuls celui de la ligne ; sinon, demandez à la banque le détail du retour et prévenez le support.";

/**
 * Review M2c-6b-1 round 7 (S2): what « À classer » says of a line of an unsplit entry holding a detail of ours
 * (holdsOursUnsplit) — in place of the job's review (return_differs, batch_partial), after a P0 reason if any.
 * Review round 8 (T3): only what the code knows, true of every such line — the bank's detail of the entry is incomplete
 * or does not match it (a count, a direction or an amount), never that other movements sit beside ours (a single detail
 * of ours whose own amount is not the entry's holds none); (T2) our refunds and top-ups are counted too.
 * Review M2c-6b-2d round 1 (pages-e2e-1): what « Comptabiliser d'après le détail du relevé » accepts — our details
 * making the entry, or the only detail, ours, with the charges the statement records for the entry (S08) — and only
 * charges the statement does not record are refused.
 */
export const UNSPLIT_OURS_NOTE =
  "Ligne d'une écriture de la banque qui contient au moins l'un de nos virements (reversement, quote-part du cabinet, remboursement ou approvisionnement), son débit ou son retour, et dont le détail donné par la banque est incomplet ou ne correspond pas à l'écriture (nombre, sens ou montant des opérations) : son montant est celui de toute l'écriture, rien n'est comptabilisé automatiquement. Si le relevé détaille nos virements dans cette écriture et qu'ils en font exactement le montant, ou s'il n'y détaille que l'un de nos virements et que les frais qu'il indique pour l'écriture font la différence, « Comptabiliser d'après le détail du relevé » les propose ; sinon (le paiement d'un débiteur, un remboursement ou un approvisionnement dans l'écriture, des frais que le relevé n'indique pas, ou un détail incomplet), elle ne peut pas être comptabilisée ici : demandez le détail à la banque et prévenez le support. Ne la classez pas sans comptabiliser et ne la rattachez à aucun paiement ni remboursement.";

/**
 * Review M2c-6b-1 round 5 (Q1): on such a credit read as a return (offersOwnLotRefundBack), the one exception — the
 * refund its lot held alone, which « À classer » then offers (COMPLIANCE OQ-84's default).
 */
export const OUR_LOT_REFUND_BACK_NOTE =
  "Seule exception : si ce lot ne contenait qu'un remboursement, déjà exécuté et du même montant, ce remboursement vous est proposé (« Remboursement revenu ») : c'est lui qui revient.";

/**
 * Review M2c-6b-1 round 4 (N1): the funds pass's reasons on a credit (the return of our payout or sweep, flagged by the
 * bank or read so at import) in a credit's words — the debit's ones say « Débit … ».
 */
const CREDIT_REVIEW: Record<string, string> = {
  transfer_unknown:
    "Crédit portant la référence d'un virement du cabinet (RMT, SWP) que Collectoo ne connaît pas : rien n'est comptabilisé ; vérifiez dans la banque.",
  transfer_differs:
    "Crédit revenant d'un virement du cabinet, mais sur un autre compte ou dans une autre devise : rien n'est comptabilisé ; vérifiez dans la banque.",
};

/**
 * The review « À classer » shows on a line: the note on our unflagged returned credits (OUR_TRANSFER_CREDIT_NOTE), on a
 * credit naming only one of our lots (OUR_LOT_CREDIT_NOTE, round 4's N3), else the job's reason — in a credit's words
 * on a credit. The return of our payout or sweep keeps the funds pass's review, which names it (round 4's N1).
 */
export function debitReviewText(
  o: LineIds & {
    review_reason: string | null;
    candidates?: ({ run_status?: string | null } & Record<string, unknown>)[] | null;
    amount_minor?: string;
    bookable_as?: string | null;
  },
  linkOptions?: {
    return_guard?: string | null;
    payments?: LinkPayment[] | null;
    refunds?: { refund_request_id: string }[] | null;
  } | null,
): string | null {
  // review 6b-2c round 3: a reference-less debit whose only candidates are payouts returned, or cancelled with their run
  // ended (iii; a cancelled payout whose run is still approved or sent may be that run's payout: still « en cours »)
  const cands = o.candidates ?? [];
  // M2c-6b-3a (K, rule 3b's (iv)): its only candidates a refund or a sweep cancelled out of a downloaded file — raised
  // only once cancellation after download is on
  if (
    o.review_reason === "payout_amount_match" &&
    cands.length > 0 &&
    cands.every((c) => c.status === "cancelled" && (c.kind === "refund" || c.kind === "sweep"))
  )
    return cands.every((c) => c.kind === "sweep")
      ? cands.length === 1
        ? CANCELLED_SWEEP_MATCH
        : CANCELLED_SWEEPS_MATCH
      : // review round 1 (pages-texts-9): a payment's return the row still offers (OQ-86) is named
        o.amount_minor !== undefined &&
          linkOffers(
            { ...o, amount_minor: o.amount_minor },
            linkPayments(cands, linkOptions?.payments),
            [],
            linkOptions?.return_guard,
          ).returns.length > 0
        ? `${CANCELLED_REFUND_MATCH} ${PAYOUT_AMOUNT_MATCH_RETURN}`
        : CANCELLED_REFUND_MATCH;
  // review round 1 (pages-texts-4): a refund of its amount the link options do not offer (a cancelled transfer may be
  // the line: the trigger would refuse it)
  if (
    o.review_reason === "refund_amount_match" &&
    linkOptions?.refunds != null &&
    cands.length > 0 &&
    cands.every(
      (c) =>
        typeof c.refund_request_id === "string" &&
        !linkOptions.refunds!.some((r) => r.refund_request_id === c.refund_request_id),
    )
  )
    return REFUND_AMOUNT_MATCH_BARRED;
  // review round 1 (pages-texts-2): a sweep's own late debit is booked as that sweep's, not « Virement hors reversement »
  if (
    o.review_reason === "cancelled_transfer_debited" &&
    (/^SWP/.test(o.end_to_end_id ?? "") ||
      /^SWP/.test(o.original_end_to_end_id ?? "") ||
      (cands.length > 0 && cands.every((c) => c.kind === "sweep")))
  )
    return CANCELLED_SWEEP_DEBITED;
  if (
    o.review_reason === "payout_amount_match" &&
    cands.length > 0 &&
    cands.every(
      (c) =>
        c.status === "returned" ||
        (c.status === "cancelled" && c.run_status !== "approved" && c.run_status !== "sent"),
    )
  )
    // 6b-2d (ended-twin-return-sentence-without-payment): the sentence names « Retour du paiement … » only when the row
    // offers that button — linkOffers' returns from the same payments the row's actions read (linkPayments), never on
    // return_guard alone (null while debit_link_options lists no payment the line can take back)
    return o.amount_minor !== undefined &&
      linkOffers(
        { ...o, amount_minor: o.amount_minor },
        linkPayments(cands, linkOptions?.payments),
        [],
        linkOptions?.return_guard,
      ).returns.length > 0
      ? `${PAYOUT_AMOUNT_MATCH_ENDED} ${PAYOUT_AMOUNT_MATCH_RETURN}`
      : PAYOUT_AMOUNT_MATCH_ENDED;
  // M2c-6b-2c (critic2 ML-4): a cancelled transfer whose run is still approved or sent — this debit is that run's payout,
  // never booked as « Virement hors reversement » (the command refuses run_still_live)
  if (
    o.review_reason === "cancelled_transfer_debited" &&
    (o.candidates ?? []).some((c) => c.run_status === "approved" || c.run_status === "sent")
  )
    return holdsOursUnsplit(o) ? `${CANCELLED_TRANSFER_LIVE_RUN} ${UNSPLIT_OURS_NOTE}` : CANCELLED_TRANSFER_LIVE_RUN;
  // M2c-6b-3a-2 (T14): a refund's
  if (o.review_reason === "cancelled_transfer_debited" && cands.length > 0 && cands.every((c) => c.kind === "refund"))
    return CANCELLED_REFUND_DEBITED;
  // review round 7 (S2): a line of an unsplit entry holding ours — a P0 first, then why nothing is offered
  if (holdsOursUnsplit(o))
    return o.review_reason !== null && P0_DEBIT_REVIEWS.has(o.review_reason)
      ? `${reviewReasonText(o.direction, o.review_reason)} ${UNSPLIT_OURS_NOTE}`
      : UNSPLIT_OURS_NOTE;
  if (o.direction === "credit" && o.kind !== "return" && isOurTransferLine(o)) return OUR_TRANSFER_CREDIT_NOTE;
  if (isOurTransferCredit(o) && !isOurTransferLine(o))
    return offersOwnLotRefundBack(o) ? `${OUR_LOT_CREDIT_NOTE} ${OUR_LOT_REFUND_BACK_NOTE}` : OUR_LOT_CREDIT_NOTE;
  // review round 6 (R2): a return naming our lot with an end-to-end id that is not ours
  if (offersOwnLotRefundBack(o)) return `${OUR_LOT_FOREIGN_E2E_NOTE} ${OUR_LOT_REFUND_BACK_NOTE}`;
  // review round 7 (S3): an own or a client's credit naming our lot so, as the database reads it
  if (namesOurLot(o) && (o.kind === "own_transfer_in" || o.kind === "client_transfer_in"))
    return OUR_LOT_OWN_CREDIT_NOTE;
  if (!o.review_reason) return null;
  return reviewReasonText(o.direction, o.review_reason);
}

/** The job's reason in French, in a credit's words on a credit. */
function reviewReasonText(direction: string, reason: string): string {
  const credit = direction === "credit" ? CREDIT_REVIEW[reason] : undefined;
  if (credit) return credit;
  return DEBIT_REVIEW[reason] ?? reason;
}

/** The button and sheet title of a relayed debtor payment, by who relays it. */
export const RELAY_LABEL = {
  servicer: "Paiement d'un débiteur relayé par le cabinet",
  client: "Paiement d'un débiteur relayé par le client",
} as const;

/**
 * What a line booked from the statement became (bank_line_booking.kind; M2c-6b-2b, plan §3.13): the job's bookings
 * (6b-1) and ops' (`book_transfer_line`). « Traités » shows a line's bookings joined by `+` (public.debit_queue). The
 * fee keeps the label it has had since M2c-1.
 */
export const DECISION_LABEL: Record<string, string> = {
  payout: "Débit d'un reversement",
  sweep: "Débit de la quote-part du cabinet",
  unplanned_payout: "Virement hors reversement",
  unplanned_sweep: "Virement au compte propre",
  payout_returned: "Reversement revenu",
  sweep_returned: "Quote-part revenue",
  unplanned_payout_returned: "Virement hors reversement revenu",
  unplanned_sweep_returned: "Virement au compte propre revenu",
  fee: LINK_KIND.fee,
};

/**
 * What a decided line became, in French: a relayed payment says who relayed it (review M2c-2); a line booked in
 * several parts says each (« Débit d'un reversement + Frais bancaires … », M2c-6b-2b).
 */
export function decisionLabel(decision: string, kind: string): string {
  if (decision === "relayed_payment" && kind === "client_transfer_in")
    return RELAY_LABEL.client;
  return decision
    .split("+")
    .map((d) => DECISION_LABEL[d] ?? LINK_KIND[d] ?? d)
    .join(" + ");
}

/**
 * Whether a line may be classified without booking (« Classer sans comptabiliser »): never our refund leaving the
 * account, nor a return whose references name one of our payments (review M2b-6: money out for a payment is always
 * booked; the database refuses it too). A return naming nothing of ours (a fee's direct debit the bank rejected) may be.
 */
export function explainable(o: {
  direction: string;
  kind: string;
  namesPayment: boolean;
  endToEndId?: string | null;
  originalEndToEndId?: string | null;
  paymentInfoId?: string | null;
  /** review round 7 (S3): the database's word that a credit names one of our lots of its account (debit_queue) */
  namesOurLot?: boolean | null;
  /** review round 7 (S2): the unsplit entry's details of ours (debit_queue's unsplit_ours) */
  unsplitOurs?: number | null;
}): boolean {
  // M2c-6b-1 (plan §2.3; the database's own_transfer_line, review money-1): our payout's or sweep's debit (its RMT or
  // SWP id, or a batch line of one of our PmtInfs) and the return of one are booked from the statement, never explained
  // away — nor any line carrying one of our RMT/SWP ids, whichever way (isOurTransferLine reads both ids, round 2) —
  // nor, review round 5 (Q1), a credit naming one of our lots with no end-to-end id (isOurTransferCredit), whatever its
  // kind, as OUR_LOT_CREDIT_NOTE says — nor, round 6 (R2), with an end-to-end id that is not ours (namesOurLot, the
  // database's word since round 7) — nor, round 7 (S2), a line of an unsplit entry holding ours, whatever its direction
  const ids = {
    direction: o.direction,
    kind: o.kind,
    end_to_end_id: o.endToEndId,
    original_end_to_end_id: o.originalEndToEndId,
    payment_info_id: o.paymentInfoId,
    names_our_lot: o.namesOurLot,
    unsplit_ours: o.unsplitOurs,
  };
  if (holdsOursUnsplit(ids) || isOurTransferLine(ids) || isOurTransferCredit(ids) || namesOurLot(ids)) return false;
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
export function returnEffect(o: {
  amount: string;
  left: string;
  full: boolean;
  dateFr: string;
  hasFile: boolean;
}): string {
  const head = o.hasFile
    ? `La banque reprend ${o.amount} sur ce paiement. Ses imputations et reversements, s'il y en a, seront annulés au ${o.dateFr} (date du retour) : les factures retrouvent leur solde. Notification enregistrée pour le client (envoi : à venir).`
    : `La banque reprend ${o.amount} sur ce paiement, rattaché à aucun dossier : le retour est comptabilisé au ${o.dateFr} (date du retour), sans quittance ni information d'un client.`;
  if (!o.full)
    return `${head} Il restera ${o.left} du paiement, en attente de votre décision (réimputer ou rembourser).`;
  return o.hasFile
    ? `${head} Le paiement sera « retourné » et sa quittance annulée.`
    : `${head} Le paiement sera « retourné ».`;
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
  const byReturn = (kind: string) =>
    o.notifications.some((n) => n.kind === kind && n.reason === "bank_return");
  if (byReturn("payment_allocation_reversed"))
    parts.push(
      "Ses imputations sont annulées à la date du retour : les factures retrouvent leur solde.",
    );
  if (byReturn("payment_forward_reversed"))
    parts.push("Son reversement au client est annulé à la date du retour.");
  if (!o.hasFile) {
    parts.push(
      "Il n'est rattaché à aucun dossier : ni quittance, ni information d'un client.",
    );
    return parts.join(" ");
  }
  if (o.latestReceiptKind === "void") parts.push("Sa quittance est annulée.");
  else if (o.latestReceiptKind !== null)
    parts.push("L'annulation de sa quittance est en cours.");
  const told = [...o.notifications]
    .reverse()
    .find((n) => n.kind === "payment_returned");
  if (told)
    parts.push(`Information du client : ${notificationState(told, when)}.`);
  return parts.join(" ");
}

/**
 * What linking a line to one of our refunds does. A debit that does not carry the refund's RFD id as its end-to-end
 * reference (the bank read it as a plain debit, `other_debit`: review M2b-6) is linked on ops' word: the sheet asks
 * them to check the transfer in the bank first.
 */
export function linkRefundEffect(o: {
  direction: string;
  lineRef: string | null;
  refundRef: string;
  payee: string;
}): string {
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
export function relayedPaymentEffect(o: {
  amount: string;
  dateFr: string;
}): string {
  return `Le crédit de ${o.amount} deviendra un paiement reçu, comptabilisé sur le compte de fonds de tiers au ${o.dateFr} (date de la ligne), payeur « Versement relayé par le cabinet ». Il attendra dans « Paiements à traiter » d'être affecté au dossier du débiteur, puis sera imputé comme tout paiement. Le motif est conservé : indiquez qui a payé le cabinet, et quand. À ne pas utiliser pour un approvisionnement par le cabinet.`;
}

/**
 * Review M2c-2: what releasing a client's credit as a debtor's payment does (public.release_own_credit on a
 * `client_transfer_in` line): the same as for an own credit — a payment on no file yet, booked at the line's date, that
 * waits in « Paiements à traiter ». Not for the client paying one of our invoices, nor for a payment already declared on
 * the file as made to the client directly (it would be counted twice).
 */
export function clientRelayedPaymentEffect(o: {
  amount: string;
  dateFr: string;
}): string {
  return `Le crédit de ${o.amount} venant du compte de reversement d'un client deviendra un paiement reçu, comptabilisé sur le compte de fonds de tiers au ${o.dateFr} (date de la ligne), payeur « Versement relayé par le client ». Il attendra dans « Paiements à traiter » d'être affecté au dossier du débiteur, puis sera imputé comme tout paiement. Le motif est conservé : indiquez quel débiteur a payé le client, et quand. À ne pas utiliser pour le règlement d'une facture du cabinet par le client, ni pour un paiement déjà déclaré sur la fiche du dossier comme reçu directement par le client.`;
}

/**
 * M2c-1 (OQ-34, founder #8): a return larger than what is left of its payment. The payment's return of what is left
 * (its imputations undone at the return date, as any return) and the excess, the servicer's loss — never the client's
 * nor another client's.
 */
export function lossEffect(o: {
  amount: string;
  left: string;
  excess: string;
  dateFr: string;
  noneLeft: boolean;
}): string {
  const loss = `l'excédent de ${o.excess} sera une perte à la charge du cabinet, jamais du client ni d'un autre client (question ouverte OQ-34 : recours contre le payeur).`;
  if (o.noneLeft)
    return `La banque reprend ${o.amount} alors que rien ne reste du paiement : ${loss}`;
  return `La banque reprend ${o.amount}, plus que ce qui reste du paiement (${o.left}). Le retour de ${o.left} sera comptabilisé sur le paiement au ${o.dateFr} (ses imputations et reversements annulés à cette date) ; ${loss}`;
}

/**
 * What « Libérer » does to a CSV line held as a suspected duplicate (review M2b-6): the line becomes what the import
 * read it as (`private.held_line_kind`), and only a debtor's credit (or an unsplit batch) becomes a payment. A credit
 * read as a return (« RETOUR VIR SEPA … » in its label) books nothing and goes with the debits; a debit too. When the
 * page is not told the reading (`heldKind` null), a credit's sheet says both outcomes rather than promise a payment.
 */
export function releaseEffect(o: {
  direction: string;
  heldKind: string | null;
  amount: string;
}): string {
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
    help: "Le cabinet doit de l'argent au compte dédié (avances, frais bancaires, pertes) au-delà des approvisionnements demandés. Collectoo commande un approvisionnement chaque heure (référence TOP…, page Virements) : exécutez-le depuis le compte propre, à la main ou par le fichier.",
  },
  // M2c-7e-1 (plan §7.1, §7.4)
  // (review round 1, TUI-1: « choisi » — an own account may exist and not be the one of « Facturation »)
  top_up_account_missing: {
    label: "Approvisionnement impossible : aucun compte propre",
    help: "Le cabinet doit de l'argent au compte dédié mais aucun compte propre n'est choisi (Paramètres › Facturation) : Collectoo ne peut commander aucun approvisionnement. Choisissez le compte propre, ou approvisionnez le compte dédié à la main depuis le compte propre.",
  },
  // (review round 1, MONEY-BANK-4: also when the hourly job no longer runs)
  top_up_order_failed: {
    label: "Approvisionnement horaire non commandé",
    help: "La commande horaire des approvisionnements ne passe plus pour ce cabinet (trois heures de suite une opération en cours, une erreur, ou aucun passage depuis plus de trois heures) : ce que le cabinet doit au compte dédié n'est pas commandé. Approvisionnez-le depuis le compte propre (« Comptes bancaires ») et prévenez le support si l'alerte reste.",
  },
  remittance_completeness: {
    label: "Encaissements à reverser incomplets",
    help: "Ce qui est dû à un client ne vaut pas ses encaissements en attente de reversement plus ses reversements validés et non encore débités (I14).",
  },
  remittance_item_twice: {
    label: "Encaissement à la fois en attente et reversé",
    help: "Une écriture figure dans la file d'attente et dans un reversement : chaque encaissement est reversé une seule fois (I15).",
  },
  remittance_run_totals: {
    label: "Totaux d'un reversement incohérents",
    help: "Brut ≠ somme des lignes, net + compensation ≠ brut, virement ≠ net, ou commission des factures (et de ce qu'ont absorbé les avoirs manuels) ≠ commission des lignes (I16).",
  },
  commission_key_state: {
    label: "Historique de commission ≠ factures d'un dossier",
    help: "Pour un dossier, ce que ses factures facturent encore plus ce que des avoirs manuels ont rectifié ne vaut pas la commission facturée de son historique (I22) : le prochain reversement de ce client laissera sa commission en attente (reversement brut).",
  },
  // review M2c-5b (legal#0, F2): what a credit note owes the client beyond what its invoice still owed, still unsettled
  credit_refund_owed: {
    label: "Avoir à rembourser au client depuis plus de 30 jours",
    // M2c-7c-1 (plan §5.5): the refund from the own account is recorded on the credit note
    help: "Un avoir (le plus souvent manuel) dépasse ce que sa facture devait encore : le surplus est dû au client. Un reversement suivant le règle avec son virement, mais aucun ne l'a réglé depuis 30 jours. Préparez le reversement du client si des encaissements l'attendent ; sinon, remboursez-le par virement depuis le compte propre et enregistrez-le (« Enregistrer le remboursement » sur l'avoir).",
  },
  invoice_numbering: {
    label: "Numérotation des factures discontinue",
    help: "La série annuelle des factures et avoirs a un trou, un compteur en avance ou une date qui recule (I17).",
  },
  invoice_ledger: {
    label: "Facture ≠ son écriture",
    help: "L'écriture d'une facture ou d'un avoir ne vaut pas son TTC (4111) et son HT (7060) (I17).",
  },
  settlement_ledger: {
    label: "Factures ouvertes ≠ compte client 4111",
    help: "Ce que les factures et avoirs d'un client laissent ouvert ne vaut pas son compte 4111 (I18).",
  },
  vat_pending_ledger: {
    label: "TVA en attente ≠ factures",
    help: "La TVA sur commissions non réglées (44574) ne vaut pas la TVA des parts de factures non réglées (I18).",
  },
  remittance_deadline_breached: {
    label: "Délai de reversement dépassé",
    help: "Des encaissements d'un client n'ont pas été reversés avant leur dernière date d'exécution (art. R124-6 CPCE) : préparez et validez son reversement (« Reversements »).",
  },
  remittance_delay_unmeetable: {
    label: "Délai de reversement intenable",
    // review M2c-4 (legal#1): the J-5, J-1 alerts and the breach then count one month from the encaissement
    help: "Le délai du mandat (moins de 6 jours) ne laisse aucun jour ouvré pour exécuter le virement à temps : à revoir avec le client. Les alertes à 5 et 1 jours ouvrés, puis le dépassement, sont alors comptés sur un mois après l'encaissement.",
  },
  remittance_due_critical: {
    label: "Reversement à exécuter demain au plus tard",
    help: "La dernière date d'exécution d'encaissements d'un client est dans un jour ouvré.",
  },
  remittance_due_soon: {
    label: "Reversement à exécuter sous 5 jours ouvrés",
    help: "La dernière date d'exécution d'encaissements d'un client approche.",
  },
  payout_blocked: {
    label: "Reversement bloqué",
    help: "Un brouillon de reversement ne peut pas être validé (IBAN de reversement manquant, non confirmé ou revenu, événement du client) : levez le blocage avant la date limite.",
  },
  draft_waiting: {
    label: "Brouillon de reversement en attente",
    // review M2c-4 (tests-ui#3, C4): also, at once, a draft whose preparation failed (details.prepare_failed)
    help: "Un brouillon de reversement attend sa validation depuis plus d'un jour ouvré, ou sa préparation a échoué et rien ne la relance : validez-le, ou ouvrez-le et cliquez « Actualiser » (ou « Abandonner »).",
  },
  // review M2c-4 (legal#3): an approved run is not paid until the bank's debit; review M2c-6b-1 (legal-texts#2, K3):
  // what the check knows is that the debit is not booked — the statement may show it on a line the job cannot book;
  // round 2 (L3): a payout never handed out to the bank (still ordered, or in a file nobody downloaded) is proven unpaid
  // at once (private.run_remittance_runs_checks' olc.proven), whatever the statements
  remittance_payout_overdue: {
    label: "Reversement validé non débité après la date limite",
    help: "La dernière date d'exécution de certains encaissements d'un reversement validé est passée (art. R124-6 CPCE) et son débit n'est pas comptabilisé : vérifiez que le virement a été transmis et exécuté. Si le relevé montre ce débit sans sa référence, ou dans une ligne groupée d'un autre montant, la ligne attend dans « Débits et retours ». Le dépassement est enregistré aussitôt pour un virement jamais remis à la banque (encore à mettre dans un fichier, ou dans un fichier jamais téléchargé) ; sinon, une fois les relevés de cette date importés sans aucune ligne qui puisse être ce débit.",
  },
  // M2c-6b-3b part 2 (CPCE-08; founder question 2 of « M2c-6b-3b part 1 », its default): a booked run whose payout chain
  // holds another transfer, whose R124-6 row waits for the statements or a line's classification
  // (private.remittance_breach_held) — the row details' days and lines are worded by breachHeldHelp. Review round 1:
  // a statement counts for a day only once established after that day's end (dt-1, private.statement_covers); a line
  // « Comptabiliser… » does not propose as that transfer stops holding the record after the bound days, though it may
  // still wait in « Débits et retours » (dt-2, private.remittance_chain_holds)
  remittance_breach_held: {
    label: "Dépassement de délai non encore enregistré",
    help: "D'après les relevés importés, ce reversement a été payé après la dernière date d'exécution de certains de ses encaissements (art. R124-6 CPCE), mais un autre virement émis pour ce reversement (le virement annulé après téléchargement, ou celui qui l'a remplacé) a pu les payer à temps : le dépassement n'est pas encore enregistré. Il le sera, s'il est avéré, au prochain contrôle une fois que les relevés du compte de fonds de tiers couvrent chaque jour ouvré en cause et qu'aucune ligne qui peut être le débit de cet autre virement ne retient plus l'enregistrement (une ligne que « Comptabiliser… » ne propose pas comme ce virement cesse de le retenir quelques jours ouvrés après sa date) : selon le cas, importez les relevés manquants, établis après la fin des jours en cause, ou classez dans « Débits et retours » la ligne en attente ; l'alerte cesse alors.",
  },
  remittance_payout_not_executed: {
    label: "Reversement non exécuté à la date demandée",
    help: "La date d'exécution demandée d'un reversement validé est passée et son débit n'est pas comptabilisé : vérifiez la transmission du fichier de virements à la banque.",
  },
  // review M2c-4 (nc#0): what the deadline engine or the hourly schedule could not do
  remittance_deadline_not_computable: {
    label: "Délai de reversement non calculable",
    help: "Des encaissements ou des paiements ont une date d'encaissement hors du calendrier des jours ouvrés renseigné : leur dernière date d'exécution ne peut pas être calculée. Vérifiez-les et reversez-les sans attendre ; prévenez le support.",
  },
  remittance_schedule_failed: {
    label: "Préparation automatique des reversements en échec",
    help: "La tâche horaire qui prépare les reversements du cabinet (jours du mandat, garde du délai) a échoué : préparez les reversements dus (« Préparer maintenant ») et prévenez le support.",
  },
  invoice_late: {
    label: "Facture émise tardivement",
    help: "Un reversement a été validé plus de 2 jours ouvrés après sa préparation : la facture de commission est datée du jour de la validation.",
  },
  // review M2c-4, round 2 (legal#4): the date printed on the invoice has passed (L441-10 II: penalties from the next day)
  invoice_overdue: {
    label: "Facture de commission non réglée à sa date",
    // M2c-7d-3 (plan §6.2.10, §6.4 [critic] L9): what it leaves out (to declare, never dunned)
    // M2c-7d-3 review round 2: and the invoice netted in full whose set-off the debit withheld (SQL:
    // private.invoice_withheld_on — the debit's day stands for its due date)
    help: "Une facture de commission reste ouverte après la date de règlement qu'elle indique : une facture à régler au compte propre, une facture rétablie par l'annulation d'un reversement que le reversement suivant n'a pas compensée à temps, ou une facture à régler par compensation sur son reversement dont la compensation a été retenue au débit (fin du mandat, saisie : impayée depuis ce débit, règle du cabinet). Préparez le reversement du client ou vérifiez son règlement (les factures d'un client en procédure collective nées avant le jugement, et celles d'un client en liquidation, ne sont pas listées ici ; tant qu'elles ne sont pas déclarées, elles le sont dans « Créance du cabinet à déclarer » ou « Facture née après le jugement, impayée à son échéance »).",
  },
  // review M2c-5 (perf#2 = tests-ui#2, K4): a statement or an invoice's PDF the documents job could not draw
  remittance_document_failed: {
    label: "Document de reversement en échec",
    help: "Le relevé d'un reversement, ou le PDF d'une facture ou d'un avoir, n'a pas pu être établi ; les autres documents continuent d'être établis et celui-ci est retenté automatiquement, à intervalles croissants (6 heures au plus). Sa dernière erreur est enregistrée pour le support. Le client ne le voit pas encore : prévenez le support.",
  },
  remittance_document_missing: {
    label: "Document de reversement en attente depuis plus de 24 h",
    help: "Le relevé d'un reversement, ou le PDF d'une facture ou d'un avoir, attend d'être établi depuis plus de 24 heures : le traitement des documents ne passe plus. Le client ne le voit pas encore : prévenez le support.",
  },
  // M2c-6a (design §15): the transfer files
  transfer_not_filed: {
    label: "Virements en attente de fichier",
    help: "Des reversements ou des remboursements ordonnés attendent depuis plus d'un jour ouvré d'être mis dans un fichier de virements, ou y sont retenus (IBAN changé, nom non concordant, nom du bénéficiaire hors de l'alphabet latin, IBAN hors de la zone SEPA… : leur motif est sur « Virements »). Générez le fichier, ou levez le motif.",
  },
  file_not_downloaded: {
    label: "Fichier de virements non téléchargé",
    help: "Un fichier généré depuis plus d'un jour ouvré n'a pas été téléchargé : téléchargez-le et déposez-le à la banque (s'il n'est plus à jour, le téléchargement le remplace : régénérez-le), ou annulez-le.",
  },
  // review M2c-6b-1 (legal-texts#3): automatically only for a line carrying the reference; a file never deposited
  // leaves no line
  file_not_marked_sent: {
    label: "Fichier téléchargé, non marqué comme transmis",
    help: `Un fichier a été téléchargé mais personne n'a indiqué l'avoir déposé à la banque, et l'heure limite de dépôt de son jour d'exécution est passée (contrôlé toutes les heures) : déposez-le, puis « Marquer comme transmis ». Un fichier téléchargé ne peut pas encore être annulé dans Collectoo : s'il ne doit pas partir, gardez-le tel quel, vérifiez le relevé et voyez avec la banque ; ses virements restent en cours jusqu'à ce que leurs débits soient comptabilisés depuis le relevé (${FILE_BOOKED_WHEN}). Un fichier jamais déposé n'apparaît sur aucun relevé : ses virements restent en cours jusqu'à ce que l'annulation après téléchargement soit disponible.`,
  },
  transfer_not_debited: {
    label: "Virements sans débit sur le relevé",
    help: "Des virements d'un fichier téléchargé n'apparaissent sur aucun relevé plus de deux jours ouvrés après leur date d'exécution : importez le relevé, ou vérifiez auprès de la banque que le fichier a été exécuté.",
  },
  transfer_file_failed: {
    label: "Fichier de virements en échec",
    help: "Un fichier n'a pas pu être écrit après plusieurs essais ; ses virements attendent le prochain fichier. Générez-le de nouveau ; si l'échec se répète, prévenez le support.",
  },
  // M2c-6a review (T6, tests-ui#10): the job that writes a file has not finished it
  transfer_file_pending: {
    label: "Fichier de virements en préparation depuis plus de 15 minutes",
    help: "Le traitement qui écrit le fichier ne l'a pas terminé : ses virements y attendent (« En préparation »). Rechargez « Virements » ; s'il reste bloqué, annulez ce fichier (ses virements reviennent « à mettre dans un fichier ») et prévenez le support.",
  },
  // M2c-6a review (T3): transfers held out of every file until their data changes, should the checks raise them alone
  payee_name_not_epc: {
    label: "Nom de bénéficiaire hors de l'alphabet latin",
    help: "Un virement est retenu hors des fichiers : le nom du bénéficiaire n'a aucun caractère accepté par le format SEPA. Remboursement : annulez-le et redemandez-le avec le nom en lettres latines ; reversement : faites confirmer le compte de reversement avec le nom du titulaire en lettres latines.",
  },
  iban_not_sepa: {
    label: "IBAN de bénéficiaire hors de la zone SEPA",
    help: "Un virement est retenu hors des fichiers : l'IBAN du bénéficiaire est d'un pays hors de la zone SEPA. Remboursement : annulez-le et redemandez-le « à exécuter vous-même » ; reversement : faites confirmer un IBAN de la zone SEPA.",
  },
  // M2c-6a review, round 2 (D4): a cancelled file executed late after all
  transfer_already_debited: {
    label: "Virement déjà débité malgré son annulation",
    help: "Un relevé montre le débit d'un virement alors que son fichier a été annulé (exécuté plus tard malgré tout), sous sa référence de bout en bout, celle du virement qu'il remplace ou dans une ligne groupée du fichier annulé — ou alors qu'il avait été annulé seul, la banque l'ayant d'abord laissé hors de la ligne groupée de son lot : le reversement ou le remboursement reste hors des fichiers pour ne pas payer deux fois — s'il est déjà dans un fichier téléchargé, demandez à la banque de ne pas l'exécuter —, et aucune nouvelle quote-part du cabinet n'est mise dans un fichier tant qu'une quote-part annulée débitée n'est pas revenue (une quote-part déjà dans un fichier téléchargé n'est pas arrêtée : demandez à la banque de ne pas l'exécuter). Ne refaites aucun virement ; prévenez le support pour rattacher ce débit.",
  },
  payee_name_mismatch: {
    label: "Nom de bénéficiaire non concordant",
    help: "La vérification du bénéficiaire de la banque a signalé un nom différent ou proche pour un compte de reversement : les virements vers ce compte sont bloqués jusqu'à ce qu'une autre personne vérifie le titulaire (« Virements »).",
  },
  unallocated_deadline: {
    label: "Fonds rattachés à un dossier non imputés",
    help: "De l'argent rattaché au dossier d'un client attend son imputation alors que son délai de reversement court (OQ-26) ; « bloqué » quand une procédure l'interdit.",
  },
  vat_pack_review: {
    label: "Taux de TVA à revoir",
    help: "Le pack de TVA doit être relu avant la recodification du 1er janvier 2027 (CIBS).",
  },
  calendar_horizon: {
    label: "Calendrier des jours ouvrés à prolonger",
    help: "Moins de 12 mois de jours ouvrés sont renseignés : les délais de reversement ne pourront plus être calculés.",
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
  receipt_missing: {
    label: "Quittance manquante",
    help: "Un paiement rattaché à un dossier n'a pas de quittance.",
  },
  receipt_numbers: {
    label: "Plusieurs numéros de quittance",
    help: "Un paiement a plusieurs numéros de quittance.",
  },
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
  // M2c-6b-1 (plan §2.5, design §15): the bookings from the statement
  bank_line_booked: {
    label: "Ligne bancaire comptabilisée incohérente",
    help: "Les écritures d'une ligne comptabilisée ne font pas son montant : signalez-la au support.",
  },
  transfer_booked_once: {
    label: "Virement comptabilisé sans débit unique",
    help: "Un virement « Débité » n'a pas exactement un débit comptabilisé (ou un reversement comptabilisé n'a pas son virement) : signalez-le au support.",
  },
  cancelled_transfer_debited: {
    label: "Virement annulé débité par la banque",
    help: "La banque a exécuté un virement annulé dans Collectoo : vérifiez avant tout nouveau virement (risque de double paiement).",
  },
  transfer_debited_twice: {
    label: "Virement débité deux fois",
    help: "Un second débit porte la référence d'un virement déjà comptabilisé : voyez avec la banque.",
  },
  transfer_not_handed_out: {
    label: "Virement débité sans fichier téléchargé",
    help: "La banque a débité un virement dont le fichier n'a jamais été téléchargé : vérifiez d'où vient l'ordre.",
  },
  payout_returned: {
    label: "Reversement revenu impayé",
    help: "La banque a rejeté le virement d'un reversement : le compte de reversement du client est bloqué jusqu'à son remplacement ou sa reconfirmation ; le montant est à reverser à nouveau dans le délai.",
  },
  sweep_returned: {
    label: "Virement vers le compte propre revenu",
    help: "La quote-part du cabinet virée vers son compte propre est revenue : vérifiez le compte propre.",
  },
  // review M2c-6b-1 (legal-texts#7): « dû au client »
  payout_overrun: {
    label: "Reversement au-delà du dû",
    // M2c-7a (plan §3.7)
    // M2c-7b (plan §4.3): how it is recovered
    help: "Un reversement débité dépassait ce qui restait dû au client : le cabinet lui a avancé la différence. Avec une clause de reprise du mandat auquel elle est rattachée, elle est déduite des prochains reversements du client ; sinon (pas de clause, aucun mandat unique, fin du mandat ou saisie en cours), elle reste à récupérer (page « Avances ») ; client en procédure collective ou en liquidation : ni reprise ni demande, elle est à déclarer (règle du cabinet). Un administrateur peut la passer en perte.",
  },
  bank_line_unbooked: {
    label: "Débits du cabinet non comptabilisés",
    // review 6b-2c (legal-deadlines-3): also the reference-less debits of an in-flight transfer's amount (6b-2c)
    help: "Des débits ou retours de nos virements, ou des débits sans notre référence du montant d'un virement du cabinet en cours, attendent depuis plus d'un jour ouvré dans « Débits et retours ».",
  },
  servicer_funds_unswept: {
    label: "Quote-part du cabinet non virée",
    help: "La part du cabinet reste sur le compte dédié depuis plus de deux jours ouvrés sans virement vers son compte propre : générez le fichier de virements.",
  },
  // review M2c-6b-1 (legal-texts#4): a top-up moves the servicer's own money to the dedicated account (+5120 / −4679)
  // M2c-6b-2a (plan §2.6, §7.1; critic L14, L10)
  transfer_unknown: {
    label: "Référence du cabinet inconnue",
    help: "Ligne (débit ou crédit) portant une référence de virement du cabinet (RMT, SWP) ou un lot que Collectoo ne connaît pas : vérifiez dans la banque.",
  },
  own_transfer_payment: {
    label: "Paiement créé à partir d'un virement du cabinet revenu",
    help: "Paiement créé à partir d'un de nos virements revenus (il porte la référence d'un reversement, d'une quote-part du cabinet ou d'un lot de nos fichiers) : ces sommes ne sont reversées à personne tant qu'il n'est pas traité. Ne l'affectez pas, ne le remboursez pas, prévenez le support.",
  },
  double_payout_open: {
    label: "Avance du cabinet après un virement hors reversement",
    // M2c-7a (plan §3.7): « ce recouvrement n'est pas encore géré » goes (7b adds how it is recovered)
    help: "Avance du cabinet après un virement exécuté hors reversement. Avec une clause de reprise du mandat auquel elle est rattachée, elle est déduite des prochains reversements du client ; sinon (pas de clause, aucun mandat unique, fin du mandat ou saisie en cours), elle reste à récupérer (page « Avances ») ; client en procédure collective ou en liquidation : ni reprise ni demande, elle est à déclarer (règle du cabinet). Un administrateur peut la passer en perte.",
  },
  // M2c-7a (plan §3.4, §3.7): the advances' checks (private.run_advance_checks)
  remitted_reversal_uncovered: {
    label: "Annulation d'un encaissement déjà reversé sans avance du cabinet",
    help: "Un encaissement déjà versé au client a été annulé sans que le cabinet en fasse l'avance : la somme serait déduite des autres encaissements du client, une compensation faite sans l'avance ni la clause qui la prévoit. « Couvrir » enregistre l'avance.",
  },
  advance_ledger: {
    label: "Avances du cabinet ≠ compte des avances",
    help: "Pour ce client, les avances non récupérées ne valent pas le solde du compte des avances à récupérer (I18).",
  },
  advance_open: {
    label: "Avance du cabinet non récupérée depuis plus de 30 jours",
    // M2c-7d-3 (plan §6.2.10 [critic] L4; carried item 1): an advance of a client in a proceeding or in liquidation is
    // listed once, in claims_to_declare (« elle est à déclarer » below; the text is 7b's, pinned)
    help: "Le cabinet a avancé cette somme au client (encaissement repris après reversement, reversement au-delà du dû, virement hors reversement). Elle n'est pas encore récupérée. Avec une clause de reprise du mandat auquel elle est rattachée, elle est déduite des prochains reversements du client ; sinon (pas de clause, aucun mandat unique, fin du mandat ou saisie en cours), elle reste à récupérer (page « Avances ») ; client en procédure collective ou en liquidation : ni reprise ni demande, elle est à déclarer (règle du cabinet). Un administrateur peut la passer en perte.",
  },
  // M2c-7c-1 (plan §5.2.8, §5.0 (7)): what the servicer owes a client back (419) and the recoveries of advances passed
  // as a loss (7714)
  client_credit_owed: {
    label: "Somme à rembourser au client ou à rendre à sa procédure",
    help: "Un client a versé au cabinet plus que ce qui était ouvert (trop-perçu), ou a payé alors que sa procédure collective court (une créance antérieure à son ouverture, ou plus que ce qui était ouvert) : la somme est inscrite au compte 419, à rendre. Un trop-perçu est signalé après 15 jours : remboursez-le au client par virement depuis le compte propre et enregistrez-le (« Enregistrer le remboursement », page du client). Une somme mise de côté pour la procédure est signalée tout de suite : elle est à rendre à la procédure (administrateur, mandataire ou liquidateur), pas au client ; à qui et quand se décide avec l'avocat (OQ-98).",
  },
  client_credit_ledger: {
    label: "Sommes dues aux clients ≠ compte 419",
    help: "Pour ce client, les sommes que le cabinet lui doit encore (trop-perçus, sommes mises de côté) ne valent pas le solde de son compte 419.",
  },
  written_off_recovery_ledger: {
    label: "Recouvrements d'avances passées en perte ≠ compte 7714",
    help: "Les remboursements d'avances passées en perte enregistrés ne valent pas le solde du compte 7714 du cabinet.",
  },
  // M2c-7c-2 (plan §5.2.8): a repayment request's letter not drawn
  repayment_request_document_missing: {
    label: "Lettre de demande de remboursement non produite",
    help: "Une demande de remboursement d'avance a été enregistrée il y a plus d'une heure et sa lettre (PDF) n'est pas encore produite : le client ne la trouve pas dans son espace et elle ne peut pas être imprimée. Après un échec, sa production n'est réessayée que quelques fois : retirez la demande (« Retirer la demande ») et adressez-en une nouvelle ; si l'alerte revient pour la nouvelle demande, prévenez le support.",
  },
  // M2c-7d-1 (plan §6.3; [critic] L14, L17): an old « Tutelle ou curatelle » row to qualify; a seizure served on the
  // servicer and not released — (M2c-7d-2, plan §6.2.6, §6.2.9) payouts and set-off barred whatever the run's net
  // (texts read 2026-11-25: CPCE L211-2 al. 1, C. civ. 1347-7)
  protection_event_to_qualify: {
    label: "Tutelle ou curatelle à préciser",
    help: "Un événement « Tutelle ou curatelle » enregistré avant la distinction des deux mesures n'est pas encore précisé : les reversements du client restent bloqués et ses courriers ne sont pas envoyés. Sur la page du client, « Préciser : tutelle ou curatelle » avec le jugement : une tutelle met fin au mandat (art. 2003 C. civ.) et le tuteur reçoit les courriers ; une curatelle bloque les reversements (règle du cabinet) et ses courriers vont au client, avec copie au curateur.",
  },
  seizure_standing: {
    label: "Saisie entre les mains du cabinet en cours",
    help: "Une saisie des sommes que le cabinet doit à ce client est enregistrée et n'est pas levée : ni virement de reversement ni compensation tant que la mainlevée n'est pas enregistrée (règle du cabinet) — un reversement, même entièrement compensé, est refusé à la validation, et une compensation déjà validée est retenue au débit puis rendue au client par le reversement suivant. L'acte de saisie emporte, « à concurrence des sommes pour lesquelles elle est pratiquée, attribution immédiate au profit du saisissant de la créance saisie » (art. L211-2 du code des procédures civiles d'exécution) ; « La compensation ne préjudicie pas aux droits acquis par des tiers » (art. 1347-7 C. civ.). La déclaration au commissaire de justice et le paiement des causes de la saisie se font hors de Collectoo, avec l'avocat (art. L211-3 et R211-4 du code des procédures civiles d'exécution : le tiers saisi déclare « sur-le-champ » l'étendue de ses obligations). Prioritaire pendant 15 jours après son enregistrement.",
  },
  // M2c-7d-2 (plan §6.3 [critic] M7-MONEY-5): a set-off posted at a payout's debit that an event recorded afterwards
  // shows barred (texts read 2026-11-25: C. com. L622-7 I and III, version of 2021-10-01; review round 1: C. civ. 2008,
  // version of 1804-03-21 — the bar the claim's birth before the opening, TUI-1; a set-off barred by the mandate's end
  // alone and made before it was recorded is not alerted, MLAW-3; the event recorded after the debit's read, CC-3)
  set_off_after_bar: {
    label: "Compensation passée après une procédure, une fin de mandat ou une saisie",
    help: "Au débit d'un reversement, une facture ou une avance du cabinet a été réglée par compensation alors que la situation du client ne le permettait plus à cette date selon la règle du cabinet (créance née avant l'ouverture de la procédure collective du client, liquidation, fin du mandat, saisie en cours ; pour une avance, toute procédure en cours) : l'événement a été enregistré après la lecture que le débit en a faite, qui n'a donc pas pu retenir cette compensation. Une compensation que seule la fin du mandat empêchait, faite avant que le cabinet n'enregistre cette fin, n'est pas signalée : c'est une règle du cabinet, qui tient la date d'enregistrement pour celle où il a connu la fin (à confirmer avec l'avocat, OQ-93). Le texte vise l'ignorance du mandataire : « Si le mandataire ignore la mort du mandant ou l'une des autres causes qui font cesser le mandat, ce qu'il a fait dans cette ignorance est valide » (art. 2008 C. civ.). Le montant indiqué est la part compensée de ces documents (comptabilité). Voyez avec l'avocat s'il faut la garder ou la rendre au client : si elle est maintenue, un administrateur l'enregistre (« Compensation maintenue », avec la réponse de l'avocat en pièce) et l'alerte s'arrête ; la rendre au client ne se fait pas encore dans Collectoo (prévenez le support). En procédure collective, le jugement d'ouverture « emporte, de plein droit, interdiction de payer toute créance née antérieurement au jugement d'ouverture, à l'exception du paiement par compensation de créances connexes » (art. L622-7 I C. com.), et « tout acte ou tout paiement passé en violation des dispositions du présent article est annulé à la demande de tout intéressé ou du ministère public, présentée dans un délai de trois ans » (art. L622-7 III) ; Collectoo ne distingue pas les créances connexes. Prioritaire.",
  },
  // M2c-7d-3 (plan §6.3 [critic] L8, L4, L11; [check 1] gap 9): the declarations and the payouts after a liquidation —
  // their help said from each row's details (claimsToDeclareHelp, postOpeningUnpaidHelp, payoutAfterLiquidationHelp)
  claims_to_declare: {
    label: "Créance du cabinet à déclarer",
    help: "Facture ou avance à déclarer au mandataire judiciaire (au liquidateur en liquidation).",
  },
  post_opening_unpaid: {
    label: "Facture née après le jugement, impayée à son échéance",
    help: "Une facture née après le jugement d'ouverture n'est pas réglée à son échéance.",
  },
  payout_after_liquidation: {
    label: "Reversement au client après sa liquidation",
    help: "Un reversement au client après le jugement de liquidation (art. L641-9 C. com.).",
  },
  top_up_pending: {
    label: "Approvisionnement attendu",
    help: "Un approvisionnement du compte dédié depuis le compte propre du cabinet a été demandé il y a plus d'un jour ouvré et son crédit n'apparaît pas encore sur les relevés importés. Vérifiez le virement depuis le compte propre : il couvre ce que le cabinet doit au compte dédié (frais bancaires, avances). Si son crédit est arrivé sans la référence TOP et n'est pas encore comptabilisé, rattachez-le à cet approvisionnement (« Rattacher à TOP… » sur la ligne) ; s'il a déjà été comptabilisé sans elle, annulez cet approvisionnement (« Annuler ») : sinon Collectoo croit l'approvisionnement encore attendu et commande trop peu.",
  },
};

/**
 * M2c-6b-3a (plan §4, T12, T15): the checks' help once cancellation after download is on (6b-3b's switch) — a file
 * not deposited is cancelled on evidence by two people; an alert of a transfer debited although cancelled says, by its
 * case (its row's details: kind, status, reason), what ops book or ask. The help of the switch off is unchanged.
 */
function checkHelpOn(code: string, details: Record<string, unknown> | null | undefined): string | null {
  if (code === "file_not_marked_sent")
    return `Un fichier a été téléchargé mais personne n'a indiqué l'avoir déposé à la banque, et l'heure limite de dépôt de son jour d'exécution est passée (contrôlé toutes les heures) : déposez-le, puis « Marquer comme transmis ». S'il ne doit pas partir, demandez son annulation depuis sa page, relevés à l'appui (deux personnes) ; d'ici là ses virements restent en cours jusqu'à ce que leurs débits soient comptabilisés depuis le relevé (${FILE_BOOKED_WHEN}). Un fichier jamais déposé n'apparaît sur aucun relevé : son annulation peut être demandée une fois importés les relevés de son jour d'exécution et du jour ouvré suivant.`;
  if (code !== "transfer_already_debited") return null;
  const kind = typeof details?.kind === "string" ? details.kind : null;
  const status = typeof details?.status === "string" ? details.status : null;
  const reason = typeof details?.reason === "string" ? details.reason : null;
  if (reason === "client_payout_debited_late")
    return "Un virement annulé de ce client a peut-être été débité en retard (relevé, sous sa référence, dans une ligne groupée de son lot ou sans nos références) : ce reversement reste hors des fichiers pour ne pas payer deux fois les mêmes encaissements — s'il est déjà dans un fichier téléchargé, demandez à la banque de ne pas l'exécuter. Comptabilisez d'abord ce débit dans « Débits et retours » (« Virement hors reversement »), après avoir annulé ce reversement s'il reprend les mêmes encaissements : la retenue cesse ensuite ; si la page ne permet pas de le comptabiliser, demandez à la banque le détail de ce débit et prévenez le support.";
  if (reason === "payment_refund_debited_late")
    return "Un remboursement annulé de ce paiement a peut-être été exécuté en retard (relevé) : ce remboursement reste hors des fichiers pour que le payeur ne soit pas remboursé deux fois — s'il est déjà dans un fichier téléchargé, demandez à la banque de ne pas l'exécuter. Rattachez d'abord ce débit (« Débits et retours »), ou annulez ce remboursement.";
  if (kind === "sweep" && status === "cancelled")
    return "Une quote-part du cabinet annulée a été virée malgré tout (relevé) : aucune nouvelle quote-part n'est mise dans un fichier tant que son débit n'est ni comptabilisé ni revenu. Comptabilisez-le dans « Débits et retours » (« Comptabiliser… », puis « Virement au compte propre » de cette quote-part).";
  if (kind === "sweep")
    return "Cette quote-part du cabinet a été calculée alors qu'une quote-part annulée, exécutée en retard par la banque, avait déjà viré cette somme : son fichier n'est plus servi. S'il n'a pas été déposé, faites-le annuler depuis sa page, relevés à l'appui (deux personnes) : la quote-part sera recalculée ; s'il l'a été, demandez à la banque de ne pas l'exécuter.";
  if (status === "cancelled")
    return kind === "refund"
      ? "Un remboursement annulé après téléchargement a été débité malgré tout (relevé, sous sa référence, dans une ligne groupée de son lot ou sans référence) : il ne peut pas encore être comptabilisé. Ne refaites pas ce remboursement, voyez avec la banque et prévenez le support."
      : // M2c-6b-3a-2 (E): its run still in flight, the debit is its payout (the late predecessor)
        "Un reversement dont le virement a été annulé après téléchargement a été débité malgré tout (relevé, sous sa référence, dans une ligne groupée de son lot ou sans référence) : ne refaites aucun virement. Comptabilisez ce débit dans « Débits et retours » (« Comptabiliser… ») : son reversement encore en cours, comme « Débit d'un reversement » (le reversement est comptabilisé comme payé) ; terminé, comme « Virement hors reversement ». L'alerte cesse ensuite.";
  // review round 1 (pages-texts-3, pages-texts-6): a debit without our references only may be the replaced transfer's;
  // dated on or after this one's execution in its downloaded file, it may be this one's too — booked as its debit then
  // (« Comptabiliser… » proposes it) — and its file's cancellation is refused while it is open
  // M2c-6b-3a-2 (E, T15): a payout's re-issue — the debit of the transfer it replaces is its run's payout (the late
  // predecessor): booked, this one is cancelled and the hold ends; in a downloaded file, that file cancelled first
  if (kind === "payout")
    return "Un relevé montre le débit, ou un débit sans nos références qui peut l'être, du virement qu'il remplace (exécuté plus tard malgré tout) : ce virement reste hors des fichiers pour ne pas payer deux fois. Ne refaites aucun virement. S'il est déjà dans un fichier téléchargé, demandez à la banque de ne pas l'exécuter et faites annuler ce fichier, relevés à l'appui (deux personnes), avant de comptabiliser ce débit : un débit sans nos références de son montant peut aussi être sa propre exécution — « Comptabiliser… » le propose alors comme son débit —, et l'annulation de ce fichier est refusée tant que ce débit n'est ni comptabilisé ni classé. Sinon, comptabilisez ce débit dans « Débits et retours » (« Comptabiliser… », « Débit d'un reversement ») : le reversement est comptabilisé comme payé, ce virement annulé, et la retenue cesse ; s'il ne peut pas y être comptabilisé, demandez à la banque le détail de ce débit et prévenez le support.";
  return "Un relevé montre le débit, ou un débit sans nos références qui peut l'être, du virement qu'il remplace (exécuté plus tard malgré tout) : ce virement reste hors des fichiers pour ne pas payer deux fois. Ne refaites aucun virement. S'il est déjà dans un fichier téléchargé, demandez à la banque de ne pas l'exécuter : un débit sans nos références de son montant peut aussi être sa propre exécution — « Comptabiliser… » le propose alors comme son débit —, et l'annulation de ce fichier est refusée tant que ce débit n'est ni comptabilisé ni classé. Sinon, voyez ce débit dans « Débits et retours » ; s'il ne peut pas y être comptabilisé, demandez à la banque le détail de ce débit et prévenez le support.";
}

/** A waiting line as « remittance_breach_held »'s details name it (private.remittance_breach_held). */
type HeldLine = { booking_date?: unknown; amount_minor?: unknown; currency?: unknown; end_to_end_id?: unknown };

const HELD_DAYS_NAMED = 10;
const HELD_LINES_NAMED = 3;

/** « et 2 autres », « et 1 autre ligne »… after a list cut short; empty when nothing was cut. */
function andOthers(rest: number, noun = ""): string {
  if (rest <= 0) return "";
  const s = rest > 1 ? "s" : "";
  return noun ? ` et ${rest} autre${s} ${noun}${s}` : ` et ${rest} autre${s}`;
}

/**
 * M2c-6b-3b part 2 (CPCE-08): the help of « remittance_breach_held » from its row's details — the label's own text,
 * then what holds the row back: the business days no imported statement covers yet (`uncovered_days`, the first ten
 * named, `uncovered_count` all of them; a statement counts for a day only once established after its end — review
 * round 1, dt-1), a break in the balances of two imported statements (`balance_break`), or the lines that may be
 * another transfer's debit (`waiting`, the first three named, `waiting_count` all of them; each stops holding
 * `bound_days` business days after its date when « Comptabiliser… » does not propose it as that transfer; several
 * lines are each told what to do — tests-ui-4). Neither: the facts moved while the check ran, and the next one judges
 * the run again. Dates and amounts
 * are the row's (the statements' and the ledger's), never computed here; the alert gives no deadline of its own.
 */
export function breachHeldHelp(details: Record<string, unknown> | null | undefined): string {
  const base = CHECK_LABEL.remittance_breach_held.help;
  const days = Array.isArray(details?.uncovered_days)
    ? details.uncovered_days.filter((d): d is string => typeof d === "string")
    : [];
  const lines: HeldLine[] = Array.isArray(details?.waiting) ? (details.waiting as HeldLine[]) : [];
  const parts: string[] = [];
  if (days.length > 0) {
    const total = typeof details?.uncovered_count === "number" ? details.uncovered_count : days.length;
    const named = days.slice(0, HELD_DAYS_NAMED);
    // review round 1 (dt-1): a day is named when no imported statement covers it (private.statement_covers) — also
    // when a statement of that day is imported but established during it, or is a CSV ending on it: never « missing ».
    // M2c-6b-3b part 3 (PR #39's known limit): a CSV's period is its lines' first and last booking dates
    // (private.ingest_statement) and it covers the days from its first operation's to the day before its last one's —
    // so the hint is worded by operations (« exportez jusqu'au jour suivant » proved nothing when that day had none)
    const list = named.map((d) => frenchDate(d)).join(", ");
    // review round 1 (dt3-csv-hint-last-day-not-named): the export's two ends by date — the first day (the row's days
    // are in order) and the last: the row's own (`last_uncovered_day`, also beyond the 31 days it names), else the last
    // of its days when they are all there; never a day the row does not give (an older row, its days cut: the rule)
    const last =
      typeof details?.last_uncovered_day === "string"
        ? details.last_uncovered_day
        : total <= days.length
          ? days[days.length - 1]
          : null;
    const ends = `une opération datée au plus tard du ${frenchDate(days[0])} (le premier de ces jours) et une opération postérieure ${last ? `au ${frenchDate(last)} (le dernier)` : "au dernier"}`;
    parts.push(
      `Aucun relevé importé du compte de fonds de tiers ne couvre encore les jours ouvrés suivants : ${list}${andOthers(total - named.length)}. Importez un relevé de ces jours établi par la banque après leur fin : un relevé établi pendant l'un d'eux ne compte pas pour ce jour, ni le jour de la dernière opération d'un export CSV, ni un jour avant sa première : exportez une période qui contient ${ends}.`,
    );
  }
  if (details?.balance_break === true)
    parts.push(
      "Deux relevés importés de la période ne se suivent pas (le solde d'ouverture de l'un ne reprend pas le solde de clôture du précédent) : importez le relevé manquant entre eux.",
    );
  if (lines.length > 0) {
    const total = typeof details?.waiting_count === "number" ? details.waiting_count : lines.length;
    const shown = lines.slice(0, HELD_LINES_NAMED);
    const named = shown
      .map((w) => {
        const date = typeof w.booking_date === "string" ? frenchDate(w.booking_date) : "?";
        const amount = money(
          typeof w.amount_minor === "string" ? w.amount_minor : null,
          typeof w.currency === "string" ? w.currency : "EUR",
        );
        const ref = typeof w.end_to_end_id === "string" ? ` ${w.end_to_end_id}` : "";
        return `la ligne du ${date} de ${amount}, qui peut être le débit du virement${ref}`;
      })
      .join(" ; ");
    const bound = typeof details?.bound_days === "number" ? details.bound_days : null;
    // review round 1 (tests-ui-4): several lines — the instruction for each, each line's own transfer
    const several = total > 1;
    const what = several
      ? "pour chacune, comptabilisez-la (« Comptabiliser… ») si c'est le débit du virement en cause, sinon classez-la pour ce qu'elle est."
      : "comptabilisez-la (« Comptabiliser… ») si c'est le débit de ce virement, sinon classez-la pour ce qu'elle est.";
    const s = bound !== null && bound > 1 ? "s" : "";
    parts.push(
      `Classez dans « Débits et retours » ${named}${andOthers(total - shown.length, "ligne")} : ${what}${
        bound !== null
          ? ` Une ligne que « Comptabiliser… » ne propose pas comme ${several ? "le virement en cause" : "ce virement"} cesse de retenir l'enregistrement ${bound} jour${s} ouvré${s} après sa date : si rien d'autre ne le retient, le dépassement est alors enregistré « bloqué : débit possible non comptabilisé ».`
          : ""
      }`,
    );
  }
  if (parts.length === 0)
    parts.push(
      "Les relevés ou les lignes en cause ont changé pendant le contrôle : le reversement sera réexaminé au prochain contrôle.",
    );
  return `${base} ${parts.join(" ")}`;
}

/** « le plus ancien : N jour(s) », a check result's oldest age on « Contrôles » (review round 1 of M2c-6b-3b part 2,
 *  tests-ui-5: its noun agreeing with its number). */
export function checkOldestDays(n: number): string {
  return `le plus ancien : ${n} jour${n > 1 ? "s" : ""}`;
}

/** M2c-7e-1 review round 1 (TUI-1): servicer_shortfall when no own account is chosen (the same run's
 *  top_up_account_missing): the hourly job orders nothing then. */
const SERVICER_SHORTFALL_NO_OWN_ACCOUNT =
  "Le cabinet doit de l'argent au compte dédié (avances, frais bancaires, pertes) au-delà des approvisionnements demandés. Aucun compte propre n'est choisi (Paramètres › Facturation) : Collectoo ne peut pas le commander. Approvisionnez le compte dédié à la main depuis le compte propre, ou choisissez le compte propre.";

export function checkLabel(
  code: string,
  opts?: { cancellationAfterDownload?: boolean; details?: Record<string, unknown> | null; noOwnAccount?: boolean },
): { label: string; help: string } {
  const l = CHECK_LABEL[code] ?? { label: code, help: "" };
  if (code === "servicer_shortfall" && opts?.noOwnAccount) return { label: l.label, help: SERVICER_SHORTFALL_NO_OWN_ACCOUNT };
  // M2c-6b-3b part 2: the held rows' alert names its days and lines whichever the switch (raised only for a chain)
  if (code === "remittance_breach_held" && opts?.details) return { label: l.label, help: breachHeldHelp(opts.details) };
  // M2c-7d-3: the declarations' alerts and the payouts after a liquidation, from their row's details (the switch read by
  // SQL: the row's `cancellable`)
  if (code === "claims_to_declare" && opts?.details) return { label: l.label, help: claimsToDeclareHelp(opts.details) };
  if (code === "post_opening_unpaid" && opts?.details) return { label: l.label, help: postOpeningUnpaidHelp(opts.details) };
  if (code === "payout_after_liquidation" && opts?.details)
    return { label: l.label, help: payoutAfterLiquidationHelp(opts.details) };
  const on = opts?.cancellationAfterDownload ? checkHelpOn(code, opts.details) : null;
  return on ? { label: l.label, help: on } : l;
}

/** The checks of the transfers and their files (M2c-6a, design §15; its review's T3 and T6). */
const TOP_UP_CHECKS = new Set(["servicer_shortfall", "top_up_pending", "top_up_order_failed"]);

/** The words of a check's link on « Contrôles » (plan §7.4: « Réapprovisionner » on servicer_shortfall). */
export function checkLinkLabel(code: string): string {
  if (code === "servicer_shortfall") return "Réapprovisionner";
  if (code === "top_up_account_missing") return "Choisir le compte propre";
  return "Ouvrir";
}

const TRANSFER_CHECKS = new Set([
  "transfer_not_filed",
  "transfer_not_debited",
  "payee_name_mismatch",
  "payee_name_not_epc",
  "iban_not_sepa",
  "file_not_downloaded",
  "file_not_marked_sent",
  "transfer_file_failed",
  "transfer_file_pending",
  "transfer_already_debited",
  // M2c-6b-1
  "cancelled_transfer_debited",
  "transfer_debited_twice",
  "transfer_not_handed_out",
  "payout_returned",
  "sweep_returned",
  "payout_overrun",
  "servicer_funds_unswept",
  "top_up_pending",
  // M2c-6b-2a
  "transfer_unknown",
  "double_payout_open",
]);

/**
 * Where a check result leads (« Contrôles »): the payment, the statement, the queue that holds what ages, the run,
 * (review M2c-5b F2) the invoice or credit note it is about — `invoice_overdue`, `credit_refund_owed` —, and (M2c-6a)
 * the transfer file, or « Virements ».
 */
export function checkSubjectLink(r: {
  code: string;
  subject_type: string;
  subject_id: string | null;
  details?: Record<string, unknown> | null;
}): string | null {
  // M2c-7d-3: an advance to declare, a payout after a liquidation, a set-off after a bar lead to the client's events,
  // where the declaration and the client's procedure are recorded
  const client = typeof r.details?.client_id === "string" ? r.details.client_id : null;
  // M2c-7e-1 (plan §7.4): what the servicer owes the dedicated account leads to « Approvisionnements du compte dédié »
  // on « Virements » (the hourly orders, the own account's file); no own account chosen, to « Facturation »
  if (TOP_UP_CHECKS.has(r.code)) return "/backoffice/reversements/virements#approvisionnements";
  if (r.code === "top_up_account_missing") return "/backoffice/parametres/facturation";
  if (
    client &&
    ((r.code === "claims_to_declare" && r.subject_type === "client_advance") ||
      r.code === "payout_after_liquidation" ||
      r.code === "set_off_after_bar")
  )
    return `/backoffice/clients/${client}/reversement#evenements`;
  if (r.subject_type === "payment" && r.subject_id)
    return `/backoffice/encaissements/paiements/${r.subject_id}`;
  if (r.subject_type === "bank_statement" && r.subject_id)
    return `/backoffice/encaissements/releves/${r.subject_id}`;
  // review M2c-6b-2d round 1 (pages-e2e-3): a statement line left to ops (transfer_unknown, transfer_debited_twice,
  // transfer_not_handed_out) is on « Débits et retours », at its row; our transfer lines left unbooked are there too
  if (r.subject_type === "bank_transaction" && r.subject_id)
    return `/backoffice/encaissements/debits#ligne-${r.subject_id}`;
  if (r.code === "bank_line_unbooked") return "/backoffice/encaissements/debits";
  if (r.code === "debit_unclassified")
    return "/backoffice/encaissements/debits";
  if (r.code === "duplicate_unresolved")
    return "/backoffice/encaissements/debits?onglet=doublons";
  if (r.code === "unmatched_ageing" || r.code === "unallocated_ageing")
    return "/backoffice/encaissements/a-traiter";
  // M2c-4: a run's checks lead to the run, a client's deadlines to « Reversements »
  if (r.subject_type === "remittance_run" && r.subject_id)
    return `/backoffice/reversements/${r.subject_id}`;
  if (r.subject_type === "commission_invoice" && r.subject_id)
    return `/backoffice/reversements/factures/${r.subject_id}`;
  if (r.code.startsWith("remittance_")) return "/backoffice/reversements";
  // M2c-6a: a file's alert leads to the file, the others of the transfers to « Virements »
  if (r.subject_type === "transfer_file" && r.subject_id)
    return `/backoffice/reversements/virements/${r.subject_id}`;
  if (TRANSFER_CHECKS.has(r.code)) return "/backoffice/reversements/virements";
  return null;
}

/**
 * How a refund is executed (M2c-6a review, tests-ui#8): only an explicit choice is sent; without one the database
 * decides — the transfer file when the payment's account is the servicer's active dedicated account in EUR and the IBAN
 * is in the SEPA scheme, by hand otherwise.
 */
export function refundExecutionMode(
  value: string,
): "file" | "manual" | undefined {
  return value === "file" || value === "manual" ? value : undefined;
}

/**
 * What the payment's page tells ops about its pending refund, after « demandé : » (integration of the M2c-6a review):
 * a refund in the transfer file is never executed by hand too (risk R4: paid twice); one by hand needs its RFD id as
 * the end-to-end reference. With the sheet's default the database chose, so this is where ops read which it is. Its
 * transfer (review round 7): once in a downloaded or sent file, the page names that file instead of « the next one ».
 */
export function pendingRefundInstruction(
  inFile: boolean,
  transfer?: RefundTransfer | null,
): string {
  // review round 7 (round 6's verifier, N2): its transfer already in a downloaded or sent file — not « the next file »
  const file =
    inFile && refundInDownloadedFile(transfer) ? transfer?.file : null;
  if (file)
    return `il est dans le fichier de virements ${file.number}, déjà téléchargé, avec la référence ci-dessous comme référence de bout en bout ; ne l'exécutez pas dans la banque.`;
  if (inFile)
    return "il part dans le prochain fichier de virements (« Virements »), avec la référence ci-dessous comme référence de bout en bout ; ne l'exécutez pas dans la banque.";
  return "exécutez le virement dans la banque avec la référence ci-dessous saisie comme « référence de bout en bout ».";
}

/** A refund's transfer as the payment's page reads it: its status and the file it is in (none before a file). */
export type RefundTransfer = {
  status: string;
  file: {
    id: string;
    number: string;
    status: string;
    download_count: number;
  } | null;
};

/** The refunds' transfers by refund id, from the refund rows (their transfer) and the transfers read with their file. */
export function refundTransfers(
  refunds: { id: string; transfer_id: string | null }[],
  transfers: {
    id: string;
    status: string;
    transfer_file: RefundTransfer["file"];
  }[],
): Map<string, RefundTransfer> {
  const byId = new Map(
    transfers.map((t) => [
      t.id,
      { status: t.status, file: t.transfer_file ?? null },
    ]),
  );
  const out = new Map<string, RefundTransfer>();
  for (const r of refunds) {
    const t = r.transfer_id ? byId.get(r.transfer_id) : undefined;
    if (t) out.set(r.id, t);
  }
  return out;
}

/**
 * Review round 6 (round 5's verifier): the refund's transfer is in a file already downloaded (or sent) — that file may
 * still pay it, so the refund is not cancelled until its debit, or its rejection, is read from the statement (the
 * database refuses: `in_downloaded_file`). « Annuler » is not offered then; the page says why (as the run's page).
 */
export function refundInDownloadedFile(
  transfer: RefundTransfer | null | undefined,
): boolean {
  if (!transfer || transfer.status !== "in_file" || !transfer.file)
    return false;
  return (
    transfer.file.download_count > 0 ||
    transfer.file.status === "downloaded" ||
    transfer.file.status === "sent"
  );
}

/** Whether « Annuler » is offered on a refund: requested, and its transfer (if any) not in a downloaded file. */
export function refundCancellable(
  status: string,
  transfer: RefundTransfer | null | undefined,
): boolean {
  return status === "requested" && !refundInDownloadedFile(transfer);
}

/**
 * What the payment's page says in place of « Annuler » for a refund whose transfer is in a downloaded file. M2c-6b-1
 * review round 2 (L6): it leaves « en cours » when its debit is booked from the statement (then its return, if one
 * comes); a refund the bank does not execute leaves no line (REFUND_NOT_EXECUTED).
 */
export function refundInDownloadedFileNote(fileNumber: string, cancellationAfterDownload = false): string {
  // M2c-6b-3a (plan §4, T11): once cancellation after download is on, the refund is cancelled once its transfer is
  if (cancellationAfterDownload)
    return `Le virement de ce remboursement est dans le fichier ${fileNumber}, déjà téléchargé : pour annuler le remboursement, faites d'abord annuler ce virement depuis la page du fichier (relevés à l'appui, confirmée par une autre personne) ; sinon il reste « en cours » jusqu'à ce que son débit soit comptabilisé depuis le relevé bancaire (${REFUND_BOOKED_WHEN}). ${REFUND_RETURNED} ${REFUND_NOT_EXECUTED_ON}`;
  return `Le virement de ce remboursement est dans le fichier ${fileNumber}, déjà téléchargé : il reste « en cours » jusqu'à ce que son débit soit comptabilisé depuis le relevé bancaire (${REFUND_BOOKED_WHEN}), et le remboursement ne peut pas être annulé d'ici là (l'annulation après téléchargement n'est pas encore disponible). ${REFUND_RETURNED} ${REFUND_NOT_EXECUTED} Gardez le fichier tel quel, vérifiez le relevé, voyez avec la banque et prévenez le support.`;
}

/** What the refund sheet says the RFD reference becomes, by the execution chosen (« auto »: the database's default). */
export function refundModeEffect(mode: string): string {
  if (mode === "file")
    return "le virement part dans le prochain fichier de virements (« Virements ») ; ne l'exécutez pas aussi à la main.";
  if (mode === "manual")
    return "dans la banque, saisissez-la comme « référence de bout en bout » du virement (pas seulement dans le libellé), c'est elle qui fait reconnaître son débit sur le relevé.";
  return "le virement part dans le prochain fichier de virements si le compte de fonds de tiers peut le payer (en euros, vers un IBAN de la zone SEPA) ; sinon il est à exécuter dans la banque avec cette référence de bout en bout. La page du paiement dit lequel une fois la demande faite.";
}

/** Why a payment made to the client directly was refused (direct_payment.refusal_code). */
export const DIRECT_REFUSAL: Record<string, string> = {
  more_than_due: "Montant supérieur à ce que doit le dossier à cette date",
  nothing_due: "Rien n'est dû sur ces factures à cette date",
  before_servicing_start: "Date antérieure à la reprise du dossier",
  file_closed: "Dossier clos",
  // the job failed after its retries (review M2b-6: a dead-lettered direct payment is refused, never left « En cours »)
  failed:
    "Le traitement a échoué après plusieurs essais : contactez le support",
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
  if (
    message.includes("reason is required") ||
    message.includes("refused: reason_required")
  )
    return "reason_required";
  if (
    message.includes("the payment changed") ||
    message.includes("payment_changed")
  )
    return "payment_changed";
  if (message.includes("reason does not match"))
    return "refund_reason_mismatch";
  if (message.includes("more than what is left")) return "refund_too_much";
  if (message.includes("IBAN is required")) return "refund_iban_required";
  if (message.includes("payee's name is required"))
    return "refund_name_required";
  if (message.includes("invalid IBAN")) return "iban_invalid";
  if (message.includes("cannot be refunded from here"))
    return "refund_not_possible";
  if (message.includes("no longer pending")) return "refund_not_pending";
  // M2c-6a: a refund in a file already downloaded is cancelled once its transfer is (review T1: two people, the
  // statement's evidence); a file mode the account cannot pay
  // M2c-6a review, round 4 (G2): the debit of a re-issued refund's old reference while the re-issue is in a downloaded
  // file (checked before the general « in a downloaded file »)
  if (message.includes("reissue_in_downloaded_file"))
    return "refund_reissue_in_downloaded_file";
  // review round 1 (DP-1, DP-2): a refund not handed out, a cancelled transfer that bars it possibly the line
  if (message.includes("refund refused: cancelled_transfer_matches"))
    return "refund_cancelled_transfer_matches";
  if (
    message.includes("already downloaded") ||
    message.includes("in_downloaded_file")
  )
    return "refund_in_downloaded_file";
  // M2c-6a review, round 3 (E2): its transfer, or one it re-issues, was debited already: cancelling it refunds twice
  if (message.includes("refund refused: already_debited"))
    return "refund_already_debited";
  if (message.includes("pays no transfer file"))
    return "transfer_not_paying_account";
  // M2c-6a review (T3): what a SEPA transfer file cannot carry
  if (message.includes("payee_name_not_epc"))
    return "refund_payee_name_not_epc";
  if (message.includes("iban_not_sepa")) return "refund_iban_not_sepa";
  if (
    message.includes("a refund is pending") ||
    message.includes("debit link refused: refund_pending")
  )
    return "refund_pending";
  if (message.includes("already_linked")) return "already_linked";
  if (message.includes("already_booked")) return "already_booked";
  if (message.includes("not_a_fee")) return "not_a_fee";
  if (message.includes("not_an_own_credit")) return "not_an_own_credit";
  if (message.includes("own credit release refused: not_own_credit"))
    return "not_own_credit";
  if (message.includes("own_account_unknown")) return "own_account_unknown";
  if (
    message.includes("transfer_not_pending") ||
    message.includes("bank booking refused: amount_differs")
  )
    return "top_up_differs";
  if (message.includes("not_a_loss")) return "not_a_loss";
  if (message.includes("not_explainable")) return "not_explainable";
  // review M2c-6b-1 round 3 (M1): a credit carrying our RMT/SWP id is our transfer coming back, never a debtor's payment
  if (message.includes("own credit release refused: own_transfer_line"))
    return "own_credit_own_transfer_line";
  // round 4 (N1): nor a held line carrying one, released (public.resolve_duplicate) — round 5 (Q4): its own words, the
  // line staying in « Doublons possibles »
  if (message.includes("duplicate release refused: own_transfer_line"))
    return "duplicate_own_transfer_line";
  // round 4 (N2): a credit carrying our TOP id is our top-up, never a debtor's payment
  if (message.includes("own credit release refused: top_up_line"))
    return "own_credit_top_up_line";
  // review M2c-6b-1 (money-1, K1): our payouts' and sweeps' lines are booked from the statement, never linked
  if (message.includes("own_transfer_line")) return "own_transfer_line";
  // M2c-6b-2c (plan §4.1): the lines « Comptabiliser… » books, never a fee nor explained
  if (message.includes("debit link refused: payout_candidate")) return "payout_candidate";
  if (message.includes("debit link refused: client_payout_line")) return "client_payout_line";
  if (message.includes("debit link refused: own_transfer_out_line")) return "own_transfer_out_line";
  if (message.includes("before_previous_return")) return "link_before_return";
  if (message.includes("payment_returned")) return "link_payment_returned";
  // M2c-7a: a return of a remitted payment whose cover could not be recorded (LG009)
  if (message.includes("posting_failed") && message.includes("LG009")) return "remitted_cover_failed";
  if (message.includes("posting_failed")) return "link_posting_failed";
  if (message.includes("amount_exceeds") || message.includes("amount_differs"))
    return "link_amount";
  if (message.includes("debit link refused")) return "link_refused";
  if (
    message.includes("bank booking refused") ||
    message.includes("own credit release refused")
  )
    return "booking_refused";
  if (message.includes("already decided")) return "already_decided";
  if (message.includes("client's statement is required"))
    return "direct_evidence";
  if (message.includes("before the servicing started")) return "direct_date";
  if (message.includes("invoices of this file only")) return "direct_items";
  if (message.includes("the file is not open")) return "file_not_open";
  if (message.includes("invalid amount")) return "amount_invalid";
  if (message.includes("lock") || message.includes("canceling statement"))
    return "allocation_busy";
  return "unknown";
}

/**
 * Errors of public.link_debit, by the kind ops asked for (review M2c-6b-1 round 3, M2): private.post_bank_bookings
 * refuses a top-up and a loss on our lines with the same « bank booking refused: own_transfer_line ». On a top-up (kind
 * `own_credit`) the line is a credit carrying our RMT/SWP id — our transfer coming back — so it gets the credit's words
 * (as public.release_own_credit's refusal does); every other refusal as debitErrorCode reads it.
 */
export function linkDebitErrorCode(message: string, kind: string): ErrorCode {
  const code = debitErrorCode(message);
  return code === "own_transfer_line" && kind === "own_credit" ? "own_credit_own_transfer_line" : code;
}

/**
 * M2c-6b-2c (plan §4.1; critic F9, L8): a debit « À classer » lists because « Comptabiliser… » books it — a transfer of
 * ours may be it (payout_amount_match), it went to a client's payout IBAN (client_payout_iban) or to one of our own
 * accounts (own_transfer_out): public.link_debit refuses to classify it without booking (and, but for the first, to
 * book it as a fee), so the page does not offer « Classer sans comptabiliser » on it. Review 6b-2c: (money-1) nor a
 * payment's return or its loss (payout_candidate, client_payout_line) — also when the job's own review names the line
 * (its bookable_as n says « Comptabiliser… » books it) — never a debit the bank flags as a return, which that screen does
 * not book (bookable_as null): it keeps both (round 2); (money-2) a credit the bank flags as a return from a client's
 * payout IBAN (bookable_as n: an unplanned payout's return, « Virement revenu ») takes neither the explanation nor
 * « Remboursement revenu » (client_payout_line).
 */
export function linkGuarded(o: {
  direction: string;
  review_reason?: string | null;
  bookable_as?: string | null;
}): boolean {
  if (o.direction === "credit") return o.bookable_as === "n";
  return (
    o.direction === "debit" &&
    (o.bookable_as === "n" ||
      o.review_reason === "payout_amount_match" ||
      o.review_reason === "client_payout_iban" ||
      o.review_reason === "own_transfer_out")
  );
}

/**
 * Review 6b-2c round 3 (other-debit-return-blocked-by-returned-payout-twin; COMPLIANCE OQ-86's default): whether
 * « À classer » withholds a payment's return and its loss on a line — linkGuarded's lines, but for a debit
 * « À classer » lists as payout_amount_match where public.debit_link_options says « Lier » takes the return
 * (`returnGuard` null: rule 3b's only candidates are payouts returned, or cancelled with their run ended, and the line
 * goes to no client's payout IBAN — a debtor's payment the bank takes back without flagging it, an unpaid cheque, is
 * linked to that payment). While the options are not read (`undefined`) or the database refuses (its code), withheld.
 */
export function paymentLinksGuarded(
  o: { direction: string; review_reason?: string | null; bookable_as?: string | null },
  returnGuard?: string | null,
): boolean {
  if (!linkGuarded(o)) return false;
  return !(o.direction === "debit" && o.review_reason === "payout_amount_match" && returnGuard === null);
}

/**
 * Review 6b-2c round 3 (fix2-notdone:fee-explanation-text): link_debit's payout_candidate on a line « Comptabiliser… »
 * does not offer (`offersBooking` false: a debit the bank flags as a return, of a payout's amount) — its own words,
 * which never point to that screen; every other code as it is.
 */
export function guardRefusalCode(code: ErrorCode, offersBooking: boolean): ErrorCode {
  return code === "payout_candidate" && !offersBooking ? "payout_candidate_not_bookable" : code;
}
