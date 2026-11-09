"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import { debitErrorCode } from "@/lib/payments/debits";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const AMOUNT = /^\d{1,16}$/;
const KINDS = new Set(["return", "refund", "refund_returned", "explained"]);

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

function done(error: { message: string } | null, paymentId?: string): ActionResult {
  if (error) {
    console.error("debit command failed", { error: error.message });
    return { error: debitErrorCode(error.message) };
  }
  revalidatePath("/backoffice/encaissements/debits");
  if (paymentId) revalidatePath(`/backoffice/encaissements/paiements/${paymentId}`);
  return { ok: true };
}

/** « Lier »: a bank line to the payment it takes back (what is left of it as the page showed it), to our refund, to a
 * refund that came back, or « expliqué » (not booked: founder #20). Authorization and every check are in SQL. */
export async function linkDebit(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const line = field(formData, "bank_transaction_id");
  const kind = field(formData, "kind");
  const payment = field(formData, "payment_id");
  const refund = field(formData, "refund_request_id");
  const expected = field(formData, "expected_left_minor");
  if (!UUID.test(key) || !UUID.test(line) || !KINDS.has(kind)) return { error: "unknown" };
  if (kind === "return" && (!UUID.test(payment) || !AMOUNT.test(expected))) return { error: "unknown" };
  if ((kind === "refund" || kind === "refund_returned") && !UUID.test(refund)) return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("link_debit", {
    p_idempotency_key: key,
    p_bank_transaction_id: line,
    p_kind: kind,
    p_payment_id: (kind === "return" ? payment : null) as string,
    p_refund_request_id: (kind === "refund" || kind === "refund_returned" ? refund : null) as string,
    p_expected_left_minor: (kind === "return" ? expected : null) as string,
    p_reason: reason,
  });
  return done(error, kind === "return" ? payment : undefined);
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
