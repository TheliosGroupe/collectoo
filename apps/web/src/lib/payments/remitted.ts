import type { ErrorCode } from "@/lib/boarding/forms";
import { allocationErrorCode } from "./allocation";
import { money } from "./statements";

// ---------------------------------------------------------------------------------------------------------------------
// M2c-7a (plan docs/design/m2c-7-plan.md §3.7): a collection already remitted to the client and then undone. The
// amounts, dates and run numbers come from SQL (public.allocation_remitted, private.run_settled_on); these sentences only
// word them. Dates are recording dates (§2.1): the run's debit (booked_on) or what its settlement read gives.
// ---------------------------------------------------------------------------------------------------------------------

/** One entry of public.allocation_remitted: an allocation or forward of the payment remitted in a booked run. */
export type RemittedEntry = {
  entry_id: string;
  account_id: string | null;
  run_number: string;
  booked_on: string;
  amount_minor: string;
  /** null: the client has not kept it yet (the payout came back, not paid again) */
  paid_on: string | null;
  /** paid: a payout paid it and stayed paid; set_off: an N = 0 run set it off; netted: an N = 0 run netted to nothing */
  paid_how: "paid" | "set_off" | "netted" | null;
  paid_run_number: string | null;
};

const MINOR = /^-?\d{1,16}$/;
const ISO = /^\d{4}-\d{2}-\d{2}$/;
const HOW = new Set(["paid", "set_off", "netted"]);

function frenchDay(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

/** The read, or null when it is not its shape — never a guess. */
export function parseAllocationRemitted(x: unknown): RemittedEntry[] | null {
  if (!Array.isArray(x)) return null;
  const out: RemittedEntry[] = [];
  for (const v of x) {
    if (!v || typeof v !== "object") return null;
    const o = v as Record<string, unknown>;
    if (typeof o.entry_id !== "string" || typeof o.run_number !== "string") return null;
    if (typeof o.booked_on !== "string" || !ISO.test(o.booked_on)) return null;
    if (typeof o.amount_minor !== "string" || !MINOR.test(o.amount_minor)) return null;
    if (o.account_id !== null && typeof o.account_id !== "string") return null;
    if (o.paid_on !== null && (typeof o.paid_on !== "string" || !ISO.test(o.paid_on))) return null;
    if (o.paid_how !== null && (typeof o.paid_how !== "string" || !HOW.has(o.paid_how))) return null;
    if (o.paid_run_number !== null && typeof o.paid_run_number !== "string") return null;
    out.push({
      entry_id: o.entry_id,
      account_id: o.account_id as string | null,
      run_number: o.run_number,
      booked_on: o.booked_on,
      amount_minor: o.amount_minor,
      paid_on: o.paid_on as string | null,
      paid_how: o.paid_how as RemittedEntry["paid_how"],
      paid_run_number: o.paid_run_number as string | null,
    });
  }
  return out;
}

/** What the client received of the entry, by `paid_how` (plan §3.2.1): never « versé » nor « débité » for a set-off or a
 *  net nil, and « revenu, à verser de nouveau » while a payout that came back is not paid again. */
export function remittedHead(e: RemittedEntry): string {
  if (e.paid_how === "paid" && e.paid_on) {
    const run = e.paid_run_number ?? e.run_number;
    return run === e.run_number
      ? `Déjà reversé au client (reversement ${run}, débité le ${frenchDay(e.paid_on)}).`
      : `Déjà reversé au client (reversement ${run}, débité le ${frenchDay(e.paid_on)}, après le retour du virement du reversement ${e.run_number}).`;
  }
  if (e.paid_how === "set_off" && e.paid_on)
    return `Déjà réglé au client par compensation dans le relevé ${e.paid_run_number ?? e.run_number} du ${frenchDay(e.paid_on)}.`;
  if (e.paid_how === "netted" && e.paid_on)
    return `Déjà compris dans le relevé ${e.paid_run_number ?? e.run_number} du ${frenchDay(e.paid_on)} (montant net nul).`;
  return `Compris dans le reversement ${e.run_number} (revenu, à verser de nouveau).`;
}

/** The « Désimputer » sheet's sentences when the file's entries were remitted (null when none was). */
export function reverseRemittedEffect(entries: RemittedEntry[], currency: string): string | null {
  if (entries.length === 0) return null;
  const total = entries.reduce((s, e) => s + BigInt(e.amount_minor), BigInt(0));
  const heads = [...new Set(entries.map(remittedHead))].join(" ");
  return `${heads} En désimputant, le cabinet lui en fait l'avance (${money(total.toString(), currency)}) : la somme n'est pas déduite de ses autres encaissements.`;
}

/** The toast once « Désimputer » is done: the advances the command posted (its result's `advances`). */
export function reverseToast(advances: { amount_minor: string }[], currency: string): string {
  const total = advances.reduce((s, a) => s + (MINOR.test(a.amount_minor) ? BigInt(a.amount_minor) : BigInt(0)), BigInt(0));
  return total > BigInt(0)
    ? `Imputation annulée ; avance du cabinet de ${money(total.toString(), currency)} enregistrée.`
    : "Imputation annulée.";
}

/** « Débits et retours »: a return of a payment some of which was remitted (null when nothing was). */
export function returnRemittedNote(entries: RemittedEntry[], currency: string): string | null {
  if (entries.length === 0) return null;
  const total = entries.reduce((s, e) => s + BigInt(e.amount_minor), BigInt(0));
  const runs = [...new Set(entries.map((e) => e.run_number))].join(", ");
  return `Paiement déjà reversé au client (${runs}) : au retour, le cabinet lui avance ${money(total.toString(), currency)}.`;
}

/** « Désimputer »'s error: a lock wait is an operation on the transfers (a file generation holds the remit lock while
 *  the cover waits for it, plan §2.2); LG009 the cover that could not be recorded; the others as before. */
export function reverseErrorCode(error: { code?: string | null; message?: string | null }): ErrorCode {
  const message = error.message ?? "";
  if (error.code === "55P03" || message.includes("lock timeout") || message.includes("could not obtain lock"))
    return "transfers_busy";
  return allocationErrorCode(message);
}

/** « Couvrir »: the sentence of the sheet (the gap the nightly found, the client, the date the reversal was recorded). */
export function coverPrompt(amountMinor: string, currency: string, client: string, recordedOn: string): string {
  return `Enregistrer l'avance du cabinet de ${money(amountMinor, currency)} au client ${client} pour l'annulation du ${frenchDay(recordedOn)}`;
}

export function coverErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("remitted cover refused: nothing_to_cover")) return "cover_nothing_to_cover";
  if (message.includes("remitted cover refused: gap_changed")) return "cover_gap_changed";
  if (message.includes("remitted cover refused: over_covered")) return "cover_over_covered";
  if (message.includes("allocation_busy") || message.includes("lock timeout")) return "transfers_busy";
  if (message.includes("LG009")) return "remitted_cover_failed";
  return "unknown";
}

/** « Vérification complète des avances » on « Contrôles » (admins; plan §3.7 [check 2]). */
export const FULL_CHECK = {
  label: "Vérification complète des avances",
  help: "Les contrôles de chaque nuit relisent les annulations récentes ; le 1er du mois, ils relisent tous les reversements débités. Ce bouton lance cette relecture complète avec les contrôles, maintenant.",
  toast: "Vérification complète demandée : elle passe avec les contrôles lancés maintenant.",
} as const;

export function fullCheckErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("advance check refused: already_requested")) return "full_check_already_requested";
  return "unknown";
}
