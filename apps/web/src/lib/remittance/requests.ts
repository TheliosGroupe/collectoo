import { money } from "@/lib/payments/statements";
import { type AdvanceCause, requestLabel } from "./advances";
import type { OpenAdvance } from "./settlements";

// ---------------------------------------------------------------------------------------------------------------------
// M2c-7c-2 (plan docs/design/m2c-7-plan.md §5.5): the repayment request — « Demander le remboursement » (the sheet, its
// total from SQL: public.advance_repayment_preview), « Retirer la demande », the column « Demandé le » on « Avances »,
// the client's requests on « Ce que le client doit au cabinet » and in the client space
// (public.client_repayment_requests). Every amount and date is SQL's, as text; these only word them. Refusals in
// French per code (« repayment request refused: <code> »). A request moves no money: it is a letter.
// ---------------------------------------------------------------------------------------------------------------------

const MINOR = /^-?\d{1,16}$/;
const ISO = /^\d{4}-\d{2}-\d{2}$/;
const isMinor = (v: unknown): v is string => typeof v === "string" && MINOR.test(v);
const isDay = (v: unknown): v is string => typeof v === "string" && ISO.test(v);
const isText = (v: unknown): v is string => typeof v === "string";

function frenchDay(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

export type RepaymentRequestRow = {
  request_id: string;
  number: string;
  issue_date: string;
  currency: string;
  total_minor: string;
  withdrawn_on: string | null;
  document_id: string | null;
  advance_ids: string[];
};

/** public.client_repayment_requests, or null when it is not its shape — never a guess. */
export function parseClientRepaymentRequests(x: unknown): { rows: RepaymentRequestRow[] } | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  if (!Array.isArray(o.rows)) return null;
  const rows: RepaymentRequestRow[] = [];
  for (const v of o.rows) {
    const r = v as Record<string, unknown>;
    if (!r || !isText(r.request_id) || !isText(r.number) || !isDay(r.issue_date) || !isText(r.currency)) return null;
    if (!isMinor(r.total_minor)) return null;
    if (r.withdrawn_on !== null && r.withdrawn_on !== undefined && !isDay(r.withdrawn_on)) return null;
    if (r.document_id !== null && r.document_id !== undefined && !isText(r.document_id)) return null;
    if (!Array.isArray(r.advance_ids) || !r.advance_ids.every(isText)) return null;
    rows.push({
      request_id: r.request_id,
      number: r.number,
      issue_date: r.issue_date,
      currency: r.currency,
      total_minor: r.total_minor,
      withdrawn_on: (r.withdrawn_on as string | null | undefined) ?? null,
      document_id: (r.document_id as string | null | undefined) ?? null,
      advance_ids: r.advance_ids as string[],
    });
  }
  return { rows };
}

export type RepaymentPreview = {
  total_minor: string;
  refusal: string | null;
  detail: string | null;
  rows: { advance_id: string; open_minor: string; refusal: string | null; detail: string | null }[];
};

/** public.advance_repayment_preview, or null when it is not its shape. */
export function parseRepaymentPreview(x: unknown): RepaymentPreview | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  if (!isMinor(o.total_minor) || !Array.isArray(o.rows)) return null;
  const textOrNull = (v: unknown) => v === null || v === undefined || isText(v);
  if (!textOrNull(o.refusal)) return null;
  const rows: RepaymentPreview["rows"] = [];
  for (const v of o.rows) {
    const r = v as Record<string, unknown>;
    if (!r || !isText(r.advance_id) || !isMinor(r.open_minor) || !textOrNull(r.refusal) || !textOrNull(r.detail))
      return null;
    rows.push({
      advance_id: r.advance_id,
      open_minor: r.open_minor,
      refusal: (r.refusal as string | null | undefined) ?? null,
      detail: (r.detail as string | null | undefined) ?? null,
    });
  }
  return {
    total_minor: o.total_minor,
    refusal: (o.refusal as string | null | undefined) ?? null,
    detail: (o.detail as string | null | undefined) ?? null,
    rows,
  };
}

/** The sheet's effect: a letter to the client, nothing moved. */
export function requestSheetEffect(totalMinor: string, currency: string): string {
  return `Une demande de remboursement de ${money(totalMinor, currency)} est adressée au client. La lettre est déposée dans l'espace du client ; imprimez-la pour un envoi postal.`;
}

/**
 * « Retirer la demande »'s effect, once done: (review round 1, UI-1) the other requests not withdrawn that still name
 * one of its advances (public.withdraw_advance_repayment_request's `still_requested_by` — a reminder withdrawn leaves
 * the first request) keep them requested.
 */
export function withdrawEffect(number: string, stillRequestedBy: readonly string[] = []): string {
  if (stillRequestedBy.length === 0)
    return `La demande ${number} est retirée : l'avance pourra être reprise ou demandée de nouveau.`;
  const others =
    stillRequestedBy.length === 1
      ? `La demande ${stillRequestedBy[0]} nomme encore ses avances`
      : `Les demandes ${stillRequestedBy.join(", ")} nomment encore ses avances`;
  return `La demande ${number} est retirée. ${others} : elles restent demandées au client.`;
}

/** (review round 1, UI-1) The sheet's text before the withdrawal: true whatever other request names its advances. */
export function withdrawSheetText(number: string): string {
  return `La demande ${number} est retirée : l'espace du client l'indique. Ses avances pourront être reprises ou demandées de nouveau, sauf celles qu'une autre demande en cours nomme encore.`;
}

const DRA = /^DRA-\d{4}-\d{6,}$/;

/** public.withdraw_advance_repayment_request's result (its number, the requests still naming its advances), or null. */
export function parseWithdrawal(x: unknown): { number: string; still_requested_by: string[] } | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  if (!isText(o.number) || !DRA.test(o.number)) return null;
  const still = o.still_requested_by;
  if (!Array.isArray(still) || !still.every((n) => isText(n) && DRA.test(n))) return null;
  return { number: o.number, still_requested_by: still as string[] };
}

/** The numbers a page's « reste » parameter carries (the withdrawal's still_requested_by), the others dropped. */
export function stillRequestedParam(v: unknown): string[] {
  return typeof v === "string" ? v.split(",").filter((n) => DRA.test(n)) : [];
}

function daysBefore(iso: string, days: number): string {
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d - days)).toISOString().slice(0, 10);
}

/**
 * (review round 1, TUI-5) What « Ce que le client doit au cabinet » offers to request, as « Avances » does
 * (advances.ts `requestable`): the client's open advances in the page's currency recovered by a request (no claw-back
 * clause, or no single mandate), taken by no run in flight, not born before its proceeding opened, and not named by a
 * request not withdrawn issued less than 30 days ago — a reminder after them is a new request (plan §5.2.7). Its label:
 * « Relancer » when every one offered was requested already. SQL decides on submit.
 */
export function owesRequestCandidates(
  advances: readonly OpenAdvance[],
  requests: readonly RepaymentRequestRow[],
  currency: string,
  today: string,
): { candidates: { advance_id: string; label: string; open_minor: string }[]; label: string | null } {
  // the request not withdrawn that names the advance (the newest first: SQL's order)
  const requestOf = (id: string) =>
    requests.find((q) => q.withdrawn_on === null && q.currency === currency && q.advance_ids.includes(id)) ?? null;
  const offered = advances.filter((a) => {
    if (a.before_opening || a.in_flight_run) return false;
    if (a.recovery !== "request" && a.recovery !== "request_no_mandate") return false;
    if (!MINOR.test(a.open_minor) || BigInt(a.open_minor) <= BigInt(0)) return false;
    const q = requestOf(a.id);
    return q === null || q.issue_date <= daysBefore(today, 30);
  });
  if (offered.length === 0) return { candidates: [], label: null };
  return {
    candidates: offered.map((a) => ({
      advance_id: a.id,
      label: requestLabel({ born_on: a.born_on, cause: a.cause as AdvanceCause, file_ref: null }),
      open_minor: a.open_minor,
    })),
    label: offered.every((a) => requestOf(a.id) !== null) ? "Relancer" : "Demander le remboursement",
  };
}

/**
 * (review round 1, TUI-4, NIGHT-1) What a request's line says of its letter when it has none: being drawn; or, for a
 * request withdrawn before it was drawn (its job draws none), nothing in the client space and why on the staff page.
 * Null when its letter (PDF) is offered.
 */
export function requestLetterNote(r: RepaymentRequestRow, audience: "client" | "staff"): string | null {
  if (r.document_id) return null;
  if (r.withdrawn_on === null) return "Lettre en préparation.";
  return audience === "staff" ? "Lettre non produite : la demande a été retirée avant." : null;
}

/** « Demandé le » on « Avances »: the request not withdrawn that names an open advance (null: none). */
export function requestedOn(r: { request_id: string; number: string; issue_date: string } | null): string | null {
  return r ? `Demandé le ${frenchDay(r.issue_date)} (${r.number})` : null;
}

const NOT_ALLOWED = "Action réservée aux administrateurs et responsables des opérations (double authentification).";
const BUSY = "Opération en cours sur les reversements du cabinet : réessayez dans un instant.";
const RUN = /^RV-\d{4}-\d{6,}$/;

/** The refusal's code read from the database's message (« repayment request refused: in_flight »), or null. */
function refusalCode(message: string): string | null {
  const m = /^repayment request refused: ([a-z_]+)$/.exec(message.trim());
  return m ? m[1] : null;
}

/**
 * The request's and the withdrawal's refusals (and the preview's codes), in French; detail: the run in flight, the day
 * of the last request, the claw-back clause, or for payout_not_received « <RV-…>:run » / « <RV-…>:unplanned » (the run,
 * and what came back: its own payout, or a payout outside any run that had paid the collection).
 */
export function repaymentRefusal(message: string | null | undefined, detail?: string | null): string {
  const m = message ?? "";
  if (m === "not allowed") return NOT_ALLOWED;
  if (/allocation_busy|lock timeout|could not obtain lock/.test(m)) return BUSY;
  return refusalText(refusalCode(m), detail);
}

/** The same from a code (the preview's rows and client refusal). */
export function refusalText(code: string | null, detail?: string | null): string {
  switch (code) {
    case "in_flight":
      return `Déjà réglé par le reversement ${detail && RUN.test(detail) ? detail : "en cours"} en cours : attendez son débit.`;
    case "recently_requested":
      return detail && ISO.test(detail)
        ? `Une demande a déjà été adressée pour cette avance le ${frenchDay(detail)} : une relance est possible 30 jours après.`
        : "Une demande a déjà été adressée pour cette avance : une relance est possible 30 jours après.";
    case "clawback_applies":
      return `Cette avance est reprise sur les prochains reversements du client (${detail || "clause de reprise"} du mandat) : une demande la ferait payer deux fois.`;
    case "payout_not_received": {
      const [run, via] = (detail ?? "").split(":");
      return via === "unplanned"
        ? `Le virement hors reversement qui avait payé cet encaissement (relevé ${run}) est revenu et n'a pas encore été versé de nouveau : le client n'a pas reçu cette somme.`
        : `Le reversement ${run || "concerné"} est revenu et n'a pas encore été versé de nouveau : le client n'a pas reçu cette somme.`;
    }
    case "not_open":
      return "Cette avance n'a plus rien à régler : rechargez la page.";
    case "total_changed":
      return "Les montants ont changé depuis l'affichage : rechargez la page.";
    case "identity_incomplete":
      return "L'identité de facturation du cabinet est incomplète (Paramètres › Facturation).";
    case "no_own_account":
      return "Aucun compte propre n'est enregistré (Paramètres › Facturation).";
    case "before_opening":
      return "Avance née avant l'ouverture de la procédure collective du client : le client ne peut pas la payer, aucune demande ne lui est adressée.";
    case "recipient_unknown":
      return "Un événement (décès, tutelle, liquidation, fin de mandat) est enregistré pour ce client : aucune demande ne lui est adressée tant que la personne qui agit pour lui n'est pas enregistrée.";
    case "already_withdrawn":
      return "Cette demande est déjà retirée.";
    case "reason_required":
      return "Indiquez le motif du retrait.";
    case "bad_request":
      return "La demande est incomplète : rechargez la page.";
    default:
      return "La demande n'a pas pu être adressée. Rechargez la page et réessayez ; si cela continue, prévenez le support.";
  }
}

/** The client space's line of a request (and its withdrawal). */
export function spaceRequestLine(r: RepaymentRequestRow): string {
  const head = `Demande de remboursement d'avances ${r.number} du ${frenchDay(r.issue_date)} : ${money(r.total_minor, r.currency)}`;
  return r.withdrawn_on ? `${head} — demande retirée le ${frenchDay(r.withdrawn_on)}` : head;
}
