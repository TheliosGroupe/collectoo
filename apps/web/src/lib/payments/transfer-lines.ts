// M2c-6b-2b (plan docs/design/m2c-6b-2-plan.md §3.10, §7.2): the ops command `public.book_transfer_line` and its
// preview refuse with `transfer line booking refused: <code>` (check_violation); this module turns a refusal, or the
// two SQLSTATEs the command gives a code of its own, into a code and its French label. Pure: the pages that book a
// line (« Débits et retours », 6b-2c) use it; raw database text never reaches the page.
import { errorText } from "../boarding/forms";

/** Each refusal of the command, the preview and the options, in French (plan §3.10). */
export const TRANSFER_LINE_REFUSAL: Record<string, string> = {
  bad_request: "La demande est incomplète ou mal formée : rouvrez la ligne et recommencez.",
  held_duplicate:
    "Cette ligne est retenue comme doublon possible : traitez-la d'abord dans « Doublons possibles ».",
  already_booked: "Cette ligne est déjà comptabilisée.",
  already_linked: "Cette ligne est déjà rattachée ou classée.",
  line_is_payment:
    "Cette ligne a été enregistrée comme le paiement d'un débiteur : elle ne peut pas être comptabilisée ici. Prévenez le support.",
  parts_do_not_add_up: "Les montants choisis ne font pas exactement le montant de la ligne.",
  not_a_transfer_line:
    "Cette ligne n'est pas un virement émis (c'est un remboursement, un prélèvement ou le retour d'un paiement) : elle ne se comptabilise pas ainsi.",
  // review LT-6: also a debit line named for an unplanned return that holds no unplanned booking of this transfer
  transfer_unknown:
    "Ce virement n'est pas un virement du cabinet sur ce compte, ou la ligne de débit indiquée ne l'a pas comptabilisé hors reversement.",
  // review LT-6: a transfer of the cabinet of another kind than the part (a quote-part named as a reversement)
  transfer_kind_differs:
    "Ce virement du cabinet n'est pas de ce type (reversement, quote-part du cabinet ou remboursement) : choisissez la comptabilisation qui lui correspond.",
  wrong_direction: "Ce virement ne peut pas être comptabilisé sur une ligne de ce sens (débit ou crédit).",
  not_its_line:
    "Cette ligne ne porte ni la référence de ce virement, ni celle de son lot dans son fichier, et rien ne permet de dire que c'est lui.",
  transfer_cancelled:
    "Ce virement est annulé : son débit se comptabilise comme « Virement hors reversement ».",
  already_debited:
    "Ce virement est déjà débité : un second débit se comptabilise comme « Virement hors reversement ».",
  not_handed_out:
    "Ce virement n'a jamais été remis à la banque (aucun fichier téléchargé) : ce débit ne peut pas encore être comptabilisé. Vérifiez dans la banque d'où vient cet ordre et prévenez le support.",
  transfer_differs: "Ce virement est d'un autre compte ou d'une autre devise que la ligne.",
  run_not_in_flight:
    "Le reversement de ce virement n'est plus en cours : ce débit ne peut pas encore être comptabilisé comme le sien. Prévenez le support.",
  amount_differs: "Le montant ne correspond pas à celui du virement.",
  line_ambiguous:
    "Plusieurs virements du cabinet (reversement, quote-part, remboursement, ou virement annulé que la banque a pu exécuter) ont ce montant vers ce compte : sans notre référence sur la ligne, impossible de savoir lequel la banque a exécuté. Demandez le détail à la banque.",
  batch_ambiguous:
    "Plusieurs combinaisons des virements de ce lot font le montant de la ligne : demandez à la banque le détail du lot.",
  // critic CSO-3, critic2 CSO2-3: also an unsplit entry or a lot credit above the cap
  lot_too_large:
    "Ce lot ou cette écriture compte trop de virements pour être comptabilisé depuis cet écran : prévenez le support.",
  batch_mixed:
    "Ce lot contient des remboursements ou des virements de natures différentes : il ne peut pas être comptabilisé ici. Demandez le détail à la banque.",
  not_cancelled_nor_booked:
    "Ce virement n'est ni annulé, ni débité, ni revenu : comptabilisez la ligne comme « Débit d'un reversement » ; si ce virement n'a jamais été remis à la banque, prévenez le support.",
  // critic2 ML-4 (the page adds the run's number from the refusal's detail)
  run_still_live:
    "Ce virement a été annulé, mais son reversement est toujours en cours : ce débit est le paiement de ce reversement, pas un virement hors reversement. Il ne peut pas encore être comptabilisé ; ne faites pas annuler ce reversement et prévenez le support.",
  // critic2 ML-3
  debit_pending:
    "Un autre débit de ce virement (second débit, ou débit après annulation) figure sur un relevé sans être encore comptabilisé : comptabilisez-le d'abord ; ce retour sera alors celui du virement hors reversement, et rien ne sera reversé deux fois.",
  // critic2 ML-10
  fee_unexplained:
    "L'écart entre la ligne et le virement a le montant d'un virement du cabinet, et le relevé n'indique aucun frais : ce n'est sans doute pas des frais (virement débité deux fois, ou un autre virement dans la même écriture). Demandez le détail à la banque.",
  // critic F6 (the page adds the run's number from the refusal's detail)
  client_run_cancellable:
    "Les sommes que ce virement a payées sont dans un reversement de ce client validé mais pas encore remis à la banque : faites d'abord annuler ce reversement par un administrateur (ces sommes reviennent en attente et ce débit en sera déduit), puis recommencez.",
  client_unknown: "Ce client n'est pas un client du cabinet.",
  client_iban_mismatch: "Le compte crédité n'est pas un compte de reversement enregistré de ce client.",
  client_ambiguous:
    "Ce compte de reversement est enregistré pour plusieurs clients du cabinet : prévenez le support.",
  payout_in_flight_matches:
    "Un virement du cabinet en cours de ce montant vers ce compte (reversement, quote-part ou remboursement) peut être ce débit : comptabilisez-le comme son débit (« Débit d'un reversement »), ou rattachez-le au remboursement.",
  // critic F12
  cancelled_payout_matches:
    "Un virement annulé ou revenu de ce montant vers ce compte a pu être exécuté par la banque : comptabilisez ce débit comme son « Virement hors reversement ».",
  // critic F13
  payout_not_handed_out_matches:
    "Un reversement de ce client de ce montant n'a jamais été remis à la banque (pas encore dans un fichier téléchargé) : ce débit ne peut pas encore être comptabilisé. Vérifiez dans la banque d'où vient cet ordre et prévenez le support.",
  own_account_unknown: "Le compte crédité n'est pas l'un de nos comptes propres enregistrés.",
  sweep_in_flight_matches:
    "Une quote-part du cabinet en cours de ce montant peut être ce débit : comptabilisez-la comme son débit.",
  // critic L2, L15
  fee_not_allowed:
    "Des frais bancaires ne se comptabilisent ici que sur la ligne même d'un virement du cabinet (son débit, ou son retour signalé par la banque) : ailleurs, ils ne se distinguent pas de l'argent d'un tiers.",
  not_a_return: "Cette ligne n'est pas un crédit qui revient.",
  return_before_debit: "Le débit de ce virement n'est pas comptabilisé, ou il est daté d'après ce retour.",
  // critic F1
  unplanned_open:
    "Ce virement a aussi été exécuté hors reversement, et ce second virement n'est pas revenu : ce retour se comptabilise comme le sien (« Virement revenu », virement hors reversement), pour que rien ne soit reversé deux fois.",
  already_returned: "Ce virement est déjà revenu.",
  return_differs:
    "Ce retour ne correspond pas au virement (montant supérieur, virement sans débit comptabilisé, ou autre virement hors reversement à annuler d'abord).",
  advance_settled:
    "L'avance liée à ce virement a déjà été en partie récupérée : ce retour ne peut pas être comptabilisé ici. Prévenez le support.",
  // critic F8, critic2 ML-6
  unsplit_detail_missing:
    "Le relevé ne détaille pas assez cette écriture (un montant ou les frais de la banque manquent, ou la ligne a été importée avant que Collectoo garde ce détail) : elle ne peut pas être comptabilisée ici. Demandez le détail à la banque et prévenez le support.",
  // critic2 ML-5, CSO2-10
  unsplit_not_bookable:
    "Cette écriture contient autre chose que des virements du cabinet sur ce compte (le paiement d'un débiteur, un autre débit, un remboursement ou un approvisionnement du cabinet), ou deux fois le même virement : elle ne peut pas être comptabilisée ici. Demandez le détail à la banque et prévenez le support.",
  unsplit_parts_differ:
    "Les virements nommés ne sont pas exactement ceux que le relevé détaille dans cette écriture, à leurs montants.",
  split_changed:
    "La situation a changé depuis l'affichage (sommes en attente, brouillon, virements) : rouvrez la ligne pour voir la nouvelle répartition.",
  posting_failed:
    "La comptabilisation a été refusée par les contrôles du grand livre : rien n'est enregistré. Prévenez le support.",
  // the two SQLSTATEs (§3.10): the lock wait, re-raised with the step it waited at (critic2 CSO2-6), and the statement
  // timeout (critic CSO-3)
  busy: "Cette ligne ou un virement qu'elle concerne est en cours de traitement : réessayez dans un instant.",
  allocation_busy:
    "Une imputation ou une validation de reversements est en cours pour ce cabinet : réessayez dans quelques secondes.",
  timeout:
    "La comptabilisation a pris trop de temps et n'a rien enregistré : réessayez ; si cela se répète, prévenez le support.",
};

const REFUSED = /transfer line booking refused: ([a-z_]+)/;

/** The code of an error the command, the preview or the options raised (never the database's text on the page). */
export function transferLineErrorCode(error: { code?: string | null; message?: string | null }): string {
  const message = error.message ?? "";
  const refused = REFUSED.exec(message);
  if (refused) return refused[1];
  // review CSR-1: a deadlock or a serialisation failure aborts the call and records nothing — retried like a lock wait
  if (
    error.code === "55P03" ||
    error.code === "40P01" ||
    error.code === "40001" ||
    message.includes("lock timeout") ||
    message.includes("could not obtain lock") ||
    message.includes("deadlock detected")
  )
    return "busy";
  if (error.code === "57014" || message.includes("statement timeout")) return "timeout";
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("a reason is required")) return "reason_required";
  return "unknown";
}

/** The French text of a code `transferLineErrorCode` returned; « not allowed » and the motif keep their labels. */
export function transferLineErrorText(code: string): string {
  if (code === "not_allowed" || code === "reason_required") return errorText(code);
  return TRANSFER_LINE_REFUSAL[code] ?? errorText("unknown");
}
