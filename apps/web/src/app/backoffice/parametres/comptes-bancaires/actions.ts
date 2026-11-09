"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import { type ActionResult, parseEurosToMinor } from "@/lib/boarding/forms";
import { bankAccountErrorCode } from "@/lib/payments/bank-accounts";
import { cleanTypedCode } from "@/lib/payments/iban";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PATH = "/backoffice/parametres/comptes-bancaires";
const PURPOSES = new Set(["client_funds", "own"]);

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

/** A client-funds account (R124-2; one active per currency is founder #14, not the law) or, since M2c, the servicer's own
 * account (no feed). */
export async function registerBankAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const organization = field(formData, "organization_id");
  const purpose = field(formData, "purpose") || "client_funds";
  if (!UUID.test(key) || !UUID.test(organization) || !PURPOSES.has(purpose)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("register_bank_account", {
    p_idempotency_key: key,
    p_organization_id: organization,
    p_label: field(formData, "label"),
    p_iban: cleanTypedCode(field(formData, "iban")),
    p_currency: field(formData, "currency"),
    p_feed: purpose === "own" ? "" : field(formData, "feed"),
    p_bic: cleanTypedCode(field(formData, "bic")) || undefined,
    p_opened_on: field(formData, "opened_on") || undefined,
    p_purpose: purpose,
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

/** « Approvisionner le compte dédié » (M2c-1): a top-up from the own account; the page then shows our TOP reference to
 * type in the bank. Nothing is booked before the credit is on the dedicated account's statement. */
export async function requestTopUp(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const own = field(formData, "own_bank_account_id");
  const target = field(formData, "client_funds_bank_account_id");
  if (!UUID.test(key) || !UUID.test(own) || !UUID.test(target)) return { error: "unknown" };
  const minor = parseEurosToMinor(field(formData, "amount"));
  if (minor === null || minor <= BigInt(0)) return { error: "amount_invalid" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("request_top_up", {
    p_idempotency_key: key,
    p_own_bank_account_id: own,
    p_client_funds_bank_account_id: target,
    p_amount_minor: minor.toString(),
    p_reason: reason,
  });
  return done(error);
}

export async function cancelTopUp(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const transfer = field(formData, "transfer_id");
  if (!UUID.test(key) || !UUID.test(transfer)) return { error: "unknown" };
  const reason = field(formData, "reason");
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("cancel_top_up", {
    p_idempotency_key: key,
    p_transfer_id: transfer,
    p_reason: reason,
  });
  return done(error);
}
