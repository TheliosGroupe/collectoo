import type { ErrorCode } from "@/lib/boarding/forms";
import { money } from "@/lib/payments/statements";

/**
 * M2c-4 « Reversements » (design §17.1–§17.2): the words of the runs' states, blockers and failures, the deadline
 * chip, the amounts of a run's card. Every amount comes from the database as text (integer minor units): never a JS
 * number. No copy says « payé » before the bank's debit (M2c-6): a run is « validé », its transfer « ordonné ».
 */

type Tone = "neutral" | "busy" | "action" | "ok" | "error";

export type RunCard = {
  id: string;
  number: string;
  status: string;
  trigger: string;
  currency: string;
  client_id: string;
  client_name: string;
  version: number;
  job: string | null;
  known_at: string;
  prepared_at: string | null;
  item_count: number;
  line_count: number | null;
  gross_minor: string | null;
  net_minor: string | null;
  settlement_minor: string | null;
  invoice_ttc_minor: string | null;
  credit_ttc_minor: string | null;
  commission_taken_minor: string | null;
  refund_minor: string | null;
  advance_recovered_minor: string | null;
  earliest_latest_execution_date: string | null;
  earliest_deadline: string | null;
  unmeetable_count: number;
  requested_execution_date: string | null;
  blockers: string[];
  commission_blockers: string[];
  inputs_hash: string | null;
  last_failure: { code: string; detail?: string; at?: string; step?: string } | null;
  approved_at: string | null;
  booked_on: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
  invoice_late: boolean;
  deadline_state: "ok" | "soon" | "critical" | "late" | null;
  payout: { iban_last4: string; holder_name: string; confirmed_at: string | null; new_iban: boolean } | null;
};

export const RUN_TABS: Record<string, { label: string }> = {
  "a-valider": { label: "À valider" },
  "en-cours": { label: "En cours" },
  termines: { label: "Terminés" },
};

export function runTab(value: string | string[] | undefined): string {
  const v = Array.isArray(value) ? value[0] : value;
  return v && v in RUN_TABS ? v : "a-valider";
}

type RunState = Pick<RunCard, "status" | "job" | "prepared_at"> & Partial<Pick<RunCard, "last_failure">>;

/**
 * A draft whose preparation failed (review M2c-4 tests-ui#3): no job in flight, never prepared, its last failure at
 * the prepare step (`private.remittance_prepare_failed`). Nothing retries it: ops « Actualiser » or « Abandonner ».
 */
export function prepareFailed(card: RunState): boolean {
  return card.status === "draft" && card.job === null && card.prepared_at === null && card.last_failure?.step === "prepare";
}

/** A run with work in flight (a job, or a draft not yet prepared): the pages refresh themselves meanwhile. */
export function runBusy(card: RunState): boolean {
  return card.job !== null || (card.status === "draft" && card.prepared_at === null && !prepareFailed(card));
}

export function runStatus(card: RunState): { label: string; tone: Tone } {
  if (card.status === "draft") {
    if (prepareFailed(card)) return { label: "Préparation échouée — actualisez", tone: "error" };
    if (card.job === "prepare" || card.prepared_at === null) return { label: "Préparation en cours", tone: "busy" };
    if (card.job === "approve") return { label: "Validation en cours", tone: "busy" };
    return { label: "Brouillon", tone: "action" };
  }
  const s: Record<string, { label: string; tone: Tone }> = {
    approved: { label: "Validé — virement ordonné", tone: "ok" },
    sent: { label: "Fichier transmis à la banque", tone: "ok" },
    booked: { label: "Comptabilisé", tone: "ok" },
    cancelled: { label: "Annulé", tone: "neutral" },
  };
  return s[card.status] ?? { label: card.status, tone: "neutral" };
}

export const TRIGGER_LABEL: Record<string, string> = {
  schedule: "Échéance du mandat",
  deadline: "Échéance R124-6",
  payout_returned: "Virement revenu",
  manual: "Préparé à la demande",
};

const BLOCKER_LABEL: Record<string, string> = {
  client_funds_account_missing: "Aucun compte dédié actif dans cette devise",
  several_client_funds_accounts: "Plusieurs comptes dédiés actifs dans cette devise",
  payout_account_missing: "Aucun IBAN de reversement confirmé",
  payout_account_unconfirmed: "IBAN de reversement en attente de confirmation",
  payout_account_returned: "Dernier virement revenu : IBAN à remplacer ou reconfirmer",
  "client_status:liquidation": "Client en liquidation : compte du liquidateur à confirmer",
  "client_status:death": "Décès du client enregistré",
  "client_status:guardianship": "Client sous tutelle ou curatelle",
  "client_status:mandate_ended": "Mandat terminé",
  negative_net: "Net négatif : les annulations dépassent les encaissements",
  servicer_identity_incomplete: "Identité de facturation du cabinet incomplète",
  client_identity_changed: "Le client n'est plus un professionnel établi en France métropolitaine",
  commission_terms_incomplete: "Conditions du mandat incomplètes (références des clauses)",
};

/** A blocker (payout) or a reason the commission stays pending, in French. */
export function blockerLabel(code: string): string {
  if (code.startsWith("commission_input_error")) return "La commission n'a pas pu être calculée (données à vérifier)";
  return BLOCKER_LABEL[code] ?? code;
}

/**
 * Review M2c-5b (security-concurrency#0, F5): a draft whose commission the engine refused to compute (its history read
 * while a credit note committed, or data to check). The database refuses to approve it (`engine_error`); the card says
 * « Actualiser » and its box stays unticked.
 */
export function commissionNotComputed(card: Pick<RunCard, "commission_blockers">): boolean {
  return card.commission_blockers.some((b) => b.startsWith("commission_input_error"));
}

const FAILURE_LABEL: Record<string, string> = {
  stale: "le brouillon a changé depuis l'affichage",
  vat_rate_changed: "le taux de TVA du jour n'est plus celui du brouillon : actualisez",
  commission_blocked: "la commission ne peut plus être facturée (identités)",
  payout_account_changed: "l'IBAN de reversement a changé depuis la préparation : actualisez",
  balance_changed: "solde modifié depuis l'aperçu : actualisez",
  history_changed: "l'historique des commissions a changé : actualisez",
  documents_changed: "les factures ouvertes ont changé : actualisez",
  items_changed: "les encaissements réservés ont changé : actualisez",
  negative_net: "net négatif",
  late_reason_required: "motif du retard requis",
  // the command's own refusals (review M2c-4 tests-ui#4, contract C1)
  unknown_run: "reversement introuvable",
  not_draft: "n'est plus un brouillon : rechargez",
  preparing: "préparation en cours : réessayez",
  approval_in_progress: "déjà en cours de validation",
  payout_blocked: "virement bloqué",
  busy: "traitement en cours sur ce reversement : réessayez",
  // the job's re-checks against what the draft was prepared with (money#1, money#2)
  vat_option_changed: "option TVA modifiée depuis la préparation : actualisez",
  client_status_changed: "situation du client modifiée depuis la préparation : actualisez",
  execution_date_passed: "la date d'exécution demandée est passée",
  execution_date_not_business_day: "la date d'exécution demandée n'est pas un jour ouvré",
  execution_date_after_cutoff: "exécution le jour même impossible après l'heure limite de la banque",
  approval_timeout: "la validation n'a pas abouti en 10 minutes",
  approval_failed: "la validation a échoué après plusieurs essais",
  prepare_failed: "la préparation a échoué",
  not_prepared: "le brouillon n'est pas préparé",
  // review M2c-5b (security-concurrency#0, F5): the draft's commission could not be computed (data read mid-change)
  engine_error: "la commission de certains encaissements n'a pas pu être calculée : actualisez le brouillon",
};

/** Why a run went back to draft (last_failure.code), as « Renvoyé en brouillon : … », or why the approval refused it. */
export function failureLabel(code: string): string {
  if (code.startsWith("payout_blocked:")) return `virement bloqué — ${blockerLabel(code.slice("payout_blocked:".length))}`;
  if (code.startsWith("data_error:")) return "les données ont été refusées par la base (voir le support)";
  return FAILURE_LABEL[code] ?? code;
}

/**
 * The note a draft's last failure shows (review M2c-4 tests-ui#3): a failed preparation says what to do; an approval
 * sent back says why (« Renvoyé en brouillon : … »).
 */
export function failureNote(failure: RunCard["last_failure"]): string | null {
  if (!failure) return null;
  if (failure.step === "prepare") return `Préparation échouée : ${failureLabel(failure.code)} — « Actualiser » la relance`;
  return `Renvoyé en brouillon : ${failureLabel(failure.code)}`;
}

/** The deadline chip (§17.1): green, orange from J-5 business days, red from J-1 and past. */
export function deadlineChip(date: string | null, state: RunCard["deadline_state"]): { label: string; tone: Tone } | null {
  if (!date) return null;
  const label = `Exécution au plus tard le ${frenchDate(date)}`;
  if (state === "late") return { label: `Délai dépassé : ${frenchDate(date)}`, tone: "error" };
  if (state === "critical") return { label, tone: "error" };
  if (state === "soon") return { label, tone: "action" };
  return { label, tone: "ok" };
}

export function frenchDate(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-");
  return `${d}/${m}/${y}`;
}

/** « IBAN confirmé il y a 3 j » (whole days since the confirmation, Paris calendar not needed for a badge). */
export function confirmedAgo(confirmedAt: string | null, now: Date = new Date()): string | null {
  if (!confirmedAt) return null;
  const days = Math.max(0, Math.floor((now.getTime() - new Date(confirmedAt).getTime()) / 86_400_000));
  return days === 0 ? "IBAN confirmé aujourd'hui" : `IBAN confirmé il y a ${days} j`;
}

/** Σ of minor-unit texts (BigInt), as text: the sticky « Valider n reversements · total ». */
export function sumMinor(values: (string | null | undefined)[]): string {
  return values.reduce((acc, v) => (v && /^-?\d+$/.test(v) ? acc + BigInt(v) : acc), BigInt(0)).toString();
}

/** What a run's line commission says (parts as stored by the engine): « 15 % sur 2 000,00 € ». */
export type Part = { rule_id: string; label_fr: string; tiers: [string, string][]; commission: string; held: string };

/** A rate as written (« 0.1500 », at most 4 decimals) in French percent, by string arithmetic (no float). */
export function percentText(rate: string): string {
  const m = /^(\d+)(?:\.(\d{1,4}))?$/.exec(rate);
  if (!m) return rate;
  const frac = (m[2] ?? "").padEnd(4, "0");
  const whole = (BigInt(m[1]) * BigInt(100) + BigInt(frac.slice(0, 2))).toString();
  const decimals = frac.slice(2).replace(/0+$/, "");
  return `${whole}${decimals ? `,${decimals}` : ""}\u00a0%`;
}

const COMMAND_ERRORS: [string, ErrorCode][] = [
  ["not allowed", "not_allowed"],
  ["run_pending", "run_pending"],
  ["nothing_pending", "nothing_pending"],
  ["version_changed", "run_version_changed"],
  ["not_draft", "run_not_draft"],
  ["approval_in_progress", "run_approval_in_progress"],
  ["already_sent", "run_already_sent"],
  ["transfer_in_file", "run_already_sent"],
  ["not_cancellable", "run_not_cancellable"],
  ["draft_use_discard", "run_not_cancellable"],
  ["a reason is required", "reason_required"],
  ["1 to 200 runs", "run_none_selected"],
  ["business calendar", "execution_date_invalid"],
  // a run, or the servicer's allocation work, locked by a job or another command (review M2c-4 tests-ui#5)
  ["could not obtain lock", "run_busy"],
  ["lock timeout", "run_busy"],
  // the commands' allocation lock waited too long (cancel, refresh, discard; review M2c-4 perf#4)
  ["allocation_busy", "run_busy"],
  // the documents' day turned at Paris midnight during the command (review M2c-4 nc#1): a new try works
  ["the day turned", "run_retry"],
];

/** Code for an error raised by a run command (never the database's text on the page). */
export function runErrorCode(message: string): ErrorCode {
  for (const [needle, code] of COMMAND_ERRORS) if (message.includes(needle)) return code;
  return "unknown";
}

export type ApprovalOutcome = { summary: string; queued: number; refused: number };

/** The approval's per-run outcome, as the result line says it (« 3 en validation ; RV-… refusé : … »), and its counts. */
export function approvalSummary(results: { number: string | null; status: string; reason: string | null }[]): ApprovalOutcome {
  const queued = results.filter((r) => r.status === "queued").length;
  const refused = results.filter((r) => r.status !== "queued");
  const parts = [`${queued} en validation`];
  for (const r of refused) parts.push(`${r.number ?? "?"} refusé : ${failureLabel(r.reason ?? "")}`);
  return { summary: parts.join(" ; "), queued, refused: refused.length };
}

/** The result line's colour: green when every run was queued, orange when some were refused, red when all were. */
export function summaryTone(o: Pick<ApprovalOutcome, "queued" | "refused">): "ok" | "action" | "error" {
  if (o.refused === 0) return "ok";
  return o.queued > 0 ? "action" : "error";
}

const MINOR = /^-?\d+$/;

/**
 * Whether the approval needs « Motif du retard » (design §9.5; review M2c-4 money#3), as the command decides it: a run
 * that transfers (N > 0) when the requested execution date is after its earliest latest execution date; a run that
 * transfers nothing (N = 0, settled at approval, today) when today (Europe/Paris) is after it.
 */
export function lateReasonRequired(
  runs: Pick<RunCard, "net_minor" | "earliest_latest_execution_date">[],
  date: string,
  today: string,
): boolean {
  return runs.some((r) => {
    const latest = r.earliest_latest_execution_date;
    if (latest === null || r.net_minor === null || !MINOR.test(r.net_minor)) return false;
    const net = BigInt(r.net_minor);
    if (net > BigInt(0)) return date > latest;
    return net === BigInt(0) && today > latest;
  });
}

/**
 * A credit note's refund owed to the client (review M2c-4 legal#5): paid with the run's payout, so « remboursé » only
 * once the run is booked (the bank's debit, M2c-6; or settled at approval when nothing is transferred).
 */
export function refundNote(card: Pick<RunCard, "status" | "refund_minor" | "currency">): string | null {
  if (!card.refund_minor || !MINOR.test(card.refund_minor) || BigInt(card.refund_minor) === BigInt(0)) return null;
  const amount = money(card.refund_minor, card.currency);
  return card.status === "booked" ? `avoir remboursé ${amount}` : `remboursement d'avoir inclus dans le virement : ${amount}`;
}
