"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import { allocationErrorCode } from "@/lib/payments/allocation";

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
