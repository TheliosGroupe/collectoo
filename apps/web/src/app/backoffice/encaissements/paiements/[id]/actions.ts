"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import { allocationErrorCode } from "@/lib/payments/allocation";

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
