"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import {
  type AcceptResult,
  type AcceptSkip,
  type QueueAccount,
  matchingErrorCode,
  parseAcceptItems,
} from "@/lib/payments/matching";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PATH = "/backoffice/encaissements/a-traiter";

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

/** Authorization (admin or ops manager at aal2) and every check are in the SQL commands. */
function done(error: { message: string } | null): ActionResult {
  if (error) {
    console.error("matching command failed", { error: error.message });
    return { error: matchingErrorCode(error.message) };
  }
  revalidatePath(PATH);
  return { ok: true };
}

/**
 * Accept the one-tap suggestion of one payment, or of several (bulk, on desktop). Each `item` is
 * « payment:file », the file the page showed: the command assigns a payment only if that file is still
 * its suggestion, and says which it skipped and why (the page tells ops).
 */
export async function acceptSuggestions(formData: FormData): Promise<AcceptResult> {
  const key = field(formData, "idempotency_key");
  const values = formData.getAll("item").map(String);
  if (!UUID.test(key)) return { error: "unknown" };
  if (values.length === 0) return { error: "none_selected" };
  const items = parseAcceptItems(values);
  if (items === null || items.length > 200) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("accept_suggestions", { p_idempotency_key: key, p_items: items });
  if (error) {
    console.error("matching command failed", { error: error.message });
    return { error: matchingErrorCode(error.message) };
  }
  revalidatePath(PATH);
  const result = (data ?? {}) as { accepted?: number; skipped?: AcceptSkip[] };
  return { ok: true, accepted: Number(result.accepted ?? 0), skipped: result.skipped ?? [] };
}

/** Assign a payment to one file, with the reason ops give. */
export async function assignPayment(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const payment = field(formData, "payment_id");
  const account = field(formData, "account_id");
  if (!UUID.test(key) || !UUID.test(payment) || !UUID.test(account)) return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("assign_payment", {
    p_idempotency_key: key,
    p_payment_id: payment,
    p_splits: [{ account_id: account }],
    p_designation: null,
    p_reason: reason,
  });
  return done(error);
}

/** Take a payment off its file (nothing allocated yet): back to the queue. */
export async function unassignPayment(formData: FormData): Promise<ActionResult> {
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
  return done(error);
}

/** Files ops may assign a payment to: by file, invoice or RF reference, else by debtor name. */
export async function searchFiles(
  paymentId: string,
  query: string,
): Promise<{ files: (QueueAccount & { found_by: string })[] } | { error: "unknown" }> {
  if (!UUID.test(paymentId) || query.trim().length < 3 || query.length > 100) return { files: [] };
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("search_payment_files", { p_payment_id: paymentId, p_query: query });
  if (error) {
    console.error("file search failed", { error: error.message });
    return { error: "unknown" };
  }
  return { files: (data ?? []) as (QueueAccount & { found_by: string })[] };
}
