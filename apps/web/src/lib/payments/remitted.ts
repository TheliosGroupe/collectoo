import type { ErrorCode } from "@/lib/boarding/forms";
import { allocationErrorCode } from "./allocation";
import { money } from "./statements";

// ---------------------------------------------------------------------------------------------------------------------
// M2c-7a (plan docs/design/m2c-7-plan.md §3.7): a collection already remitted to the client and then undone. The
// amounts, dates and run numbers come from SQL (public.allocation_remitted, private.entry_remitted and
// private.item_settled_at); these sentences only word them. Dates are recording dates (§2.1): the run's debit
// (booked_on) or what its settlement read gives.
// ---------------------------------------------------------------------------------------------------------------------

/** One entry of public.allocation_remitted: an allocation or forward of the payment remitted in a booked run. */
export type RemittedEntry = {
  entry_id: string;
  account_id: string | null;
  run_number: string;
  /** (review round 1, M7A-MONEY-2) whether that run had a payout transfer of its own (false for an N = 0 run). Kept in
   *  the read; since review round 2 the texts name the payout that came back by `returned_via`. */
  run_transfer: boolean;
  booked_on: string;
  amount_minor: string;
  /** null: the client has not kept it yet (the payout came back, not paid again) */
  paid_on: string | null;
  /** paid: a payout paid it and stayed paid; set_off: an N = 0 run set it off; netted: an N = 0 run netted to nothing */
  paid_how: "paid" | "set_off" | "netted" | null;
  paid_run_number: string | null;
  /** (review round 2) what came back first of what had paid the entry: `run` its run's own payout, `unplanned` a payout
   *  outside any run (« hors reversement ») that had paid it — with or without a transfer of the run's own —, null
   *  nothing came back */
  returned_via: "run" | "unplanned" | null;
};

const MINOR = /^-?\d{1,16}$/;
const ISO = /^\d{4}-\d{2}-\d{2}$/;
const HOW = new Set(["paid", "set_off", "netted"]);
const VIA = new Set(["run", "unplanned"]);

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
    if (typeof o.run_transfer !== "boolean") return null;
    if (typeof o.booked_on !== "string" || !ISO.test(o.booked_on)) return null;
    if (typeof o.amount_minor !== "string" || !MINOR.test(o.amount_minor)) return null;
    if (o.account_id !== null && typeof o.account_id !== "string") return null;
    if (o.paid_on !== null && (typeof o.paid_on !== "string" || !ISO.test(o.paid_on))) return null;
    if (o.paid_how !== null && (typeof o.paid_how !== "string" || !HOW.has(o.paid_how))) return null;
    if (o.paid_run_number !== null && typeof o.paid_run_number !== "string") return null;
    if (o.returned_via !== null && (typeof o.returned_via !== "string" || !VIA.has(o.returned_via))) return null;
    out.push({
      entry_id: o.entry_id,
      account_id: o.account_id as string | null,
      run_number: o.run_number,
      run_transfer: o.run_transfer,
      booked_on: o.booked_on,
      amount_minor: o.amount_minor,
      paid_on: o.paid_on as string | null,
      paid_how: o.paid_how as RemittedEntry["paid_how"],
      paid_run_number: o.paid_run_number as string | null,
      returned_via: o.returned_via as RemittedEntry["returned_via"],
    });
  }
  return out;
}

/** (review round 1, M7A-MONEY-2; review round 2) the payout that came back before a later run paid the entry, by
 *  `returned_via`: the remitted run's own, or a payout outside any run that had paid it — in an N = 0 run, which had
 *  none, or in a run whose own payout paid its other collections. null: nothing came back (a state the read does not
 *  give with a later run): no clause. */
function returnedPayout(e: RemittedEntry): string | null {
  if (e.returned_via === "run") return `après le retour du virement du reversement ${e.run_number}`;
  if (e.returned_via === "unplanned") return "après le retour du virement hors reversement qui l'avait payé";
  return null;
}

/** (review round 2) while what came back is not paid again (`paid_on` null): what came back, in the parentheses. */
function backAgain(e: RemittedEntry): string {
  return e.returned_via === "unplanned"
    ? "le virement hors reversement qui l'avait payé est revenu, à verser de nouveau"
    : "revenu, à verser de nouveau";
}

/** What the client received of the entry, by `paid_how` (plan §3.2.1): never « versé » nor « débité » for a set-off or a
 *  net nil, and « revenu, à verser de nouveau » while a payout that came back is not paid again. */
export function remittedHead(e: RemittedEntry): string {
  if (e.paid_how === "paid" && e.paid_on) {
    const run = e.paid_run_number ?? e.run_number;
    const back = run === e.run_number ? null : returnedPayout(e);
    return back === null
      ? `Déjà reversé au client (reversement ${run}, débité le ${frenchDay(e.paid_on)}).`
      : `Déjà reversé au client (reversement ${run}, débité le ${frenchDay(e.paid_on)}, ${back}).`;
  }
  if (e.paid_how === "set_off" && e.paid_on)
    return `Déjà réglé au client par compensation dans le relevé ${e.paid_run_number ?? e.run_number} du ${frenchDay(e.paid_on)}.`;
  if (e.paid_how === "netted" && e.paid_on)
    return `Déjà compris dans le relevé ${e.paid_run_number ?? e.run_number} du ${frenchDay(e.paid_on)} (montant net nul).`;
  return `Compris dans le reversement ${e.run_number} (${backAgain(e)}).`;
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

/** The return note's clause for one entry, by `paid_how` (review round 1, tests-ui-1: « reversé » only for a payout
 *  paid and kept, as `remittedHead` says it); `first` capitalises it. */
function returnClause(e: RemittedEntry): string {
  if (e.paid_how === "paid" && e.paid_on) {
    const run = e.paid_run_number ?? e.run_number;
    const back = run === e.run_number ? null : returnedPayout(e);
    return back === null ? `déjà reversé au client (${run})` : `déjà reversé au client (${run}, ${back})`;
  }
  if (e.paid_how === "set_off" && e.paid_on)
    return `déjà réglé au client par compensation dans le relevé ${e.paid_run_number ?? e.run_number} du ${frenchDay(e.paid_on)}`;
  if (e.paid_how === "netted" && e.paid_on)
    return `déjà compris dans le relevé ${e.paid_run_number ?? e.run_number} du ${frenchDay(e.paid_on)} (montant net nul)`;
  return `compris dans le reversement ${e.run_number} (${backAgain(e)})`;
}

/** « Débits et retours »: a return of a payment some of which was remitted (null when nothing was). Its first clause
 *  follows `paid_how`, as the « Désimputer » sheet does: a payout that came back, a set-off or a net nil is never said
 *  « reversé » (review round 1, tests-ui-1). */
export function returnRemittedNote(entries: RemittedEntry[], currency: string): string | null {
  if (entries.length === 0) return null;
  const total = entries.reduce((s, e) => s + BigInt(e.amount_minor), BigInt(0));
  const clauses = [...new Set(entries.map(returnClause))].join(" ; ");
  return `Paiement ${clauses} : au retour, le cabinet lui avance ${money(total.toString(), currency)}.`;
}

// (review round 1, M7A-MONEY-3) After « Désimputer », the URL names the advances the command posted — their ids, never an
// amount — and the page reads them back from the ledger: a crafted or stale link shows no amount the ledger does not hold.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_ADVANCE_IDS = 50;

/** The URL value naming the advances a « Désimputer » posted (empty when it posted none). */
export function advanceIdsParam(ids: string[]): string {
  return ids.join(",");
}

/** The advance ids of the URL, or null when absent or not that shape (then no notice at all). */
export function parseAdvanceIds(x: unknown): string[] | null {
  if (typeof x !== "string") return null;
  if (x === "") return [];
  const ids = x.split(",");
  if (ids.length > MAX_ADVANCE_IDS || !ids.every((id) => UUID_RE.test(id))) return null;
  return ids;
}

/** One advance read back: its amount (minor units as text, from the ledger), the reversal it covers, and whether its
 *  entry has been reversed since (a release). */
export type AdvanceRead = { id: string; amount_minor: string; cause_entry_id: string; reversed: boolean };

/** The notice once « Désimputer » is done: the advances of the URL that cover a reversal of this payment
 *  (`reversalIds`) and are still live, their total as the ledger holds it; null when nothing of the payment was
 *  reversed (a link to a payment it does not concern). */
export function reverseNotice(rows: AdvanceRead[], reversalIds: ReadonlySet<string>, currency: string): string | null {
  if (reversalIds.size === 0) return null;
  const live = rows.filter((a) => reversalIds.has(a.cause_entry_id) && !a.reversed && MINOR.test(a.amount_minor));
  return reverseToast(live, currency);
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
  // (review round 1, CC-3) another request of the servicer being recorded at that instant (its lock, lock_timeout 2s)
  if (message.includes("lock timeout") || message.includes("could not obtain lock")) return "full_check_busy";
  return "unknown";
}
