"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import { type ActionResult, parseEurosToMinor } from "@/lib/boarding/forms";
import { allocationErrorCode } from "@/lib/payments/allocation";
import { debitErrorCode, normaliseIban } from "@/lib/payments/debits";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const AMOUNT = /^\d{1,16}$/;

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

function optionalUuid(formData: FormData, name: string): string | null | undefined {
  const v = field(formData, name);
  if (v === "") return null;
  return UUID.test(v) ? v : undefined;
}

/** Authorization (admin or ops manager at aal2), compare and set and every check are in the SQL commands. */
function done(paymentId: string, error: { message: string } | null): ActionResult {
  if (error) {
    console.error("allocation command failed", { error: error.message });
    return { error: allocationErrorCode(error.message) };
  }
  revalidatePath(`/backoffice/encaissements/paiements/${paymentId}`);
  revalidatePath("/backoffice/encaissements/a-traiter");
  return { ok: true };
}

/** « Désimputer »: the allocation entries the page showed, on one file, reversed at their date. */
export async function reverseAllocation(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const payment = field(formData, "payment_id");
  const account = field(formData, "account_id");
  const entries = formData.getAll("entry_id").map(String);
  if (!UUID.test(key) || !UUID.test(payment) || !UUID.test(account) || entries.length === 0) return { error: "unknown" };
  if (!entries.every((e) => UUID.test(e))) return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("reverse_allocation", {
    p_idempotency_key: key,
    p_payment_id: payment,
    p_account_id: account,
    p_entry_ids: entries,
    p_reason: reason,
  });
  return done(payment, error);
}

/** « Imputer »: send the payment to allocation again (from the reason the page showed), or use what is left
 * of it for another file of the same debtor on his written request (founder #8). */
export async function allocatePayment(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const payment = field(formData, "payment_id");
  const expected = field(formData, "expected_reason");
  const account = optionalUuid(formData, "account_id");
  const evidence = optionalUuid(formData, "evidence_document_id");
  if (!UUID.test(key) || !UUID.test(payment) || !expected || account === undefined || evidence === undefined)
    return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  if (account !== null && evidence === null) return { error: "request_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("allocate_payment", {
    p_idempotency_key: key,
    p_payment_id: payment,
    p_expected_reason: expected,
    p_account_id: account as string,
    p_evidence_document_id: evidence as string,
    p_reason: reason,
  });
  return done(payment, error);
}

/** « Lever le blocage »: allocate a held payment with the judge's authorisation (founder #12). */
export async function releaseHold(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const payment = field(formData, "payment_id");
  const evidence = optionalUuid(formData, "evidence_document_id");
  if (!UUID.test(key) || !UUID.test(payment) || evidence === undefined) return { error: "unknown" };
  if (evidence === null) return { error: "authorisation_required" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("release_hold_payment", {
    p_idempotency_key: key,
    p_payment_id: payment,
    p_evidence_document_id: evidence,
    p_reason: reason,
  });
  return done(payment, error);
}

/** « Reverser au client »: what is left of the payment, the amount the page showed (compare and set). */
export async function forwardPayment(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const payment = field(formData, "payment_id");
  const expected = field(formData, "expected_minor");
  const evidence = optionalUuid(formData, "evidence_document_id");
  if (!UUID.test(key) || !UUID.test(payment) || !AMOUNT.test(expected) || evidence === undefined)
    return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("forward_payment", {
    p_idempotency_key: key,
    p_payment_id: payment,
    p_client_organization_id: null as unknown as string,
    p_expected_minor: expected,
    p_evidence_document_id: evidence as string,
    p_reason: reason,
  });
  return done(payment, error);
}

/** Take a payment off its file (nothing allocated): back to the queue. */
export async function unassignFromPage(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const payment = field(formData, "payment_id");
  if (!UUID.test(key) || !UUID.test(payment)) return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("unassign_payment", {
    p_idempotency_key: key,
    p_payment_id: payment,
    p_reason: reason,
  });
  return done(payment, error);
}

/** M2b-6 commands: errors as codes (raw database text never reaches the page). */
function debitDone(paymentId: string, error: { message: string } | null): ActionResult {
  if (error) {
    console.error("refund command failed", { error: error.message });
    return { error: debitErrorCode(error.message) };
  }
  revalidatePath(`/backoffice/encaissements/paiements/${paymentId}`);
  revalidatePath("/backoffice/encaissements/a-traiter");
  return { ok: true };
}

/** « Rembourser » (founder #8, #9, #11, #12): what is left of the payment, to the payer's IBAN unless another one is
 * given; the state the page showed (reason, what is left) is checked again in SQL. Nothing is booked now. */
export async function requestRefund(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const payment = field(formData, "payment_id");
  const expectedLeft = field(formData, "expected_left_minor");
  const expectedReason = field(formData, "expected_review_reason");
  const code = field(formData, "reason_code");
  if (!UUID.test(key) || !UUID.test(payment) || !AMOUNT.test(expectedLeft) || !code) return { error: "unknown" };
  const amount = parseEurosToMinor(field(formData, "amount"));
  if (amount === null || amount <= BigInt(0)) return { error: "amount_invalid" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const useOther = field(formData, "payee") === "other";
  const iban = useOther ? normaliseIban(field(formData, "payee_iban")) : null;
  if (useOther && iban === null) return { error: "refund_iban_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("request_refund", {
    p_idempotency_key: key,
    p_payment_id: payment,
    p_amount_minor: amount.toString(),
    p_payee_iban: iban as string,
    p_payee_name: (field(formData, "payee_name") || null) as string,
    p_reason_code: code,
    p_expected_review_reason: (expectedReason || null) as string,
    p_expected_left_minor: expectedLeft,
    p_reason: reason,
  });
  return debitDone(payment, error);
}

/** « Annuler le remboursement »: the transfer was not made (or the IBAN was wrong). */
export async function cancelRefund(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const payment = field(formData, "payment_id");
  const refund = field(formData, "refund_request_id");
  if (!UUID.test(key) || !UUID.test(payment) || !UUID.test(refund)) return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("cancel_refund", {
    p_idempotency_key: key,
    p_refund_request_id: refund,
    p_reason: reason,
  });
  return debitDone(payment, error);
}
