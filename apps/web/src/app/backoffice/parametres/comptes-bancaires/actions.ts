"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import { bankAccountErrorCode } from "@/lib/payments/bank-accounts";
import { cleanTypedCode } from "@/lib/payments/iban";

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
    p_iban: cleanTypedCode(field(formData, "iban")),
    p_currency: field(formData, "currency"),
    p_feed: field(formData, "feed"),
    p_bic: cleanTypedCode(field(formData, "bic")) || undefined,
    p_opened_on: field(formData, "opened_on") || undefined,
  });
  return done(error);
}

export async function closeBankAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const account = field(formData, "bank_account_id");
  if (!UUID.test(key) || !UUID.test(account)) return { error: "unknown" };
  const { supabase } = await staffSession();
  // Closing is final: staff retype the end of the IBAN, so the wrong card cannot be closed by a tap.
  const { data: target } = await supabase.from("bank_account").select("iban").eq("id", account).maybeSingle();
  const typed = cleanTypedCode(field(formData, "confirm_iban"));
  if (!target || typed.length !== 4 || !target.iban.endsWith(typed)) return { error: "close_confirmation" };
  const { error } = await supabase.rpc("close_bank_account", {
    p_idempotency_key: key,
    p_bank_account_id: account,
    p_reason: field(formData, "reason"),
  });
  return done(error);
}
