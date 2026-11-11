import type { ErrorCode } from "@/lib/boarding/forms";
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
};

export type TransferOverview = {
  today: string;
  accounts: PayingAccount[];
  own_account: { id: string; label: string; iban_last4: string } | null;
  payee_checks: PayeeCheck[];
  can_admin: boolean;
};

export type FileItem = TransferCard & { seq: number; pmt_inf_id: string; late: boolean; debit_seen: boolean };

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
};

/** Why a transfer is held out of a file generated today (null: it goes in). */
export function holdLabel(code: string | null): string | null {
  if (code === null) return null;
  if (code.startsWith("payout_blocked:")) return `Virement bloqué — ${payoutBlockerLabel(code.slice("payout_blocked:".length))}`;
  return HOLD_LABEL[code] ?? code;
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
  out.push(
    n === 0
      ? "Aucun reversement ni remboursement à mettre dans le fichier."
      : `${n} virement${n > 1 ? "s" : ""} depuis ${a.label} (…${a.iban_last4}) : ${money(a.eligible_total_minor, a.currency)}, exécution demandée au plus tôt le ${frenchDate(a.earliest_execution_date)}.`,
  );
  if (a.sweep_preview_minor !== "0") {
    out.push(
      ownAccount
        ? `La quote-part du cabinet réglée sur le compte dédié, ${money(a.sweep_preview_minor, a.currency)}, part dans le même fichier vers le compte propre (…${ownAccount.iban_last4}) — après les clients si le solde ne couvre pas tout.`
        : "La quote-part du cabinet reste sur le compte dédié : aucun compte propre n'est renseigné dans « Facturation ».",
    );
  }
  const held = a.to_file_count - a.eligible_count;
  if (held > 0) out.push(`${held} virement${held > 1 ? "s restent" : " reste"} hors du fichier (motif affiché).`);
  if (a.late_count > 0) out.push(`${a.late_count} virement${a.late_count > 1 ? "s" : ""} après la date limite : le motif du retard est enregistré sur le fichier.`);
  out.push(
    `Format ${a.pain_version}. Un fichier non encore téléchargé est remplacé par le nouveau (nouveau numéro). Rien n'est comptabilisé avant le débit sur le relevé.`,
  );
  return out;
}

export const PAIN_VERSIONS = ["pain.001.001.09", "pain.001.001.03"] as const;

export const ATTESTATION_LABEL: Record<string, string> = {
  not_uploaded: "Le fichier n'a pas été déposé à la banque",
  rejected_by_bank: "La banque a rejeté le fichier en entier",
};

const COMMAND_ERRORS: [string, ErrorCode][] = [
  ["not allowed", "not_allowed"],
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
