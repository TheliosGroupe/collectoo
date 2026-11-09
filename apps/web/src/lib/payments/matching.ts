import type { ErrorCode } from "@/lib/boarding/forms";
import { money, type Tone } from "@/lib/payments/statements";

/**
 * M2b-3: the exception queue (« Paiements à traiter », design §12.2). Pure helpers, unit-tested.
 * The rules that match payments run in the worker (deterministic, no model); this page shows what
 * they decided and lets admins and ops managers assign, accept a suggestion or unassign.
 * Amounts arrive as text (integer minor units): they never pass through a JS number.
 */

/** Why a payment is in the queue, in French, with what ops do about it. */
export const REVIEW_REASON: Record<string, { label: string; tone: Tone; help: string }> = {
  waiting: {
    label: "Rapprochement en cours",
    tone: "busy",
    help: "Les règles de rapprochement n'ont pas encore traité ce paiement : la page se met à jour.",
  },
  no_match: {
    label: "Aucun dossier désigné",
    tone: "action",
    help: "Aucune règle ne désigne un dossier avec certitude. Acceptez la suggestion si elle est juste, ou cherchez le dossier.",
  },
  ambiguous: {
    label: "Plusieurs dossiers possibles",
    tone: "action",
    help: "Le paiement cite plusieurs dossiers : choisissez celui qu'il règle (la répartition sur plusieurs dossiers viendra avec l'imputation).",
  },
  account_not_confirmed: {
    label: "Dossier pas encore confirmé",
    tone: "busy",
    help: "Le paiement attend la confirmation du lot de ce dossier ; il sera rapproché automatiquement à la confirmation.",
  },
  no_mandate: {
    label: "Lot annulé : hors mandat",
    tone: "error",
    help: "Le lot de ce dossier a été annulé : le paiement est à rembourser, sauf ratification par le client (art. 1342-2 C. civ.).",
  },
  account_closed: {
    label: "Dossier clôturé",
    tone: "action",
    help: "Le dossier est clôturé : un dossier rappelé par le client voit ses paiements reversés au client ; sinon, remboursement au payeur.",
  },
  currency_mismatch: {
    label: "Autre devise",
    tone: "action",
    help: "Le paiement n'est pas dans la devise de la créance : il n'est pas converti et sera remboursé par défaut.",
  },
  before_servicing_start: {
    label: "Antérieur à la reprise",
    tone: "action",
    help: "Le paiement est antérieur à la date d'arrêté : vérifiez avec le client si son solde en tient déjà compte.",
  },
  hold_blocks_allocation: {
    label: "Dossier bloqué (procédure)",
    tone: "error",
    help: "Surendettement ou procédure collective : le paiement est retenu, ni imputé ni reversé, jusqu'à décision.",
  },
  nothing_due: {
    label: "Plus rien à payer",
    tone: "action",
    help: "Le dossier ne présente plus de solde : vérifiez le dossier, sinon le paiement sera remboursé au payeur.",
  },
  overpayment: { label: "Trop-perçu", tone: "action", help: "Une partie du paiement dépasse le solde du dossier." },
  credit_note_to_apply: { label: "Avoir à appliquer", tone: "action", help: "Un avoir du dossier reste à appliquer." },
  partial_return: { label: "Retour partiel", tone: "action", help: "La banque a retourné une partie du paiement." },
};

export function reviewReason(reason: string | null): { label: string; tone: Tone; help: string } {
  return REVIEW_REASON[reason ?? "waiting"] ?? { label: reason ?? "", tone: "neutral", help: "" };
}

/** Queue filters (« Motif »): every reason ops can meet in this slice. */
export const REASON_FILTERS: { value: string; label: string }[] = [
  "no_match",
  "ambiguous",
  "account_not_confirmed",
  "no_mandate",
  "account_closed",
  "currency_mismatch",
  "before_servicing_start",
  "hold_blocks_allocation",
  "nothing_due",
  "waiting",
].map((value) => ({ value, label: reviewReason(value).label }));

/** How a payment found its file (payment.match_method). */
export const METHOD_LABEL: Record<string, string> = {
  rf_structured: "Référence RF (zone structurée)",
  rf_text: "Référence RF dans le libellé",
  rf_body: "Chiffres de la référence RF",
  item_ref: "Numéro de facture ou de dossier confirmé",
  iban_memory: "IBAN connu de ce dossier",
  manual: "Affecté par un gestionnaire",
};

/** The worker's rules, as ops read them (collectoo_worker.payments.matching.RULES). */
export const RULE_LABEL: Record<string, string> = {
  R1: "Référence RF structurée",
  R2: "Référence RF dans le libellé",
  R3: "Numéro de facture ou de dossier",
  R4: "IBAN connu",
  R5: "Montant et nom",
  R6: "Indices",
};

/** Days since the booking date as a badge: from 20 days, the one-month remittance (R124-6) is close. */
export function ageBadge(days: number): { text: string; tone: Tone } {
  return { text: `J+${Math.max(0, days)}`, tone: days >= 20 ? "error" : days >= 10 ? "action" : "neutral" };
}

/** An invoice or file reference as compared: ASCII letters and digits, upper case (= SQL private.ref_key). */
export function refKey(text: string): string {
  return text.replace(/[^0-9A-Za-z]/g, "").toUpperCase();
}

/**
 * The remittance text cut into pieces, those the rules read as references marked. A word is marked
 * when its key (3 characters at least) is, or is part of, one of the detected references.
 */
export function highlight(text: string, references: string[]): { text: string; mark: boolean }[] {
  const keys = references.map(refKey).filter((k) => k.length >= 3);
  if (keys.length === 0) return [{ text, mark: false }];
  const pieces = text.split(/(\s+)/).filter((p) => p !== "");
  const marks = pieces.map((p) => {
    if (/^\s+$/.test(p)) return null;
    const k = refKey(p);
    return k.length >= 3 && keys.some((ref) => ref.includes(k));
  });
  const out: { text: string; mark: boolean }[] = [];
  pieces.forEach((piece, i) => {
    // spaces inside a reference written in groups ("RF60 4821 …") belong to it
    const mark = marks[i] ?? (marks[i - 1] === true && marks[i + 1] === true);
    const last = out[out.length - 1];
    if (last && last.mark === mark) last.text += piece;
    else out.push({ text: piece, mark });
  });
  return out;
}

export type Signals = {
  rf?: string[];
  tokens?: string[];
  similarity?: string;
  amount?: string;
  why?: string;
  iban_payments?: string;
  designation?: string[];
  reason?: string;
};

/** The references a candidate's signals cite (for the highlighting). */
export function citedReferences(signals: Signals[]): string[] {
  return signals.flatMap((s) => [...(s.rf ?? []), ...(s.tokens ?? [])]);
}

/** Why a file was proposed, in French (from the signals the worker kept). */
export function signalText(rule: string, s: Signals): string {
  const parts: string[] = [];
  if (s.rf?.length) parts.push(`référence ${s.rf.map(formatRf).join(", ")}`);
  if (s.tokens?.length) parts.push(`cite ${s.tokens.join(", ")}`);
  if (s.amount === "account") parts.push("montant égal au solde du dossier");
  else if (s.amount?.startsWith("item:")) parts.push(`montant égal à la facture ${s.amount.slice(5)}`);
  if (s.iban_payments) parts.push("IBAN déjà connu de ce dossier");
  if (s.similarity && s.similarity !== "0.00") parts.push(`nom proche à ${Math.round(Number(s.similarity) * 100)} %`);
  if (s.why === "not_corroborated") parts.push("sans second indice");
  if (s.why === "above_due") parts.push("montant supérieur au reste dû");
  if (s.why === "account_closed") parts.push("dossier clôturé");
  return `${RULE_LABEL[rule] ?? rule} : ${parts.join(" · ") || "indice faible"}`;
}

/** RF reference in groups of four, as printed on letters. */
export function formatRf(rf: string): string {
  return rf.replace(/\s/g, "").replace(/(.{4})(?=.)/g, "$1 ");
}

export type QueueAccount = {
  account_id: string;
  external_ref: string;
  status: string;
  client_name: string;
  debtor_name: string | null;
  currency: string;
  balance_minor: string;
  pending_minor: string;
  rf: string | null;
  /** First day of servicing (gating: a payment booked before it waits). */
  servicing_start: string | null;
  /** Active surendettement / collective proceeding holds (gating: the payment is held). */
  holds: readonly string[];
};

/** « M-0042 · Martin SAS · solde 800,00 € » — what the one-tap button and the choices say. */
export function fileLabel(a: QueueAccount): string {
  const who = a.debtor_name ? ` · ${a.debtor_name}` : "";
  return `${a.external_ref}${who} · solde ${money(a.balance_minor, a.currency)}`;
}

/** Payments already matched to the file and not allocated yet, when there are some. */
export function pendingText(a: QueueAccount): string | null {
  return a.pending_minor !== "0" ? `dont ${money(a.pending_minor, a.currency)} déjà reçus, à imputer` : null;
}

/**
 * What the gating will say once this payment is assigned to this file: the SQL `private.gate_assignments`,
 * first that applies (null: ready for allocation). The confirmation sheet words it, so it never promises an
 * allocation that will be held or refused. Amounts compared as integers (BigInt), dates as ISO text.
 */
export function gatingOutcome(file: QueueAccount, paid: { currency: string; booking_date: string }): string | null {
  if (file.status === "staged") return "account_not_confirmed";
  if (file.status.startsWith("closed")) return "account_closed";
  if (paid.currency.trim() !== file.currency.trim()) return "currency_mismatch";
  if (!file.servicing_start || paid.booking_date < file.servicing_start) return "before_servicing_start";
  if (file.holds.length > 0) return "hold_blocks_allocation";
  if (BigInt(file.balance_minor) - BigInt(file.pending_minor) <= BigInt(0)) return "nothing_due";
  return null;
}

const OUTCOME_TEXT: Record<string, string> = {
  account_not_confirmed: "Le dossier n'est pas encore confirmé : le paiement ne peut pas y être affecté.",
  account_closed:
    "Le dossier est clôturé : le paiement sera mis en attente, sans imputation, pour être reversé au client (dossier rappelé) ou remboursé au payeur.",
  currency_mismatch:
    "Le paiement n'est pas dans la devise du dossier : il sera mis en attente, sans conversion ni imputation, et remboursé par défaut.",
  before_servicing_start:
    "Le paiement est antérieur à la reprise du dossier : il sera mis en attente, à vérifier avec le client avant toute imputation.",
  hold_blocks_allocation:
    "Le dossier est bloqué (surendettement ou procédure collective) : le paiement sera mis en attente, ni imputé ni reversé, jusqu'à décision.",
  nothing_due:
    "Le dossier ne présente plus rien à payer : le paiement sera mis en attente, à vérifier, sinon remboursé au payeur.",
};

/** The sentence the confirmation sheet ends with: what happens after the assignment. */
export function outcomeText(reason: string | null): string {
  if (reason === null) return "Il sera imputé sur ses factures à l'étape suivante, dans l'ordre légal.";
  return OUTCOME_TEXT[reason] ?? reviewReason(reason).help;
}

/** A payment and the file the page showed for it, as accept_suggestions takes them. */
export type AcceptItem = { payment_id: string; account_id: string };
export type AcceptSkip = { payment_id: string; reason: string };
export type AcceptResult = { ok: true; accepted: number; skipped: AcceptSkip[] } | { error: ErrorCode };

/** « payment:file » values of the accept forms; null when one of them is not a pair of ids. */
export function parseAcceptItems(values: string[]): AcceptItem[] | null {
  const items: AcceptItem[] = [];
  for (const v of values) {
    const [payment, account, ...rest] = v.split(":");
    if (rest.length > 0 || !UUID_RE.test(payment ?? "") || !UUID_RE.test(account ?? "")) return null;
    items.push({ payment_id: payment, account_id: account });
  }
  return items;
}

const SKIP_LABEL: Record<string, string> = {
  suggestion_changed: "suggestion modifiée entre-temps",
  no_suggestion: "plus de suggestion",
  not_waiting: "déjà traité",
};

function count(n: number, one: string, many: string): string {
  return `${n} ${n > 1 ? many : one}`;
}

/** What accept_suggestions did, in French: how many were accepted, which were skipped and why. */
export function acceptNotice(accepted: number, skipped: AcceptSkip[]): { text: string; tone: Tone } {
  const done = accepted === 0 ? "Aucune suggestion acceptée" : count(accepted, "suggestion acceptée", "suggestions acceptées");
  if (skipped.length === 0) return { text: `${done}.`, tone: "ok" };
  const reasons = new Map<string, number>();
  for (const s of skipped) reasons.set(s.reason, (reasons.get(s.reason) ?? 0) + 1);
  const why = [...reasons].map(([reason, n]) => `${SKIP_LABEL[reason] ?? reason} (${n})`).join(", ");
  return {
    text: `${done} ; ${count(skipped.length, "paiement ignoré", "paiements ignorés")} : ${why}. Vérifiez les propositions à jour.`,
    tone: "action",
  };
}

/** The last page of a tab holding `total` payments (a page past it shows a way back). */
export function lastPage(total: number): number {
  return Math.max(1, Math.ceil(total / QUEUE_PAGE_SIZE));
}

/** Errors of assign_payment / accept_suggestions / unassign_payment, as codes. */
export function matchingErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("reason is required")) return "reason_required";
  if (message.includes("already matched")) return "already_matched";
  if (message.includes("not confirmed yet")) return "file_not_confirmed";
  if (message.includes("splitting comes with allocation")) return "split_not_available";
  if (message.includes("unknown file")) return "unknown_file";
  if (message.includes("is not matched")) return "not_matched";
  if (message.includes("is allocated")) return "payment_allocated";
  if (message.includes("lock") || message.includes("canceling statement")) return "busy";
  if (message.includes("designation")) return "designation_invalid";
  return "unknown";
}

export type QueueQuery = {
  onglet: "a-traiter" | "rapproches";
  motif: string | null;
  client: string | null;
  min: bigint | null;
  max: bigint | null;
  age: number | null;
  page: number;
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const QUEUE_PAGE_SIZE = 20;

/** Euros typed in a filter ("1 234,5") as minor units, or null. Never through a float. */
export function eurosToMinor(text: string): bigint | null {
  const m = /^(\d{1,12})(?:[.,](\d{1,2}))?$/.exec(text.replace(/[\s  €]/g, ""));
  return m ? BigInt(m[1]) * BigInt(100) + BigInt((m[2] ?? "").padEnd(2, "0")) : null;
}

/** The queue's filters from the URL (anything else falls back to the default). */
export function queueQuery(query: Record<string, string | string[] | undefined>): QueueQuery {
  const text = (v: string | string[] | undefined) => (typeof v === "string" ? v.trim() : "");
  const motif = REASON_FILTERS.some((r) => r.value === text(query.motif)) ? text(query.motif) : null;
  const age = /^\d{1,4}$/.test(text(query.age)) ? Number(text(query.age)) : null;
  const page = /^[1-9]\d{0,5}$/.test(text(query.page)) ? Number(text(query.page)) : 1;
  return {
    onglet: text(query.onglet) === "rapproches" ? "rapproches" : "a-traiter",
    motif,
    client: UUID_RE.test(text(query.client)) ? text(query.client) : null,
    min: eurosToMinor(text(query.min)),
    max: eurosToMinor(text(query.max)),
    age,
    page,
  };
}

/** The queue's URL for a query (defaults left out). */
export function queueHref(q: QueueQuery, changes: Partial<QueueQuery> = {}): string {
  const n = { ...q, ...changes };
  const params = new URLSearchParams();
  if (n.onglet !== "a-traiter") params.set("onglet", n.onglet);
  if (n.motif) params.set("motif", n.motif);
  if (n.client) params.set("client", n.client);
  if (n.min !== null) params.set("min", minorToEuros(n.min));
  if (n.max !== null) params.set("max", minorToEuros(n.max));
  if (n.age !== null) params.set("age", String(n.age));
  if (n.page > 1) params.set("page", String(n.page));
  const search = params.toString();
  return `/backoffice/encaissements/a-traiter${search ? `?${search}` : ""}`;
}

/** Minor units as typed euros ("123450" -> "1234,50"), for a filter field. */
export function minorToEuros(minor: bigint): string {
  const cents = (minor % BigInt(100)).toString().padStart(2, "0");
  return `${minor / BigInt(100)},${cents}`;
}

/** « 96 % » of the payments of a statement matched by a rule (integer percentage, rounded down). */
export function autoShare(automatic: number, payments: number): string {
  if (payments === 0) return "–";
  return `${Math.floor((automatic * 100) / payments)} %`;
}
