"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import { type QueueAccount, matchingErrorCode } from "@/lib/payments/matching";

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

/** Accept the one-tap suggestion of one payment, or of several (bulk, on desktop). */
export async function acceptSuggestions(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const ids = formData.getAll("payment_id").map(String).filter((id) => UUID.test(id));
  if (!UUID.test(key) || ids.length === 0 || ids.length > 200) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("accept_suggestions", { p_idempotency_key: key, p_payment_ids: ids });
  return done(error);
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
