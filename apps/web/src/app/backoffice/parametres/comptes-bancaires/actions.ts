"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import { bankAccountErrorCode } from "@/lib/payments/bank-accounts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PATH = "/backoffice/parametres/comptes-bancaires";

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

/** Authorization (admin at aal2) and validation are in the SQL commands; errors become codes. */
function done(error: { message: string } | null): ActionResult {
  if (error) {
    console.error("bank account command failed", { error: error.message });
    return { error: bankAccountErrorCode(error.message) };
  }
  revalidatePath(PATH);
  return { ok: true };
}

export async function registerBankAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const organization = field(formData, "organization_id");
  if (!UUID.test(key) || !UUID.test(organization)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("register_bank_account", {
    p_idempotency_key: key,
    p_organization_id: organization,
    p_label: field(formData, "label"),
    p_iban: field(formData, "iban"),
    p_currency: field(formData, "currency"),
    p_feed: field(formData, "feed"),
    p_bic: field(formData, "bic") || undefined,
    p_opened_on: field(formData, "opened_on") || undefined,
  });
  return done(error);
}

export async function closeBankAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const account = field(formData, "bank_account_id");
  if (!UUID.test(key) || !UUID.test(account)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("close_bank_account", {
    p_idempotency_key: key,
    p_bank_account_id: account,
    p_reason: field(formData, "reason"),
  });
  return done(error);
}
