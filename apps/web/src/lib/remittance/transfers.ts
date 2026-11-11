import type { ErrorCode } from "@/lib/boarding/forms";
import type { Database } from "@/lib/database.types";
import { money } from "@/lib/payments/statements";
import { blockerLabel, frenchDate } from "@/lib/remittance/runs";

/**
 * M2c-6a « Virements » (design §11, §17.3): the words of the transfers, the files, why a transfer is held out of a
 * file, the cash check and the warnings. Every amount comes from the database as text (integer minor units), never a
 * JS number. Nothing here says « payé » or « débité » before the bank's statement shows the debit (M2c-6b books it).
 */

type Tone = "neutral" | "busy" | "action" | "ok" | "error";

export type TransferCard = {
  transfer_id: string;
  kind: "payout" | "refund" | "sweep" | "top_up";
  status: string;
  amount_minor: string;
  currency: string;
  payee_name: string;
  iban_last4: string;
  end_to_end_id: string;
  remittance_info: string | null;
  requested_execution_date: string;
  execution_date?: string;
  run_id: string | null;
  run_number: string | null;
  run_status: string | null;
  run_version: number | null;
  client_id: string | null;
  client_name: string | null;
  refund_request_id: string | null;
  payment_id: string | null;
  hold: string | null;
  payee_check_open: boolean;
};

export type CashPosition = {
  statement_id: string;
  closing_date: string;
  closing_minor: string;
  debits_since_minor: string;
  in_flight_minor: string;
  in_flight_count: number;
  manual_refunds_minor: string;
  available_minor: string;
  ctrl_sum_minor?: string;
  sweep_left_minor?: string;
};

export type FileCard = {
  id: string;
  number: string;
  status: string;
  version: number;
  pain_version: string;
  nb_of_txs: number;
  ctrl_sum_minor: string;
  currency: string;
  first_execution_date: string;
  last_execution_date: string;
  created_at: string;
  generated_at: string | null;
  xsd_validated: boolean | null;
  file_sha256: string | null;
  size_bytes: number | null;
  download_count: number;
  first_downloaded_at: string | null;
  first_downloaded_by: string | null;
  sent_marked_at: string | null;
  sent_marked_by: string | null;
  closed_at: string | null;
  close_reason: string | null;
  close_attestation: string | null;
  error: string | null;
  late_reason: string | null;
  held_count: number;
  /** M2c-6a review (T2): the database's own flag of a generated file no longer downloadable (a reason code), when given */
  stale?: string | boolean | null;
  /** M2c-6a review (T1): the two-step cancellation of a downloaded or sent file, when the database gives it */
  cancellation?: unknown;
};

export type PayingAccount = {
  bank_account_id: string;
  label: string;
  iban_last4: string;
  bic: string | null;
  currency: string;
  pain_version: string;
  earliest_execution_date: string;
  cash: CashPosition | null;
  sweep_preview_minor: string;
  /** review round 2 (D4): why no sweep is proposed although the servicer's share is on the account */
  sweep_hold?: string | null;
  to_file_count: number;
  eligible_count: number;
  eligible_total_minor: string;
  late_count: number;
  to_file: TransferCard[];
  files: FileCard[];
};

export type PayeeCheck = {
  check_id: string;
  client_id: string;
  client_name: string;
  payout_account_id: string;
  iban_last4: string;
  holder_name: string;
  result: "no_match" | "close_match";
  bank_name: string | null;
  note: string;
  recorded_at: string;
  recorded_by: string | null;
  recorded_by_me: boolean;
  transfer_id: string | null;
  /**
   * M2c-6a review (T5): false when the viewer may not clear it — who recorded the mismatch, or proposed or confirmed the
   * flagged IBAN; absent before the database gives it (then only `recorded_by_me` is known)
   */
  can_clear?: boolean;
};

export type TransferOverview = {
  today: string;
  accounts: PayingAccount[];
  own_account: { id: string; label: string; iban_last4: string } | null;
  payee_checks: PayeeCheck[];
  can_admin: boolean;
};

export type FileItem = TransferCard & {
  seq: number;
  pmt_inf_id: string;
  late: boolean;
  debit_seen: boolean;
  /** M2c-6a review (T1): the two-step cancellation of this one transfer, when the database gives it */
  cancellation?: unknown;
};

export type FileDetail = FileCard & {
  bank_account: { id: string; label: string; iban_last4: string };
  cash_check: CashPosition;
  held: (TransferCard & { reason: string })[];
  downloads: { n: number; at: string; warning_acknowledged: boolean; by: string | null }[];
  items: FileItem[];
  next_after_seq: number | null;
  statuses: Record<string, number>;
  can_admin: boolean;
};

export const TRANSFER_KIND: Record<string, string> = {
  payout: "Reversement",
  refund: "Remboursement",
  sweep: "Quote-part du cabinet vers le compte propre",
  top_up: "Approvisionnement du compte dédié",
};

/** A transfer where it stands (bank_transfer.status). */
export const TRANSFER_STATUS: Record<string, { label: string; tone: Tone }> = {
  ordered: { label: "À mettre dans un fichier", tone: "action" },
  in_file: { label: "Dans un fichier de virements", tone: "busy" },
  booked: { label: "Débité", tone: "ok" },
  returned: { label: "Revenu", tone: "error" },
  cancelled: { label: "Annulé", tone: "neutral" },
};

/** A file where it stands (transfer_file.status): « Téléchargé » is not « transmis » until ops say so. */
export const FILE_STATUS: Record<string, { label: string; tone: Tone }> = {
  pending: { label: "En préparation", tone: "busy" },
  generated: { label: "Prêt à télécharger", tone: "action" },
  downloaded: { label: "Téléchargé — à déposer à la banque", tone: "action" },
  sent: { label: "Transmis à la banque", tone: "ok" },
  superseded: { label: "Remplacé", tone: "neutral" },
  rejected: { label: "Rejeté par la banque", tone: "error" },
  failed: { label: "Échec de l'écriture", tone: "error" },
};

export function fileStatus(status: string): { label: string; tone: Tone } {
  return FILE_STATUS[status] ?? { label: status, tone: "neutral" };
}

/** A file is live while its transfers wait in it (the cash check counts a downloaded or sent one in flight). */
export function fileLive(status: string): boolean {
  return ["pending", "generated", "downloaded", "sent"].includes(status);
}

const HOLD_LABEL: Record<string, string> = {
  payout_not_covered:
    "Montant supérieur à ce qui reste dû au client (un encaissement a été annulé depuis la validation) : annulez le reversement et préparez-en un nouveau",
  late_reason_required: "Exécution après la date limite du reversement : un motif du retard est demandé",
  payout_account_changed: "L'IBAN de reversement a changé depuis la validation : annulez le reversement et préparez-en un nouveau",
  run_not_in_flight: "Le reversement n'est plus en cours",
  refund_not_pending: "Le remboursement n'est plus en attente",
  not_eur: "Seuls les virements en euros passent par un fichier SEPA",
  // M2c-6a review (T3): held out of the file rather than failing it for every other transfer
  payee_name_not_epc:
    "Le nom du bénéficiaire n'a aucun caractère accepté par le format SEPA (lettres latines sans accent, chiffres) : il reste hors du fichier. Remboursement : annulez-le et redemandez-le avec le nom en lettres latines ; reversement : faites confirmer le compte de reversement avec le nom du titulaire en lettres latines",
  iban_not_sepa:
    "L'IBAN du bénéficiaire est hors de la zone SEPA : un fichier SEPA ne peut pas le payer, il reste hors du fichier. Remboursement : annulez-le et redemandez-le « à exécuter vous-même » ; reversement : faites confirmer un IBAN de la zone SEPA",
  // M2c-6a review (T2): a file refused at download (its whole CtrlSum no longer covered by the dedicated account)
  cash_not_covered:
    "Le solde du compte dédié ne couvre plus le fichier (dernier relevé, moins ce qui est déjà en route) : importez le dernier relevé, puis régénérez",
  no_closing_balance: "Aucun relevé avec solde de clôture n'est importé pour le compte dédié : importez-en un, puis régénérez",
  // M2c-6a review, round 2 (D4): a cancelled file executed late after all — filing it again would pay twice
  already_debited:
    "Un relevé montre déjà le débit de ce virement — sous sa référence de bout en bout, celle du virement qu'il remplace, ou dans une ligne groupée d'un fichier annulé depuis (exécuté plus tard malgré tout) : il reste hors des fichiers pour ne pas payer deux fois. Ne le refaites pas ; le débit sera rattaché (prévenez le support)",
};

/** Why the sweep a file would carry is not proposed (review round 2, D4). */
const SWEEP_HOLD_LABEL: Record<string, string> = {
  cancelled_sweep_debited:
    "Quote-part du cabinet non proposée : un virement de quote-part annulé a quand même été débité (relevé) sans être revenu. Aucune nouvelle quote-part ne part tant que ce débit n'est pas rattaché (prévenez le support)",
};

/** The words for a sweep held back, or null when none is. */
export function sweepHoldLabel(code: string | null | undefined): string | null {
  if (!code) return null;
  return SWEEP_HOLD_LABEL[code] ?? code;
}

/** The same reasons under the names the review's findings used (pain001#2, pain001#4), should the database send them. */
const HOLD_ALIAS: Record<string, string> = {
  iban_outside_sepa: "iban_not_sepa",
  payee_name_not_latin: "payee_name_not_epc",
};

/** Why a transfer is held out of a file generated today (null: it goes in). */
export function holdLabel(code: string | null): string | null {
  if (code === null) return null;
  if (code.startsWith("payout_blocked:")) return `Virement bloqué — ${payoutBlockerLabel(code.slice("payout_blocked:".length))}`;
  return HOLD_LABEL[HOLD_ALIAS[code] ?? code] ?? code;
}

/** The payout blockers of runs (M2c-4), and the payee check of M2c-6a. */
export function payoutBlockerLabel(code: string): string {
  if (code === "payee_name_mismatch")
    return "la banque a signalé un nom de bénéficiaire non concordant : à vérifier avec le client";
  return blockerLabel(code);
}

/** « Déjà téléchargé par Léa le 02/11 à 09:41 — ne le déposez pas deux fois » (ops critique #33). */
export function downloadWarning(file: Pick<FileCard, "download_count" | "first_downloaded_at" | "first_downloaded_by">): string | null {
  if (file.download_count === 0 || !file.first_downloaded_at) return null;
  return `Déjà téléchargé par ${file.first_downloaded_by ?? "un utilisateur"} le ${parisDayMonth(file.first_downloaded_at)} à ${parisTime(file.first_downloaded_at)} — ne le déposez pas deux fois`;
}

function parisParts(iso: string): Record<string, string> {
  const parts = new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Europe/Paris",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(iso));
  return Object.fromEntries(parts.map((p) => [p.type, p.value]));
}

/** « 02/11 » in Paris time. */
export function parisDayMonth(iso: string): string {
  const p = parisParts(iso);
  return `${p.day}/${p.month}`;
}

/** « 09:41 » in Paris time. */
export function parisTime(iso: string): string {
  const p = parisParts(iso);
  return `${p.hour}:${p.minute}`;
}

/** « 02/11/2026 à 09:41 » in Paris time. */
export function parisDateTime(iso: string): string {
  const p = parisParts(iso);
  return `${p.day}/${p.month}/${p.year} à ${p.hour}:${p.minute}`;
}

/** The cash check as the page says it (design §11: the last closing balance, less what already left or will). */
export function cashLines(cash: CashPosition | null, currency: string): string[] {
  if (!cash) return ["Aucun relevé avec solde de clôture importé : importez le dernier relevé du compte avant de générer un fichier."];
  const lines = [`Solde au ${frenchDate(cash.closing_date)} : ${money(cash.closing_minor, currency)}`];
  if (cash.debits_since_minor !== "0") lines.push(`débits importés depuis : − ${money(cash.debits_since_minor, currency)}`);
  if (cash.in_flight_minor !== "0")
    lines.push(
      `${cash.in_flight_count} virement${cash.in_flight_count > 1 ? "s" : ""} déjà en route (fichiers téléchargés, débit non encore vu) : − ${money(cash.in_flight_minor, currency)}`,
    );
  if (cash.manual_refunds_minor !== "0")
    lines.push(`remboursements à exécuter dans la banque : − ${money(cash.manual_refunds_minor, currency)}`);
  lines.push(`disponible pour un fichier : ${money(cash.available_minor, currency)}`);
  return lines;
}

/** What « Générer le fichier » will do (the sheet states every effect, §17.1 style). */
export function generationEffects(a: PayingAccount, ownAccount: TransferOverview["own_account"]): string[] {
  const out: string[] = [];
  const n = a.eligible_count;
  const replaced = replacedFiles(a);
  if (n > 0 || replaced.length === 0)
    out.push(
      n === 0
        ? "Aucun reversement ni remboursement à mettre dans le fichier."
        : `${n} virement${n > 1 ? "s" : ""} depuis ${a.label} (…${a.iban_last4}) : ${money(a.eligible_total_minor, a.currency)}, exécution demandée au plus tôt le ${frenchDate(a.earliest_execution_date)}.`,
    );
  // M2c-6a review (T2): a file not downloaded is replaced; its transfers come in the new one if they pass today's checks
  for (const f of replaced)
    out.push(
      `Le fichier ${f.number} (${f.nb_of_txs} virement${f.nb_of_txs > 1 ? "s" : ""}, ${money(f.ctrl_sum_minor, f.currency)}) n'a pas été téléchargé${fileStale(f, a.earliest_execution_date) ? " et sa date d'exécution est passée" : ""} : il est remplacé, et ses virements sont repris s'ils passent les contrôles d'aujourd'hui (exécution au plus tôt le ${frenchDate(a.earliest_execution_date)}).`,
    );
  if (a.sweep_preview_minor !== "0") {
    out.push(
      ownAccount
        ? `La quote-part du cabinet réglée sur le compte dédié, ${money(a.sweep_preview_minor, a.currency)}, part dans le même fichier vers le compte propre (…${ownAccount.iban_last4}) — après les clients si le solde ne couvre pas tout.`
        : "La quote-part du cabinet reste sur le compte dédié : aucun compte propre n'est renseigné dans « Facturation ».",
    );
  }
  const sweepHold = sweepHoldLabel(a.sweep_hold);
  if (sweepHold) out.push(`${sweepHold}.`);
  const held = a.to_file_count - a.eligible_count;
  if (held > 0) out.push(`${held} virement${held > 1 ? "s restent" : " reste"} hors du fichier (motif affiché).`);
  if (a.late_count > 0) out.push(`${a.late_count} virement${a.late_count > 1 ? "s" : ""} après la date limite : le motif du retard est enregistré sur le fichier.`);
  out.push(
    `Format ${a.pain_version}. Un fichier non encore téléchargé est remplacé par le nouveau (nouveau numéro). Rien n'est comptabilisé avant le débit sur le relevé.`,
  );
  return out;
}

/** The account's files a new generation replaces: those not downloaded yet (design §11; one live file per account). */
export function replacedFiles(a: Pick<PayingAccount, "files">): FileCard[] {
  return a.files.filter((f) => f.status === "pending" || f.status === "generated");
}

/**
 * M2c-6a review (T2, pain001#0): a generated file no longer downloadable — its requested execution date is before the
 * paying account's next execution day now (the cut-off passed), or the database flags it. The download would refuse it
 * (`file_stale`) and replace it: the page offers « Régénérer » instead of « Télécharger ».
 */
export function fileStale(f: Pick<FileCard, "status" | "first_execution_date" | "stale">, earliestExecutionDate: string | null): boolean {
  if (f.status !== "generated") return false;
  if (f.stale === true || (typeof f.stale === "string" && f.stale !== "")) return true;
  return earliestExecutionDate !== null && f.first_execution_date < earliestExecutionDate;
}

/** Whether « Générer le fichier » has something to do: transfers to file, the sweep, or a file to replace. */
export function canGenerate(a: PayingAccount): boolean {
  return a.currency === "EUR" && (a.eligible_count > 0 || a.sweep_preview_minor !== "0" || replacedFiles(a).length > 0);
}

/** « Régénérer le fichier » when it replaces a stale file (T2), « Générer le fichier » otherwise. */
export function generateLabel(a: PayingAccount): string {
  return replacedFiles(a).some((f) => fileStale(f, a.earliest_execution_date)) ? "Régénérer le fichier" : "Générer le fichier";
}

/** What « Régénérer » does from a file's own page (its account's overview is not read there). */
export function regenerationEffects(f: Pick<FileDetail, "bank_account" | "number">): string[] {
  return [
    `Un nouveau fichier est généré pour ${f.bank_account.label} (…${f.bank_account.iban_last4}), avec un nouveau numéro et l'exécution au plus tôt au prochain jour ouvré du compte.`,
    `Il reprend les virements à mettre dans un fichier, dont ceux du fichier ${f.number} qui passent les contrôles d'aujourd'hui ; les autres restent hors du fichier, avec leur motif sur « Virements ».`,
    "Un virement après sa date limite n'y entre qu'avec un motif du retard (sinon il reste hors du fichier). Rien n'est comptabilisé avant le débit sur le relevé.",
  ];
}

/** Paris's calendar day of an instant, as the database's dates (YYYY-MM-DD). */
export function parisDate(now: Date): string {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("fr-FR", { timeZone: "Europe/Paris", day: "2-digit", month: "2-digit", year: "numeric" })
      .formatToParts(now)
      .map((x) => [x.type, x.value]),
  );
  return `${p.year}-${p.month}-${p.day}`;
}

export const PAIN_VERSIONS = ["pain.001.001.09", "pain.001.001.03"] as const;

export const ATTESTATION_LABEL: Record<string, string> = {
  not_uploaded: "Le fichier n'a pas été déposé à la banque",
  rejected_by_bank: "La banque a rejeté le fichier en entier",
};

const COMMAND_ERRORS: [string, ErrorCode][] = [
  ["not allowed", "not_allowed"],
  // M2c-6a review (T1): a downloaded file or one of its transfers is cancelled by two people, with the statement's evidence
  ["no_statement_evidence", "transfer_no_statement_evidence"],
  // review round 2 (D2, D3): one transfer only from an executed file; a batch debit that does not single it out
  ["file_not_executed", "transfer_file_not_executed"],
  ["batch_ambiguous", "transfer_batch_ambiguous"],
  ["same_person", "transfer_same_person"],
  ["already_requested", "transfer_cancel_already_requested"],
  ["not_requested", "transfer_cancel_not_requested"],
  ["no_request", "transfer_cancel_not_requested"],
  ["cancellation_request_required", "transfer_cancellation_request_required"],
  ["not_in_downloaded_file", "transfer_not_in_downloaded_file"],
  ["not_live", "transfer_not_live"],
  ["late_reason_too_long", "transfer_late_reason_too_long"],
  ["not_a_payout", "payee_check_not_a_payout"],
  // M2c-6a review (T2): the download re-ran the generation's checks and replaced the file
  ["file_stale", "transfer_file_stale"],
  ["file_blocked", "transfer_file_blocked"],
  ["holds_cancelled_transfer", "transfer_file_holds_cancelled"],
  // review round 4 (G4): a transfer of the file left the account already (a predecessor's debit)
  ["holds_debited_transfer", "transfer_file_holds_debited"],
  ["nothing_to_file", "transfer_nothing_to_file"],
  ["cash_not_covered", "transfer_cash_not_covered"],
  ["no_closing_balance", "transfer_no_closing_balance"],
  ["not_a_paying_account", "transfer_not_paying_account"],
  ["already_downloaded", "transfer_already_downloaded"],
  ["hash_mismatch", "transfer_hash_mismatch"],
  ["not_ready", "transfer_not_ready"],
  ["not_downloaded", "transfer_not_downloaded"],
  ["attestation_required", "transfer_attestation_required"],
  ["debit_seen", "transfer_debit_seen"],
  ["statement_not_imported", "transfer_statement_not_imported"],
  ["version_changed", "transfer_version_changed"],
  ["already_sent", "transfer_already_sent"],
  ["four_eyes", "payee_check_four_eyes"],
  ["already_cleared", "payee_check_cleared"],
  ["unknown_pain_version", "transfer_pain_version"],
  ["a reason is required", "reason_required"],
  ["a note is required", "reason_required"],
  ["allocation_busy", "run_busy"],
  ["lock timeout", "run_busy"],
  ["could not obtain lock", "run_busy"],
];

/** Code for an error raised by a transfer-file command (never the database's text on the page). */
export function transferErrorCode(message: string): ErrorCode {
  for (const [needle, code] of COMMAND_ERRORS) if (message.includes(needle)) return code;
  return "unknown";
}

/** The payee check's own refusals: whoever recorded it, proposed or confirmed the flagged IBAN may not clear it (T5). */
export function payeeCheckErrorCode(message: string): ErrorCode {
  if (message.includes("same_person") || message.includes("four_eyes")) return "payee_check_four_eyes";
  return transferErrorCode(message);
}

/** Whether the viewer may clear a payee check (the database decides; the page only hides what it would refuse). */
export function payeeCheckClearable(c: Pick<PayeeCheck, "recorded_by_me" | "can_clear">): boolean {
  return !c.recorded_by_me && c.can_clear !== false;
}

// ------------------------------------------------------------------------------------------------------------------
// M2c-6a review (T1; money#1, security#1, money#2, pain001#1): a downloaded or sent file — or one transfer of it — is
// cancelled only with the statement's evidence and by two people: one asks (request_…), another confirms (confirm_…),
// both admins or ops managers at aal2. Until then nothing goes back « à mettre dans un fichier ».
// ------------------------------------------------------------------------------------------------------------------

/** A cancellation asked by one person, waiting for another's confirmation. */
export type CancelRequest = {
  requested_at: string;
  requested_by: string | null;
  requested_by_me: boolean;
  reason: string;
  attestation: string | null;
};

/**
 * What the paying account's imported statements show (T1's evidence): they must cover the requested execution date
 * and the account's next business day (`needed_to_date`), with no debit carrying one of the file's (or the
 * transfer's) end-to-end ids or PmtInfIds — or a debit and its return showing the bank rejected it.
 */
export type CancelEvidence = {
  statement_to_date: string | null;
  needed_to_date: string | null;
  covered: boolean;
  debit_seen: boolean;
  returned: boolean;
  /** review round 2 (D1): the window's last day is over (before today); the first day the cancellation can be asked */
  window_over: boolean | null;
  available_from: string | null;
  /** review round 2 (D3): a batch debit other transfers of the PmtInf could make up */
  batch_ambiguous: boolean;
  /** review round 2 (D2): for one transfer, whether the bank executed something of its file (null: not decided) */
  file_executed: boolean | null;
  /** the database's verdict, when it gives one */
  refusal: string | null;
};

export type Cancellation = { request: CancelRequest | null; evidence: CancelEvidence | null };

function isRecord(x: unknown): x is Record<string, unknown> {
  return typeof x === "object" && x !== null && !Array.isArray(x);
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function dateOrNull(x: unknown): string | null {
  return typeof x === "string" && ISO_DATE.test(x.slice(0, 10)) ? x.slice(0, 10) : null;
}

/**
 * The `cancellation` the file's (or the item's) read gives: `{request: {...} | null, evidence: {...} | null}`.
 * Anything missing or malformed reads as « not known »: the page then says what the command checks, and the command
 * decides (the evidence and the second person are enforced by the database, never by the page).
 */
export function cancellationOf(x: unknown): Cancellation {
  const c = isRecord(x) ? x : {};
  const r = isRecord(c.request) ? c.request : null;
  const e = isRecord(c.evidence) ? c.evidence : null;
  const request: CancelRequest | null =
    r && typeof r.requested_at === "string"
      ? {
          requested_at: r.requested_at,
          requested_by: typeof r.requested_by === "string" ? r.requested_by : null,
          requested_by_me: r.requested_by_me === true,
          reason: typeof r.reason === "string" ? r.reason : "",
          attestation: typeof r.attestation === "string" ? r.attestation : null,
        }
      : null;
  const evidence: CancelEvidence | null = e
    ? {
        statement_to_date: dateOrNull(e.statement_to_date),
        needed_to_date: dateOrNull(e.needed_to_date),
        covered: e.covered === true,
        debit_seen: e.debit_seen === true,
        returned: e.returned === true,
        window_over: typeof e.window_over === "boolean" ? e.window_over : null,
        available_from: dateOrNull(e.available_from),
        batch_ambiguous: e.batch_ambiguous === true,
        file_executed: typeof e.file_executed === "boolean" ? e.file_executed : null,
        refusal: typeof e.refusal === "string" ? e.refusal : null,
      }
    : null;
  return { request, evidence };
}

/** Which sheet the page offers: ask, confirm another's request, or wait for another person to confirm mine. */
export function cancellationStep(c: Cancellation): "request" | "confirm" | "wait" {
  if (!c.request) return "request";
  return c.request.requested_by_me ? "wait" : "confirm";
}

/**
 * The evidence as the sheets state it. `ready`: true when the statements allow the cancellation, false when they
 * refuse it, null when the page does not know (the command checks it).
 */
export function evidenceStatus(e: CancelEvidence | null, what: "file" | "transfer"): { ready: boolean | null; text: string } {
  const of = what === "file" ? "de ce fichier" : "de ce virement";
  if (!e)
    return {
      ready: null,
      text: `La commande vérifie les relevés : ceux du compte doivent être importés jusqu'au jour ouvré qui suit la date d'exécution demandée, sans aucun débit ${of} (ou avec son rejet par la banque).`,
    };
  if (e.returned)
    return { ready: true, text: `Un relevé montre le rejet ou le retour ${of} par la banque : l'annulation peut être demandée.` };
  if (e.debit_seen)
    return {
      ready: false,
      text: `Un relevé montre un débit ${of} : la banque l'a exécuté, il ne peut pas être annulé (risque de double paiement).`,
    };
  // review round 2 (D3): the bank debited the lot as one line, which other transfers of it could make up
  if (e.batch_ambiguous || e.refusal === "batch_ambiguous")
    return {
      ready: false,
      text: "La banque a débité ce lot en une seule ligne, sans le détail des virements, et d'autres virements du lot font le même montant que celui-ci : rien ne prouve lequel n'a pas été payé. Demandez à la banque le détail du lot.",
    };
  // review round 2 (D1): the days must be over before any statement proves them
  if (e.window_over === false)
    return {
      ready: false,
      text: `La banque peut encore exécuter ${what === "file" ? "ce fichier" : "ce virement"} jusqu'à la fin du ${e.needed_to_date ? frenchDate(e.needed_to_date) : "jour ouvré qui suit l'exécution demandée"} : l'annulation se demande${e.available_from ? ` à partir du ${frenchDate(e.available_from)}` : " ensuite"}, avec le relevé de ces journées importé après leur fin.`,
    };
  if (!e.covered)
    return {
      ready: false,
      text: `Importez d'abord le relevé du compte jusqu'au ${e.needed_to_date ? frenchDate(e.needed_to_date) : "jour ouvré qui suit l'exécution demandée"}, établi après la fin de cette journée (dernier relevé importé : ${e.statement_to_date ? `jusqu'au ${frenchDate(e.statement_to_date)}` : "aucun"} ; un relevé importé le jour même, ou le dernier jour d'un CSV, ne compte pas) : il doit montrer qu'aucun débit ${of} n'a eu lieu.`,
    };
  // review round 2 (D2): one transfer only out of a file the bank executed in part
  if (what === "transfer" && (e.file_executed === false || e.refusal === "file_not_executed"))
    return {
      ready: false,
      text: "Les relevés ne montrent aucun débit ni retour de ce fichier : la banque n'en a rien exécuté. N'annulez pas ce virement seul — demandez l'annulation du fichier entier.",
    };
  const until = e.statement_to_date ?? e.needed_to_date;
  return {
    ready: true,
    text: `Relevés importés${until ? ` jusqu'au ${frenchDate(until)}` : ""} : aucun débit ${of} — la banque ne l'a pas exécuté.`,
  };
}

/** « Annulation demandée par Léa le 12/11/2026 à 09:41 : motif » (who asked, so the confirmer knows it is not them). */
export function requestLine(r: CancelRequest): string {
  const attest = r.attestation ? ` (${ATTESTATION_LABEL[r.attestation] ?? r.attestation})` : "";
  return `Annulation demandée par ${r.requested_by ?? "un utilisateur"} le ${parisDateTime(r.requested_at)} : ${r.reason}${attest}`;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * The four commands of T1, called through the narrow `CancellationRpc` (one call site for four functions); their
 * arguments are checked against the generated `database.types.ts` by `CancellationArgsMatchDb` below.
 */
export type CancellationCall =
  | {
      fn: "request_transfer_file_cancellation";
      args: { p_idempotency_key: string; p_file_id: string; p_expected_version: number; p_reason: string; p_attestation: string };
    }
  | { fn: "confirm_transfer_file_cancellation"; args: { p_idempotency_key: string; p_file_id: string; p_expected_version: number } }
  | { fn: "request_transfer_cancellation"; args: { p_idempotency_key: string; p_transfer_id: string; p_reason: string } }
  | { fn: "confirm_transfer_cancellation"; args: { p_idempotency_key: string; p_transfer_id: string } };

/**
 * The call a cancellation sheet's fields make, or why it is refused before the database is asked. A file's request
 * carries the attestation (not uploaded / rejected whole by the bank: the database sets `superseded` or `rejected`); a
 * transfer's carries only its reason (the bank refused that one transfer: the statement shows no debit of it, or its
 * return). The confirmation names only the target (and the file's version): the request it confirms is the one stored.
 */
export function cancellationCall(
  step: "request" | "confirm",
  target: "file" | "transfer",
  get: (name: string) => string,
): CancellationCall | { error: ErrorCode } {
  const key = get("idempotency_key");
  if (!UUID.test(key)) return { error: "unknown" };
  if (target === "file") {
    const file = get("file_id");
    const v = get("expected_version");
    if (!UUID.test(file) || !/^\d+$/.test(v)) return { error: "unknown" };
    if (step === "confirm")
      return { fn: "confirm_transfer_file_cancellation", args: { p_idempotency_key: key, p_file_id: file, p_expected_version: Number(v) } };
    const attestation = get("attestation");
    if (attestation !== "not_uploaded" && attestation !== "rejected_by_bank") return { error: "transfer_attestation_required" };
    const reason = get("reason");
    if (!reason) return { error: "reason_required" };
    return {
      fn: "request_transfer_file_cancellation",
      args: { p_idempotency_key: key, p_file_id: file, p_expected_version: Number(v), p_reason: reason, p_attestation: attestation },
    };
  }
  const transfer = get("transfer_id");
  if (!UUID.test(transfer)) return { error: "unknown" };
  if (step === "confirm") return { fn: "confirm_transfer_cancellation", args: { p_idempotency_key: key, p_transfer_id: transfer } };
  const reason = get("reason");
  if (!reason) return { error: "reason_required" };
  return { fn: "request_transfer_cancellation", args: { p_idempotency_key: key, p_transfer_id: transfer, p_reason: reason } };
}

export type CancellationRpc = (
  fn: CancellationCall["fn"],
  args: CancellationCall["args"],
) => PromiseLike<{ data: unknown; error: { message: string } | null }>;

/** The four commands from a Supabase client (as a method, so the client keeps its `this`). */
export function cancellationRpc(client: unknown): CancellationRpc {
  return (fn, args) => (client as { rpc: CancellationRpc }).rpc(fn, args);
}

type DbFunctions = Database["public"]["Functions"];
type ExactArgs<C> = C extends { fn: infer F extends keyof DbFunctions; args: infer A }
  ? [A] extends [DbFunctions[F]["Args"]]
    ? [DbFunctions[F]["Args"]] extends [A]
      ? true
      : false
    : false
  : false;
type IsTrue<T extends true> = T;
/** Type-checks only: each `CancellationCall`'s arguments are exactly the database's signature (tsc fails on a drift). */
export type CancellationArgsMatchDb = IsTrue<false extends ExactArgs<CancellationCall> ? false : true>;

/**
 * How cancelling a run reaches its payout (T1, money#2): `direct` — nothing left the bank (no transfer, still to file,
 * in a file not downloaded, or already cancelled under T1); `transfer_first` — the transfer is in a downloaded or sent
 * file: it is cancelled first (request, then another person's confirmation, with the statement), and only then the run
 * (`payout_in_downloaded_file` until then); `none` — its debit is booked or it came back.
 */
export function runCancelPath(
  transfer: { status: string } | null,
  file: { status: string; download_count: number } | null,
): "direct" | "transfer_first" | "none" {
  if (!transfer || transfer.status === "ordered" || transfer.status === "cancelled") return "direct";
  if (transfer.status !== "in_file") return "none";
  if (!file) return "direct";
  return file.download_count > 0 || file.status === "downloaded" || file.status === "sent" ? "transfer_first" : "direct";
}

// ------------------------------------------------------------------------------------------------------------------
// M2c-6a review (T2, tests-ui#9): the download. The route asks the command first (it re-runs the generation's checks
// under the same locks, records the download, replaces a stale or blocked file), and a refusal sends the browser back to
// the file's page with what happened — never a bare text page.
// ------------------------------------------------------------------------------------------------------------------

export type DownloadRefusal =
  | "already_downloaded"
  | "file_stale"
  | "file_blocked"
  | "not_ready"
  | "not_downloadable"
  | "holds_cancelled_transfer"
  | "holds_debited_transfer"
  | "hash_mismatch"
  | "unavailable"
  | "unknown";

/** A transfer held out at download with its reason, or (no transfer id) the file's own: the cash check. */
export type BlockedTransfer = { transfer_id: string | null; reason: string };

export type DownloadOutcome =
  | { kind: "ok"; storagePath: string | null }
  | { kind: "refused"; code: DownloadRefusal; blocked: BlockedTransfer[] };

const REASON = /^[a-z0-9_:]{1,80}$/;
const MAX_BLOCKED = 20;

const REFUSALS: readonly DownloadRefusal[] = [
  "already_downloaded",
  "file_stale",
  "file_blocked",
  "not_ready",
  "not_downloadable",
  "holds_cancelled_transfer",
  "holds_debited_transfer",
  "hash_mismatch",
  "unavailable",
  "unknown",
];

/** The transfers the command held out, and the file's own reasons (the cash check: no transfer id). */
function blockedList(x: unknown): BlockedTransfer[] {
  const out: BlockedTransfer[] = [];
  for (const b of Array.isArray(x) ? x : []) {
    if (!isRecord(b)) continue;
    const reason = typeof b.reason === "string" && REASON.test(b.reason) ? b.reason : null;
    if (!reason) continue;
    if (b.transfer_id === null || b.transfer_id === undefined) out.push({ transfer_id: null, reason });
    else if (typeof b.transfer_id === "string" && UUID.test(b.transfer_id)) out.push({ transfer_id: b.transfer_id, reason });
  }
  return out;
}

function refusalCode(text: string): DownloadRefusal {
  return REFUSALS.find((c) => c !== "unknown" && c !== "unavailable" && text.includes(c)) ?? "unknown";
}

/**
 * The command's answer: the bytes may be served (with the file's storage path, read with the caller's session), or a
 * refusal with its code and, for `file_blocked`, the transfers and their reasons. A refusal that replaced the file comes
 * back as data (`{refused, blocked}`: a raise would undo the replacement); one that changed nothing as an error (its
 * detail may carry `{blocked}` too).
 */
export function downloadOutcome(data: unknown, error: { message: string; details?: string | null } | null): DownloadOutcome {
  if (error) {
    let detail: unknown = null;
    try {
      detail = error.details ? JSON.parse(error.details) : null;
    } catch {
      detail = null;
    }
    return { kind: "refused", code: refusalCode(error.message), blocked: blockedList(isRecord(detail) ? detail.blocked : null) };
  }
  const d = isRecord(data) ? data : {};
  if (typeof d.refused === "string") return { kind: "refused", code: refusalCode(d.refused), blocked: blockedList(d.blocked) };
  return { kind: "ok", storagePath: typeof d.storage_path === "string" ? d.storage_path : null };
}

/** The file's page the browser is sent back to after a refusal (the blocked transfers in the query, at most 20). */
export function refusalUrl(fileId: string, code: DownloadRefusal, blocked: BlockedTransfer[]): string {
  const q = new URLSearchParams({ refus: code });
  for (const b of blocked.slice(0, MAX_BLOCKED)) q.append("b", `${b.transfer_id ?? ""}:${b.reason}`);
  return `/backoffice/reversements/virements/${fileId}?${q.toString()}`;
}

/** The refusal the file's page was sent back with (anything else in the query is ignored). */
export function refusalFromSearch(
  params: Record<string, string | string[] | undefined>,
): { code: DownloadRefusal; blocked: BlockedTransfer[] } | null {
  const raw = Array.isArray(params.refus) ? params.refus[0] : params.refus;
  const code = REFUSALS.find((c) => c === raw);
  if (!code) return null;
  const entries = params.b === undefined ? [] : Array.isArray(params.b) ? params.b : [params.b];
  const blocked: BlockedTransfer[] = [];
  for (const entry of entries.slice(0, MAX_BLOCKED)) {
    const at = entry.indexOf(":");
    const id = entry.slice(0, at);
    const reason = entry.slice(at + 1);
    if (at < 0 || !REASON.test(reason)) continue;
    if (at === 0) blocked.push({ transfer_id: null, reason });
    else if (UUID.test(id)) blocked.push({ transfer_id: id, reason });
  }
  return { code, blocked };
}

/** What the file's page says after a refused download (`already_downloaded` also opens the warning sheet). */
export function refusalText(code: DownloadRefusal): string {
  switch (code) {
    case "already_downloaded":
      return "Ce fichier a déjà été téléchargé : confirmez l'avertissement pour le télécharger de nouveau, et ne le déposez pas deux fois.";
    case "file_stale":
      return "Date d'exécution dépassée : le fichier n'a pas été servi et il est remplacé. Régénérez-le (nouveau numéro, exécution au plus tôt le prochain jour ouvré du compte).";
    case "file_blocked":
      return "Des virements de ce fichier ne passent plus les contrôles depuis sa génération : le fichier n'a pas été servi et il est remplacé. Régénérez-le ; ces virements restent hors du fichier tant que leur motif demeure.";
    case "not_ready":
      return "Le fichier est en cours d'écriture : réessayez dans quelques secondes.";
    case "not_downloadable":
      return "Ce fichier ne peut plus être téléchargé (remplacé, rejeté ou en échec) : utilisez le fichier en cours sur « Virements ».";
    case "holds_cancelled_transfer":
      return "Un virement de ce fichier a été annulé depuis son téléchargement : le fichier n'est plus servi et ne doit plus être déposé.";
    // review round 4 (G4)
    case "holds_debited_transfer":
      return "Un virement de ce fichier a déjà été débité sous la référence du virement qu'il remplace (un fichier annulé exécuté plus tard malgré tout) : le fichier n'est plus servi, ne le déposez pas. Prévenez le support.";
    case "hash_mismatch":
      return "Le fichier stocké ne correspond pas au fichier généré : il n'a pas été servi (le téléchargement est enregistré). Ne déposez rien et prévenez le support.";
    case "unavailable":
      return "Le fichier est momentanément indisponible : il n'a pas été servi, mais le téléchargement est enregistré. Réessayez dans un instant avec « Télécharger de nouveau ».";
    default:
      return "Le téléchargement a échoué. Rechargez la page et réessayez ; si le problème persiste, contactez le support.";
  }
}
