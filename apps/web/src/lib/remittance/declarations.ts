import { type ErrorCode, errorText } from "@/lib/boarding/forms";

/**
 * M2c-7d-3 (plan docs/design/m2c-7-plan.md §6.3, §6.4; ADR-0014 « M2c-7d-3 »): the declarations' alerts and the payouts
 * after a liquidation, as « Contrôles » words them from each row's details (every rule is SQL's:
 * private.client_claims_to_declare, client_post_opening_unpaid, client_payouts_after_liquidation), and the refusals of
 * « Enregistrer la suite » and « Compensation maintenue ». Texts quote only what the articles say (read on LibreJustice on
 * 2026-11-25); the servicer's rules are named « règle du cabinet ».
 */

type Details = Record<string, unknown> | null | undefined;

function text(d: Details, k: string): string | null {
  const v = d?.[k];
  return typeof v === "string" && v.length > 0 ? v : null;
}

function day(iso: string | null): string {
  if (!iso || !/^\d{4}-\d{2}-\d{2}$/.test(iso)) return "?";
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

const R622_24 =
  "« deux mois à compter de la publication du jugement d'ouverture au Bulletin officiel des annonces civiles et commerciales »";
const L622_24_AL6 = "« Les délais courent à compter de la date d'exigibilité de la créance »";
const CPC_642 =
  "« Le délai qui expirerait normalement un samedi, un dimanche ou un jour férié ou chômé est prorogé jusqu'au premier jour ouvrable suivant »";
const DECLARED = "« Créances du cabinet déclarées au mandataire judiciaire (ou au liquidateur) »";

/** claims_to_declare: the document, to whom, its deadline and its basis; then what the alert lists and what stops it. */
export function claimsToDeclareHelp(d: Details): string {
  const what =
    text(d, "document_kind") === "invoice"
      ? `Facture ${text(d, "number") ?? ""}`.trim()
      : `Avance du cabinet née le ${day(text(d, "born_on"))}`;
  const to =
    text(d, "liquidation_on") || text(d, "opening_kind") === "liquidation" ? "au liquidateur" : "au mandataire judiciaire";
  const basis = text(d, "deadline_basis");
  // review round 1 (ML-3): the day the two months end (CPC 641 al. 2), « au plus tard » — never « avant le », a day
  // stricter than the article; the extension of CPC 642 is stated below, the alert keeps the day unextended
  const when =
    basis === "publication"
      ? ` au plus tard le ${day(text(d, "deadline"))} (deux mois après la publication du jugement au BODACC le ${day(text(d, "publication_date"))}, art. R622-24 C. com.).`
      : basis === "exigibility"
        ? ` au plus tard le ${day(text(d, "deadline"))} (deux mois après son exigibilité, art. L622-24 C. com. : ${L622_24_AL6} ; l'exigibilité retenue est la date de l'avance, règle du cabinet).`
        : // review round 1 (TUI-1): no command adds a date to a recorded event (append-only): the same event recorded
          // again with it — in liquidation, the liquidator's account confirmed after each recording (7d-1's payee rule)
          ` : date de publication à saisir — une date ne s'ajoute pas à un événement déjà enregistré : enregistrez à nouveau le même événement sur la page du client (même date d'effet), avec la date de publication du jugement au BODACC, dont part le délai de déclaration${text(d, "opening_kind") === "liquidation" ? " ; le compte du liquidateur est alors à confirmer à nouveau par un second administrateur (les reversements restent bloqués jusque-là)" : ""}.`;
  return (
    `${what} à déclarer ${to}${when} ` +
    "Le client est en procédure collective ou en liquidation : le cabinet déclare ses créances au mandataire judiciaire (au liquidateur en liquidation, art. L641-3 C. com.). " +
    "Sont listées, règle du cabinet, chaque facture née avant le jugement d'ouverture (née, par défaut, au premier encaissement qu'elle facture) et chaque avance du cabinet ouverte, quelle que soit sa date (aucune n'est reprise ni demandée tant que la procédure court) ; une facture née après le jugement n'y figure pas. " +
    `Le délai de déclaration est de ${R622_24} (art. R622-24 C. com.) ; pour une créance née après le jugement, ${L622_24_AL6} (art. L622-24 C. com.). ` +
    `La date indiquée est le jour où expirent les deux mois (art. 641 du code de procédure civile, dont les règles s'appliquent sauf disposition contraire, art. R662-1 C. com.) ; ${CPC_642} (art. 642 du même code) : l'alerte suit la date non prorogée, règle du cabinet. ` +
    `Déclarez-la hors de Collectoo, puis enregistrez l'événement ${DECLARED} avec les documents déclarés : l'alerte s'arrête pour chacun. ` +
    "Prioritaire à partir de 15 jours avant la date limite."
  );
}

const L622_17_IV =
  "« Les créances impayées perdent le privilège que leur confère le II du présent article si elles n'ont pas été portées à la connaissance de l'administrateur et, à défaut, du mandataire judiciaire ou, lorsque ces organes ont cessé leurs fonctions, du commissaire à l'exécution du plan ou du liquidateur, dans le délai d'un an à compter de la fin de la période d'observation. » (art. L622-17 IV C. com.)";
const L641_13_III =
  "« A l'exception des frais et dépens de la procédure, les créances impayées perdent le privilège que leur confère le II du présent article si elles n'ont pas été portées à la connaissance du mandataire judiciaire, de l'administrateur lorsqu'il en est désigné ou du liquidateur au plus tard, dans le délai de six mois à compter de la publication du jugement ouvrant ou prononçant la liquidation ou, à défaut, dans le délai d'un an à compter de celle du jugement arrêtant le plan de cession » (art. L641-13 III C. com.)";

/** The bar a post-opening invoice's set-off meets (private.client_set_off_barred's codes), for its help. */
const BAR_CAUSE: Readonly<Record<string, string>> = {
  liquidation: "la liquidation judiciaire du client",
  mandate_ended: "la fin du mandat",
  seizure: "une saisie",
};

/** post_opening_unpaid: the invoice, the text that governs it, what stops the alert. */
export function postOpeningUnpaidHelp(d: Details): string {
  const inLiquidation = Boolean(text(d, "liquidation_on")) || text(d, "opening_kind") === "liquidation";
  const number = text(d, "number");
  const who = number ? `La facture ${number}` : "Cette facture";
  // review round 2: an invoice its run set off in full has no due date of its own; once the debit withheld that set-off
  // (7d-2), the debit's day stands for it (SQL: private.invoice_withheld_on, the row's `withheld_on`)
  const withheld = text(d, "due_date") ? null : text(d, "withheld_on");
  // review round 3: one whose run's payout is not debited, once the client's invoice bar applies (SQL:
  // private.client_set_off_barred), from the day the bar was recorded (the row's `barred_on`, its code `bar`)
  const barred = text(d, "due_date") || withheld ? null : text(d, "barred_on");
  const head = withheld
    ? `${who} est née après le jugement d'ouverture. Elle devait être réglée par compensation sur le reversement du client ; cette compensation a été retenue au débit le ${day(withheld)} : la facture n'est pas réglée, et ce jour tient lieu d'échéance (règle du cabinet).`
    : barred
      ? `${who} est née après le jugement d'ouverture. Elle devait être réglée par compensation sur le reversement du client, qui n'est pas débité ; depuis le ${day(barred)}, jour où le cabinet a enregistré ${BAR_CAUSE[text(d, "bar") ?? ""] ?? "ce qui l'interdit"}, il ne compense plus (règle du cabinet) : la facture n'est pas réglée, et ce jour tient lieu d'échéance (règle du cabinet).`
      : `${who} est née après le jugement d'ouverture et n'est pas réglée à son échéance.`;
  const stops = barred
    ? "l'alerte s'arrête aussi quand elle est réglée, ou quand le reversement est annulé (son avoir annule la facture)."
    : "l'alerte s'arrête aussi quand elle est réglée.";
  const rule =
    "Règle du cabinet : la commission née après le jugement est traitée comme une créance payée à son échéance (une prestation fournie au débiteur pendant la procédure) ; si l'avocat en juge autrement, elle est à déclarer dans les deux mois de son exigibilité (art. L622-24 C. com.) — question ouverte OQ-92.";
  const law = inLiquidation
    ? `${L641_13_III}.`
    : `${L622_17_IV} Collectoo ne connaît pas la fin de la période d'observation : aucune date limite n'est calculée.`;
  return `${head} ${rule} ${law} Portez-la à la connaissance de l'organe de la procédure avec l'avocat, puis enregistrez ${DECLARED} en la désignant ; ${stops}`;
}

/** payout_after_liquidation: the payout made (or about to be) to the client after its liquidation, its exit. */
export function payoutAfterLiquidationHelp(d: Details): string {
  const booked = text(d, "status") === "booked";
  // review round 1 (ML-4, TUI-2): L641-9 I quoted as read (version of 2022-05-15), its qualifier kept, the cut marked
  const head = `Un reversement ${booked ? "payé" : "à payer"} au client après le jugement de liquidation, sur un compte qui n'est pas celui du liquidateur confirmé : le jugement « emporte de plein droit, à partir de sa date, dessaisissement pour le débiteur de l'administration et de la disposition de ses biens composant le patrimoine engagé par l'activité professionnelle […] » ; « Les droits et actions du débiteur concernant son patrimoine sont exercés pendant toute la durée de la liquidation judiciaire par le liquidateur. » (art. L641-9 I C. com.).`;
  if (booked)
    return `${head} Le virement a été débité de notre compte : voyez avec le liquidateur et l'avocat ce qu'il advient de cette somme (ratification par le liquidateur, ou somme reversée au liquidateur : question ouverte OQ-99), puis « Enregistrer la suite » avec sa pièce ; l'alerte reste jusque-là, quel que soit le temps écoulé. Prioritaire.`;
  if (d?.downloaded === false)
    return `${head} Le fichier n'est pas téléchargé : annulez le reversement avant de le télécharger. Prioritaire.`;
  if (d?.cancellable === true)
    return `${head} Annulez-le depuis la page du fichier (annulation en deux temps, relevés à l'appui), ou demandez à la banque de ne pas l'exécuter ; s'il est débité, l'alerte reste jusqu'à ce que la suite soit enregistrée. Prioritaire.`;
  return `${head} Le virement est dans un fichier déjà téléchargé : Collectoo ne peut plus l'annuler ; demandez à la banque de ne pas l'exécuter. S'il est débité, l'alerte reste jusqu'à ce que la suite soit enregistrée. Prioritaire.`;
}

/** What became of a payout made to the client after its liquidation (public.liquidation_payout_disposition.kind). */
export const DISPOSITION_KIND: Readonly<Record<string, string>> = {
  ratified: "Ratifié par le liquidateur",
  repaid_to_liquidator: "Somme reversée au liquidateur",
};

const DISPOSITION_CODE: Readonly<Record<string, ErrorCode>> = {
  already_disposed: "disposition_already",
  not_after_liquidation: "disposition_not_after",
  bad_kind: "disposition_bad_kind",
  evidence_required: "disposition_evidence_required",
  bad_note: "disposition_bad_note",
};

const OUTCOME_CODE: Readonly<Record<string, ErrorCode>> = {
  bad_kind: "outcome_bad_kind",
  not_alerted: "outcome_not_alerted",
  already_recorded: "outcome_already",
  evidence_required: "outcome_evidence_required",
  bad_note: "outcome_bad_note",
};

function code(message: string, prefix: string, table: Readonly<Record<string, ErrorCode>>): ErrorCode {
  if (/not allowed/.test(message)) return "admin_only";
  const m = message.match(new RegExp(`${prefix} refused: (\\w+)`));
  return (m && table[m[1]]) || "unknown";
}

/** « Enregistrer la suite »'s refusal (public.record_liquidation_payout_disposition), as the form's error code. */
export function dispositionErrorCode(message: string): ErrorCode {
  return code(message, "liquidation payout disposition", DISPOSITION_CODE);
}

/** « Compensation maintenue »'s refusal (public.record_set_off_outcome), as the form's error code. */
export function outcomeErrorCode(message: string): ErrorCode {
  return code(message, "set-off outcome", OUTCOME_CODE);
}

/** The refusals in French, as the forms show them. */
export const dispositionRefusal = (message: string): string => errorText(dispositionErrorCode(message));
export const outcomeRefusal = (message: string): string => errorText(outcomeErrorCode(message));
