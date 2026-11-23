"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import { coverErrorCode, fullCheckErrorCode } from "@/lib/payments/remitted";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

/** M2c-7a « Couvrir » (plan §3.2.9): an admin records the cover the nightly found missing, for the gap the page showed
 * (compare and set in SQL; admins at aal2 only, checked there). */
export async function coverRemittedReversal(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const reversal = field(formData, "reversal_id");
  const expected = field(formData, "expected_gap");
  if (!UUID.test(key) || !UUID.test(reversal) || !/^-?\d{1,16}$/.test(expected)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("cover_remitted_reversal", {
    p_idempotency_key: key,
    p_reversal_id: reversal,
    p_expected_gap_text: expected,
  });
  if (error) {
    console.error("cover command failed", { error: error.message });
    return { error: coverErrorCode(error.message) };
  }
  revalidatePath("/backoffice/encaissements/controles");
  return { ok: true };
}

/** M2c-7a « Vérification complète des avances » (plan §3.2.11 [check 2]): the full pass of the advance checks, taken by
 * the checks queued with it (admins at aal2 only, checked in SQL). */
export async function requestFullAdvanceCheck(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const org = field(formData, "organization_id");
  if (!UUID.test(key) || !UUID.test(org)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("request_full_advance_check", {
    p_idempotency_key: key,
    p_organization_id: org,
  });
  if (error) {
    console.error("full check request failed", { error: error.message });
    return { error: fullCheckErrorCode(error.message) };
  }
  revalidatePath("/backoffice/encaissements/controles");
  return { ok: true };
}
