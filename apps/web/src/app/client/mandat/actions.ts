"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import type { ActionResult } from "@/lib/boarding/forms";
import { cleanTypedCode } from "@/lib/payments/iban";
import { identityErrorCode } from "@/lib/remittance/terms";
import { createClient } from "@/lib/supabase/server";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function clientSession() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims?.sub) redirect("/connexion");
  return supabase;
}

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

function done(error: { message: string } | null): ActionResult {
  if (error) {
    console.error("client payout command failed", { error: error.message });
    return { error: identityErrorCode(error.message) };
  }
  revalidatePath("/client/mandat");
  return { ok: true };
}

/**
 * « Confirmer le nouvel IBAN » (founder #10): the client's administrator, with access to the whole client, at aal2,
 * types the IBAN read on its own RIB; the database checks it is the one proposed and that a second person confirms.
 */
export async function confirmOwnPayoutAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const account = field(formData, "payout_account_id");
  if (!UUID.test(key) || !UUID.test(account)) return { error: "unknown" };
  const supabase = await clientSession();
  const { error } = await supabase.rpc("confirm_payout_account", {
    p_idempotency_key: key,
    p_payout_account_id: account,
    p_iban_typed: cleanTypedCode(field(formData, "iban_typed")),
  });
  return done(error);
}

/** « Ce n'est pas notre compte »: the client's administrator refuses a proposal, with a reason. */
export async function rejectOwnPayoutAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const account = field(formData, "payout_account_id");
  if (!UUID.test(key) || !UUID.test(account)) return { error: "unknown" };
  const supabase = await clientSession();
  const { error } = await supabase.rpc("reject_payout_account", {
    p_idempotency_key: key,
    p_payout_account_id: account,
    p_reason: field(formData, "reason"),
  });
  return done(error);
}
