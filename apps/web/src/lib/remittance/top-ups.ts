import type { ErrorCode } from "@/lib/boarding/forms";
import { money } from "@/lib/payments/statements";

/**
 * M2c-7e-1 (plan docs/design/m2c-7-plan.md §7.1, §7.2, §7.4): « Approvisionnements du compte dédié » on « Virements »
 * (public.top_up_overview), « Rattacher à TOP… » on « Débits et retours » (public.top_up_credit_options,
 * public.book_top_up_credit) and « Périodes où le cabinet devait de l'argent au compte dédié » on « Comptes bancaires »
 * (public.servicer_shortfall_periods). What the servicer owes the dedicated account (its advances, bank fees and losses
 * on 4679) is ordered back every hour from its own account (a TOP… transfer); the own account's file carries the
 * orders; a credit of the dedicated account carrying the TOP id books it. Amounts are integer minor units, as text.
 */

export type TopUpOrder = {
  transfer_id: string;
  end_to_end_id: string;
  amount_minor: string;
  currency: string;
  status: string;
  requested_execution_date: string;
  created_at: string;
  automatic: boolean;
  ordered_by: string | null;
  reason: string | null;
  cancel_reason: string | null;
  cancelled_at: string | null;
  file_id: string | null;
  file_number: string | null;
  cancellable: boolean;
};

export type TopUpFile = {
  id: string;
  number: string;
  status: string;
  nb_of_txs: number;
  ctrl_sum_minor: string;
  currency: string;
  first_execution_date: string;
  last_execution_date: string;
  created_at: string;
  pain_version: string;
  xsd_validated: boolean | null;
  download_count: number;
  first_downloaded_at: string | null;
  first_downloaded_by: string | null;
  sent_marked_at: string | null;
  closed_at: string | null;
  close_reason: string | null;
  error: string | null;
  version: number;
  top_ups_open: number;
  top_ups_booked: number;
};

export type OwnAccountTopUps = {
  bank_account_id: string;
  label: string;
  iban_last4: string;
  bic: string | null;
  currency: string;
  pain_version: string;
  earliest_execution_date: string;
  ordered_count: number;
  can_generate: boolean;
  top_ups: TopUpOrder[];
  files: TopUpFile[];
};

export type TopUpNeed = {
  currency: string;
  /** Σ4679: < 0 while the servicer's share awaits its sweep. */
  owed_minor: string;
  /** Review round 2: what the servicer owes once its sweeps in flight are executed (design §13 #4's Σ4679 + sweeps
   *  ordered or in a file) — the needed line's « ne doit rien » reads it. */
  owed_with_sweeps_minor: string;
  needed_minor: string;
  /** Review round 1 (TUI-2): the top-ups in flight beyond what is owed once the sweeps in flight are executed. */
  surplus_minor: string;
  own_account: { id: string; label: string; iban_last4: string } | null;
};

export type TopUpOverview = {
  today: string;
  needed: TopUpNeed[];
  accounts: OwnAccountTopUps[];
  can_admin: boolean;
};

export type ShortfallPeriod = {
  id: string;
  currency: string;
  since_at: string;
  opened_at: string;
  closed_at: string | null;
  peak_minor: string;
  last_minor: string;
  entries: { entry_id: string; entry_type: string; posted_at: string; effective_date: string; amount_minor: string }[];
  entry_count: number;
};

export const TOP_UP_SECTION_TITLE = "Approvisionnements du compte dédié";
export const TOP_UP_SECTION_ANCHOR = "approvisionnements";
export const SHORTFALL_SECTION_TITLE = "Périodes où le cabinet devait de l'argent au compte dédié";

/** What the periods are (plan §7.1; COMPLIANCE OQ-38: their durations are logged, no rule is drawn from them). */
export const SHORTFALL_SECTION_NOTE =
  "Relevées par la commande horaire des approvisionnements : du premier passage où le cabinet devait de l'argent au compte dédié (avances, frais bancaires, pertes) à celui où il ne lui devait plus rien, avec le plus haut montant dû relevé et les avances, frais et pertes comptabilisés depuis le passage précédent son ouverture jusqu'à sa clôture.";

/** Review round 1 (MONEY-BANK-6): the file takes every top-up still to execute (plan §7.2); Collectoo cannot know that
 *  one was typed at the bank until its credit is imported. */
export const TOP_UP_FILE_WARNING =
  "Le fichier reprend tous les approvisionnements à exécuter de ce compte propre dont le crédit n'est pas encore sur un relevé : si l'un d'eux a déjà été saisi à la main dans la banque, attendez son crédit avant de générer le fichier, ou il serait exécuté deux fois.";

export const TOP_UP_SECTION_NOTE = `Quand le cabinet doit de l'argent au compte dédié (avances, frais bancaires, pertes), Collectoo commande chaque heure un approvisionnement depuis le compte propre choisi dans Paramètres › Facturation (référence TOP…). Exécutez-le à la main dans la banque avec sa référence, ou par le fichier de virements du compte propre ; son crédit sur le compte dédié le comptabilise. ${TOP_UP_FILE_WARNING}`;

export const TOP_UP_STATUS_LABEL: Record<string, string> = {
  ordered: "À exécuter depuis le compte propre",
  in_file: "Dans un fichier du compte propre",
  booked: "Crédité sur le compte dédié",
  returned: "Revenu",
  cancelled: "Annulé",
};

export const TOP_UP_STATUS_TONE: Record<string, "action" | "busy" | "ok" | "neutral" | "error"> = {
  ordered: "action",
  in_file: "busy",
  booked: "ok",
  returned: "error",
  cancelled: "neutral",
};

export const TOP_UP_FILE_STATUS: Record<string, string> = {
  pending: "En cours d'écriture",
  generated: "Prêt à télécharger",
  downloaded: "Téléchargé",
  sent: "Transmis",
  superseded: "Remplacé ou annulé",
  rejected: "Rejeté par la banque",
  failed: "Non écrit",
};

/** The « Annuler le fichier » sheet (plan §7.4): true before or after download, whatever the switch. Review round 1
 *  (TUI-2): the late credit booked as a top-up pays what the servicer owes — the hour's re-order is then beyond it. */
export const CANCEL_TOP_UP_FILE_EFFECT =
  "Les approvisionnements non comptabilisés de ce fichier sont annulés ; Collectoo recommande ce qui reste dû dans l'heure. Si la banque exécute quand même le fichier, la somme arrive sur le compte dédié : comptabilisez-la comme approvisionnement (« Débits et retours ») ; elle règle ce que le cabinet doit. Annulez alors l'approvisionnement recommandé entre-temps s'il n'est pas exécuté (« Annuler ») ; sinon le surplus revient au cabinet avec la prochaine quote-part.";

export const GENERATE_TOP_UP_FILE_EFFECT = `Un fichier pain.001 du compte propre reprend les approvisionnements à exécuter (le compte propre au débit, le compte dédié au crédit, chacun sous sa référence TOP…). Aucun contrôle de solde : les relevés du compte propre ne sont pas importés. Un fichier pas encore téléchargé de ce compte est remplacé. ${TOP_UP_FILE_WARNING}`;

/** « Annuler » an order (ordered, or in a file of the own account): its effect on what Collectoo orders. */
export const CANCEL_TOP_UP_EFFECT =
  "L'approvisionnement est annulé : Collectoo ne le compte plus comme attendu et commande dans l'heure ce qui reste dû. Annulez-le s'il n'a pas été exécuté, ou si son crédit est arrivé sans sa référence et a déjà été comptabilisé sans lui.";

/** Who ordered it (plan §7.4: « commandé automatiquement » or by whom). */
export function orderedBy(t: Pick<TopUpOrder, "automatic" | "ordered_by">): string {
  return t.automatic ? "commandé automatiquement" : `commandé par ${t.ordered_by ?? "l'équipe"}`;
}

/**
 * What the servicer owes the dedicated account now, per currency (design §13 #4's need, from the ledger). Review round 1
 * (MONEY-BANK-5, TUI-1, TUI-7, TUI-2): without an own account chosen in « Facturation » the hourly job orders nothing
 * (private.order_due_top_up) and the line says so; « couvrent » only when something is owed and the orders cover it;
 * an order beyond what is owed is named, with its exit. Review round 2 (needed-line-sweep-in-flight): what is owed is
 * counted with the sweeps in flight, as the formula counts it — Σ4679 < 0 while a sweep in a file takes that share and
 * more is not « ne doit rien ». The branches, by the formula (needed = max(0, owed + sweeps − top-ups in flight)):
 * needed > 0 → still to order; needed = 0 with owed + sweeps > 0 → the top-ups in flight cover it; owed + sweeps ≤ 0
 * → nothing owed; and any top-ups in flight beyond max(0, owed + sweeps) → the surplus.
 */
export function neededLine(n: TopUpNeed): string {
  const needed = BigInt(n.needed_minor);
  // (Σ4679 alone only while a database without the field answers, as surplus_minor's default)
  const owed = BigInt(n.owed_with_sweeps_minor ?? n.owed_minor);
  const surplus = BigInt(n.surplus_minor ?? "0");
  let line: string;
  if (needed > BigInt(0))
    line = n.own_account
      ? `Encore à commander : ${money(n.needed_minor, n.currency)} (Collectoo le commande à la prochaine heure).`
      : `Encore à commander : ${money(n.needed_minor, n.currency)}. Aucun compte propre n'est choisi dans Paramètres › Facturation : Collectoo ne peut pas le commander ; approvisionnez le compte dédié à la main depuis le compte propre, ou choisissez le compte propre.`;
  else if (owed > BigInt(0))
    line = `Rien à approvisionner en ${n.currency} : les approvisionnements commandés couvrent ce que le cabinet doit.`;
  else line = `Le cabinet ne doit rien au compte dédié en ${n.currency}.`;
  return surplus > BigInt(0)
    ? `${line} Les approvisionnements encore à exécuter dépassent de ${money(n.surplus_minor, n.currency)} ce qu'il doit : annulez ceux qui ne sont pas exécutés (« Annuler ») ; exécutés, le surplus revient au cabinet avec la prochaine quote-part.`
    : line;
}

/** A Paris date and time « 12/11/2026 14:37 ». */
export function parisMinute(iso: string): string {
  return new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Europe/Paris",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  })
    .format(new Date(iso))
    .replace(",", "")
    .replace(" à ", " ");
}

/** A shortfall period as « Du 12/11/2026 14:37 au 13/11/2026 10:37 — jusqu'à 2 000,00 € » (plan §7.4). */
export function periodLine(p: Pick<ShortfallPeriod, "opened_at" | "closed_at" | "peak_minor" | "currency">): string {
  const peak = money(p.peak_minor, p.currency);
  return p.closed_at
    ? `Du ${parisMinute(p.opened_at)} au ${parisMinute(p.closed_at)} — jusqu'à ${peak}`
    : `Depuis le ${parisMinute(p.opened_at)} (en cours) — jusqu'à ${peak}`;
}

export const SHORTFALL_ENTRY_LABEL: Record<string, string> = {
  client_advance: "Avance du cabinet",
  bank_fee: "Frais bancaires",
  servicer_loss: "Perte du cabinet",
};

/** Our top-up's end-to-end id (TOP + 12 hex digits): a credit carrying it books itself through the funds pass. */
export const TOP_UP_ID = /^TOP[0-9A-F]{12}$/;

/**
 * Whether « Rattacher à TOP… » is offered ([check 1] gap 12): beside « Approvisionnement par le compte propre »
 * (`offersTopUp`), on a credit that carries no TOP id — the bank dropped the reference. public.book_top_up_credit checks
 * the rest (unbooked, an open top-up of its servicer of exactly its amount, to its account).
 */
export function offersTopUpLink(offersTopUp: boolean, endToEndId: string | null | undefined): boolean {
  return offersTopUp && !TOP_UP_ID.test(endToEndId ?? "");
}

/** One open top-up of a credit's amount (public.top_up_credit_options). */
export type TopUpCreditOption = {
  transfer_id: string;
  end_to_end_id: string;
  amount_minor: string;
  currency: string;
  status: string;
  created_at: string;
  automatic: boolean;
  file_number: string | null;
  /** Review round 1 (MONEY-BANK-1): the own account it is ordered from (always the one the credit came from). */
  debtor_label: string;
  debtor_iban_last4: string;
};

export function parseTopUpCreditOptions(data: unknown): TopUpCreditOption[] | null {
  if (!data || typeof data !== "object" || !Array.isArray((data as { top_ups?: unknown }).top_ups)) return null;
  return (data as { top_ups: TopUpCreditOption[] }).top_ups;
}

/** An open top-up as the sheet lists it. */
export function topUpOptionLabel(o: TopUpCreditOption): string {
  const by = o.automatic ? "commandé automatiquement" : "commandé à la main";
  const where = o.file_number ? ` · dans le fichier ${o.file_number}` : "";
  return `${o.end_to_end_id} — ${money(o.amount_minor, o.currency)} · depuis ${o.debtor_label} ···${o.debtor_iban_last4} · ${by} le ${parisMinute(o.created_at)}${where}`;
}

/** What « Rattacher à TOP… » does (public.book_top_up_credit). */
export function topUpCreditEffect(amount: string): string {
  return `Le crédit de ${amount} venant du compte propre est comptabilisé comme l'approvisionnement choisi, avec l'argent du cabinet : Collectoo ne l'attend plus et ne le commande pas de nouveau.`;
}

/** An own-account file's cash check (`{"own_account": true}`): no balance is checked. */
export const OWN_FILE_CASH_NOTE =
  "Aucun contrôle de solde : les relevés du compte propre ne sont pas importés. Le fichier débite le compte propre et crédite le compte dédié.";

/** Code for an error raised by the top-up commands (most specific first); never the database's text. */
export function topUpErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("top-up file refused: not_an_own_account")) return "top_up_file_not_own";
  if (message.includes("top-up file refused: not_eur")) return "top_up_file_not_eur";
  if (message.includes("top-up file refused: nothing_to_file")) return "top_up_nothing_to_file";
  if (message.includes("top-up file refused: nothing_to_cancel")) return "top_up_nothing_to_cancel";
  if (message.includes("top-up file refused: not_a_top_up_file")) return "top_up_not_a_top_up_file";
  if (message.includes("top-up credit refused: not_an_own_credit")) return "top_up_credit_not_own";
  if (message.includes("top-up credit refused: line_booked")) return "top_up_credit_booked";
  if (message.includes("top-up credit refused: carries_top_up_id")) return "top_up_credit_carries_id";
  if (message.includes("top-up credit refused: top_up_not_open")) return "top_up_not_open";
  if (message.includes("top-up credit refused: amount_differs")) return "top_up_credit_amount";
  // M2c-7e-3 (the fourth exit): another TOP than the one the line's label cites
  if (message.includes("top-up credit refused: label_reference_transfer")) return "top_up_credit_not_cited";
  // review round 1 (MONEY-BANK-1): a credit of another own account than the top-up's (the command, or its re-check)
  if (
    message.includes("top-up credit refused: not_its_own_account") ||
    message.includes("bank booking refused: not_its_own_account")
  )
    return "top_up_credit_other_account";
  // the re-check under the locks: what changed since the page was read
  if (message.includes("bank booking refused: amount_differs")) return "top_up_credit_amount";
  if (
    message.includes("bank booking refused: transfer_not_pending") ||
    message.includes("bank booking refused: top_up_cancelled_credit") ||
    message.includes("bank booking refused: transfer_unknown")
  )
    return "top_up_not_open";
  if (message.includes("bank booking refused: already_booked")) return "top_up_credit_booked";
  if (message.includes("no longer pending")) return "top_up_not_pending";
  if (message.includes("reason is required")) return "reason_required";
  if (message.includes("allocation_busy") || message.includes("lock timeout")) return "allocation_busy";
  return "unknown";
}
