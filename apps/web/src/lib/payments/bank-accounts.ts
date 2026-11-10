import type { ErrorCode } from "@/lib/boarding/forms";

/** Code for an error raised by register_bank_account / close_bank_account (most specific first). */
export function bankAccountErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("invalid IBAN")) return "iban_invalid";
  if (message.includes("invalid BIC")) return "bic_invalid";
  if (message.includes("already registered")) return "iban_taken";
  if (message.includes("already active in this currency")) return "client_funds_exists";
  if (message.includes("transfers from or to this bank account are in flight")) return "transfers_in_flight";
  if (message.includes("top-up: from an active own account")) return "top_up_accounts";
  if (message.includes("no longer pending")) return "top_up_not_pending";
  if (message.includes("execution date is in the past")) return "date_past";
  if (message.includes("invalid amount")) return "amount_invalid";
  if (message.includes("a label is required")) return "label_required";
  if (message.includes("opening date cannot be in the future")) return "opened_future";
  if (message.includes("still holds client money")) return "account_holds_money";
  if (message.includes("already closed")) return "already_closed";
  if (message.includes("reason is required")) return "reason_required";
  return "unknown";
}

/** What a bank account is for (bank_account.purpose; M2c: the servicer's own account). */
export const PURPOSE_LABEL: Record<string, string> = {
  client_funds: "Fonds de tiers",
  own: "Compte propre du cabinet",
};

/** Status of a top-up ordered from the own account (bank_transfer.status). */
export const TOP_UP_STATUS: Record<string, string> = {
  ordered: "À exécuter depuis le compte propre",
  in_file: "Dans un fichier de virements",
  booked: "Crédité sur le compte dédié",
  returned: "Revenu",
  cancelled: "Annulé",
};

export const FEED_LABEL: Record<string, string> = {
  camt053: "CAMT.053 (XML)",
  csv: "CSV (export bancaire)",
};

/** A business date (yyyy-mm-dd) as dd/mm/yyyy, without going through a time zone. */
export function frenchDate(isoDate: string | null): string {
  if (!isoDate) return "";
  const [y, m, d] = isoDate.split("-");
  return `${d}/${m}/${y}`;
}
