"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import { PAIN_VERSIONS, transferErrorCode } from "@/lib/remittance/transfers";

/**
 * M2c-6a « Virements » commands (design §11, §16). Authorization (admins and ops managers at aal2; the pain.001
 * version: admins), compare and set (the file's version) and idempotency are in the SQL commands; errors become codes,
 * never the database's text.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

function version(formData: FormData): number | null {
  const v = field(formData, "expected_version");
  return /^\d+$/.test(v) ? Number(v) : null;
}

function done(error: { message: string } | null, file?: string): ActionResult {
  if (error) {
    console.error("transfer file command failed", { error: error.message });
    return { error: transferErrorCode(error.message) };
  }
  revalidatePath("/backoffice/reversements/virements");
  if (file) revalidatePath(`/backoffice/reversements/virements/${file}`);
  return { ok: true };
}

/** « Générer le fichier » for one paying account (with the late reason when some payouts are late). */
export async function generateFile(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const account = field(formData, "bank_account_id");
  const late = field(formData, "late_reason");
  if (!UUID.test(key) || !UUID.test(account)) return { error: "unknown" };
  if (field(formData, "late_required") === "1" && !late) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("generate_transfer_file", {
    p_idempotency_key: key,
    p_bank_account_id: account,
    p_late_reason: (late || null) as string,
  });
  return done(error);
}

/** « Marquer comme transmis »: ops uploaded the file at the bank. */
export async function markSent(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const file = field(formData, "file_id");
  const v = version(formData);
  if (!UUID.test(key) || !UUID.test(file) || v === null) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("mark_transfer_file_sent", {
    p_idempotency_key: key,
    p_file_id: file,
    p_expected_version: v,
  });
  return done(error, file);
}

/** « Annuler le fichier » before download, « Rejeté par la banque » / not uploaded after (with the attestation). */
export async function cancelFile(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const file = field(formData, "file_id");
  const v = version(formData);
  const reason = field(formData, "reason");
  const attestation = field(formData, "attestation");
  if (!UUID.test(key) || !UUID.test(file) || v === null) return { error: "unknown" };
  if (!reason) return { error: "reason_required" };
  if (attestation && attestation !== "not_uploaded" && attestation !== "rejected_by_bank") return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("cancel_transfer_file", {
    p_idempotency_key: key,
    p_file_id: file,
    p_expected_version: v,
    p_reason: reason,
    p_attestation: (attestation || null) as string,
  });
  return done(error, file);
}

/** « Nom du bénéficiaire non concordant » (verification of payee, Reg. 260/2012 art. 5 quater). */
export async function recordPayeeMismatch(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const transfer = field(formData, "transfer_id");
  const file = field(formData, "file_id");
  const result = field(formData, "result");
  const note = field(formData, "note");
  if (!UUID.test(key) || !UUID.test(transfer) || (result !== "no_match" && result !== "close_match")) return { error: "unknown" };
  if (!note) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("record_payee_name_mismatch", {
    p_idempotency_key: key,
    p_transfer_id: transfer,
    p_result: result,
    p_bank_name: (field(formData, "bank_name") || null) as string,
    p_note: note,
  });
  return done(error, UUID.test(file) ? file : undefined);
}

/** « Nom vérifié »: another person lifts the payee check. */
export async function clearPayeeMismatch(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const check = field(formData, "check_id");
  const reason = field(formData, "reason");
  if (!UUID.test(key) || !UUID.test(check)) return { error: "unknown" };
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("clear_payee_name_mismatch", {
    p_idempotency_key: key,
    p_check_id: check,
    p_reason: reason,
  });
  return done(error);
}

/** The pain.001 version a paying account's files are written in (admins). */
export async function setPainVersion(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const account = field(formData, "bank_account_id");
  const v = field(formData, "pain_version");
  if (!UUID.test(key) || !UUID.test(account) || !(PAIN_VERSIONS as readonly string[]).includes(v)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("set_bank_account_pain_version", {
    p_idempotency_key: key,
    p_bank_account_id: account,
    p_version: v,
  });
  return done(error);
}
