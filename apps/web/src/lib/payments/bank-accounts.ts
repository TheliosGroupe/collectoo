import type { ErrorCode } from "@/lib/boarding/forms";

/** Code for an error raised by register_bank_account / close_bank_account (most specific first). */
export function bankAccountErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("invalid IBAN")) return "iban_invalid";
  if (message.includes("invalid BIC")) return "bic_invalid";
  if (message.includes("already registered")) return "iban_taken";
  if (message.includes("a label is required")) return "label_required";
  if (message.includes("opening date cannot be in the future")) return "opened_future";
  if (message.includes("still holds client money")) return "account_holds_money";
  if (message.includes("already closed")) return "already_closed";
  if (message.includes("reason is required")) return "reason_required";
  return "unknown";
}

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
