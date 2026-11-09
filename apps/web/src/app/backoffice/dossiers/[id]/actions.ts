"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import { type ActionResult, parseEurosToMinor } from "@/lib/boarding/forms";
import { allocationErrorCode } from "@/lib/payments/allocation";
import { debitErrorCode } from "@/lib/payments/debits";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * « Appliquer l'avoir » (founder #7): the proposal the page showed (its key) is applied as one netting entry;
 * compensation is invoked (art. 1347 C. civ.). Authorization and the compare and set are in the SQL command.
 */
export async function applyCreditNote(formData: FormData): Promise<ActionResult> {
  const key = String(formData.get("idempotency_key") ?? "");
  const account = String(formData.get("account_id") ?? "");
  const proposal = String(formData.get("proposal_key") ?? "");
  if (!UUID.test(key) || !UUID.test(account) || !/^[0-9a-f]{64}$/.test(proposal)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("apply_credit_note", {
    p_idempotency_key: key,
    p_account_id: account,
    p_proposal_key: proposal,
  });
  if (error) {
    console.error("credit note command failed", { error: error.message });
    return { error: allocationErrorCode(error.message) };
  }
  revalidatePath(`/backoffice/dossiers/${account}`);
  return { ok: true };
}

/**
 * « Paiement direct au client » (design §8.1): the client's statement says the debtor paid it directly; the worker's
 * waterfall splits the amount in the legal order and books an adjustment. Every check is in the SQL command.
 */
export async function recordDirectPayment(formData: FormData): Promise<ActionResult> {
  const key = String(formData.get("idempotency_key") ?? "");
  const account = String(formData.get("account_id") ?? "");
  const evidence = String(formData.get("evidence_document_id") ?? "");
  const paidOn = String(formData.get("paid_on") ?? "");
  const items = formData.getAll("item_id").map(String);
  if (!UUID.test(key) || !UUID.test(account) || !items.every((i) => UUID.test(i))) return { error: "unknown" };
  if (!UUID.test(evidence)) return { error: "direct_evidence" };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(paidOn)) return { error: "direct_date" };
  const amount = parseEurosToMinor(String(formData.get("amount") ?? ""));
  if (amount === null || amount <= BigInt(0)) return { error: "amount_invalid" };
  const reason = String(formData.get("reason") ?? "").trim();
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("record_direct_payment", {
    p_idempotency_key: key,
    p_account_id: account,
    p_item_ids: items,
    p_amount_minor: amount.toString(),
    p_paid_on: paidOn,
    p_evidence_document_id: evidence,
    p_reason: reason,
  });
  if (error) {
    console.error("direct payment command failed", { error: error.message });
    return { error: debitErrorCode(error.message) };
  }
  revalidatePath(`/backoffice/dossiers/${account}`);
  return { ok: true };
}
