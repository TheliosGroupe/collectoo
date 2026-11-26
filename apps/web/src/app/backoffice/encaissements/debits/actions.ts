"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import type { Json } from "@/lib/database.types";
import { debitErrorCode, guardRefusalCode, linkDebitErrorCode } from "@/lib/payments/debits";
import { type TopUpCreditOption, parseTopUpCreditOptions, topUpErrorCode } from "@/lib/remittance/top-ups";
import {
  parseTransferLineOptions,
  parseTransferLinePreview,
  transferLineErrorCode,
  type TransferLineOptions,
  type TransferLinePreview,
} from "@/lib/payments/transfer-lines";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const AMOUNT = /^\d{1,16}$/;
const KINDS = new Set(["return", "refund", "refund_returned", "explained", "fee", "own_credit", "loss"]);

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

function done(
  error: { message: string } | null,
  paymentId?: string,
  linkKind?: string,
  offersBooking = true,
): ActionResult {
  if (error) {
    console.error("debit command failed", { error: error.message });
    // link_debit's refusals by the kind asked for (review M2c-6b-1 round 3: a top-up refused on our credit); review
    // 6b-2c round 3: payout_candidate in words true of a line « Comptabiliser… » does not offer
    return {
      error: linkKind
        ? guardRefusalCode(linkDebitErrorCode(error.message, linkKind), offersBooking)
        : debitErrorCode(error.message),
    };
  }
  revalidatePath("/backoffice/encaissements/debits");
  if (paymentId) revalidatePath(`/backoffice/encaissements/paiements/${paymentId}`);
  return { ok: true };
}

/** « Lier »: a bank line to the payment it takes back (what is left of it as the page showed it), to our refund, to a
 * refund that came back, or « expliqué » (not booked); since M2c-1 booked in the funds: a bank fee, a top-up from the
 * own account, a return larger than its payment (the servicer's loss, OQ-34). Authorization and every check are in
 * SQL. */
export async function linkDebit(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const line = field(formData, "bank_transaction_id");
  const kind = field(formData, "kind");
  const payment = field(formData, "payment_id");
  const refund = field(formData, "refund_request_id");
  const expected = field(formData, "expected_left_minor");
  if (!UUID.test(key) || !UUID.test(line) || !KINDS.has(kind)) return { error: "unknown" };
  const onPayment = kind === "return" || kind === "loss";
  if (onPayment && (!UUID.test(payment) || !AMOUNT.test(expected))) return { error: "unknown" };
  if ((kind === "refund" || kind === "refund_returned") && !UUID.test(refund)) return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("link_debit", {
    p_idempotency_key: key,
    p_bank_transaction_id: line,
    p_kind: kind,
    p_payment_id: (onPayment ? payment : null) as string,
    p_refund_request_id: (kind === "refund" || kind === "refund_returned" ? refund : null) as string,
    p_expected_left_minor: (onPayment ? expected : null) as string,
    p_reason: reason,
  });
  return done(error, onPayment ? payment : undefined, kind, field(formData, "line_books") !== "0");
}

/** « Paiement d'un débiteur relayé par le cabinet »: an unbooked credit from the own account becomes a debtor's
 * payment (on no file: « Paiements à traiter »), with ops' motif. Authorization (admin or ops manager at aal2) and every
 * check are in SQL. */
export async function releaseOwnCredit(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const line = field(formData, "bank_transaction_id");
  if (!UUID.test(key) || !UUID.test(line)) return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("release_own_credit", {
    p_idempotency_key: key,
    p_bank_transaction_id: line,
    p_reason: reason,
  });
  if (!error) revalidatePath("/backoffice/encaissements/a-traiter");
  return done(error);
}

/** « Libérer » / « Doublon confirmé »: a CSV line held as a suspected duplicate. */
export async function resolveDuplicate(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const line = field(formData, "bank_transaction_id");
  const decision = field(formData, "decision");
  if (!UUID.test(key) || !UUID.test(line) || (decision !== "duplicate" && decision !== "release")) return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("resolve_duplicate", {
    p_idempotency_key: key,
    p_bank_transaction_id: line,
    p_is_duplicate: decision === "duplicate",
    p_reason: reason,
  });
  return done(error);
}

/** « Lancer les contrôles » now (the nightly job, for this servicer). */
export async function requestChecks(formData: FormData): Promise<ActionResult> {
  const org = field(formData, "organization_id");
  if (!UUID.test(org)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("request_payment_checks", { p_organization_id: org });
  if (error) return { error: debitErrorCode(error.message) };
  revalidatePath("/backoffice/encaissements/controles");
  return { ok: true };
}

// ---------------------------------------------------------------------------------------------------------------------
// M2c-6b-2c (plan §3.11, §7.3; critic CSO-4): « Comptabiliser… » — the options are read when a line's sheet opens (one
// keyed read, never while the list renders), the preview again before an unsplit entry is booked, then the command.
// Every check is in SQL (public.transfer_line_options / transfer_line_preview / book_transfer_line); the page sends back
// the parts as the database proposed them and the preview's text, so a change between the two refuses (split_changed).
// ---------------------------------------------------------------------------------------------------------------------

/** What « Comptabiliser… » returns: done, or a refusal's code (and the run it names) for transferLineRefusalText. */
export type TransferLineActionResult = { ok: true } | { refusal: string; detail: string | null };

/** The options of a line, read when its sheet opens: null when it cannot be read (not allowed, not one of ours). */
export async function transferLineOptions(lineId: string): Promise<TransferLineOptions | null> {
  if (!UUID.test(lineId)) return null;
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("transfer_line_options", { p_bank_transaction_id: lineId });
  if (error) {
    console.error("transfer line options failed", { error: error.message });
    return null;
  }
  return parseTransferLineOptions(data);
}

/** « Vérifier »: the preview of these parts as the line stands now (an unsplit entry's stored details). */
export async function previewTransferLine(
  lineId: string,
  parts: unknown,
): Promise<{ preview: TransferLinePreview } | { refusal: string; detail: string | null }> {
  if (!UUID.test(lineId) || !Array.isArray(parts)) return { refusal: "bad_request", detail: null };
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("transfer_line_preview", {
    p_bank_transaction_id: lineId,
    p_parts: parts as Json,
  });
  if (error) return { refusal: transferLineErrorCode(error), detail: error.details || null };
  const preview = parseTransferLinePreview(data);
  return preview ? { preview } : { refusal: "unknown", detail: null };
}

/** « Comptabiliser … »: the parts the database proposed, the preview's text the sheet showed, ops' motif. */
export async function bookTransferLine(formData: FormData): Promise<TransferLineActionResult> {
  const key = field(formData, "idempotency_key");
  const line = field(formData, "bank_transaction_id");
  const expected = String(formData.get("expected_text") ?? "");
  let parts: unknown;
  try {
    parts = JSON.parse(String(formData.get("parts") ?? ""));
  } catch {
    parts = null;
  }
  if (!UUID.test(key) || !UUID.test(line) || !Array.isArray(parts) || expected === "")
    return { refusal: "bad_request", detail: null };
  const reason = field(formData, "reason");
  if (!reason) return { refusal: "reason_required", detail: null };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("book_transfer_line", {
    p_idempotency_key: key,
    p_bank_transaction_id: line,
    p_parts: parts as Json,
    p_expected_text: expected,
    p_reason: reason,
  });
  if (error) {
    console.error("transfer line booking failed", { error: error.message });
    return { refusal: transferLineErrorCode(error), detail: error.details || null };
  }
  revalidatePath("/backoffice/encaissements/debits");
  revalidatePath("/backoffice/reversements", "layout");
  return { ok: true };
}

/** « Rattacher à TOP… »: the open top-ups of the credit's amount, read when its sheet opens (public.top_up_credit_options). */
export async function topUpCreditOptions(lineId: string): Promise<TopUpCreditOption[] | null> {
  if (!UUID.test(lineId)) return null;
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("top_up_credit_options", { p_bank_transaction_id: lineId });
  if (error) {
    console.error("top-up credit options failed", { error: error.message });
    return null;
  }
  return parseTopUpCreditOptions(data);
}

/** M2c-7e-1 ([check 1] gap 12) « Rattacher à TOP… »: an own credit that carries no TOP id booked as an open top-up of its
 * amount (public.book_top_up_credit: the refusals and the re-check are in SQL). */
export async function bookTopUpCredit(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const line = field(formData, "bank_transaction_id");
  const transfer = field(formData, "transfer_id");
  const reason = field(formData, "reason");
  if (!UUID.test(key) || !UUID.test(line) || !UUID.test(transfer)) return { error: "unknown" };
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("book_top_up_credit", {
    p_idempotency_key: key,
    p_bank_transaction_id: line,
    p_transfer_id: transfer,
    p_reason: reason,
  });
  if (error) {
    console.error("top-up credit refused", { error: error.message });
    return { error: topUpErrorCode(error.message) };
  }
  revalidatePath("/backoffice/encaissements/debits");
  revalidatePath("/backoffice/reversements/virements");
  return { ok: true };
}
