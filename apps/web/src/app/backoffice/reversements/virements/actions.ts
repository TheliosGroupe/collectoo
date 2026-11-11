"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult } from "@/lib/boarding/forms";
import { PAIN_VERSIONS, cancellationCall, cancellationRpc, payeeCheckErrorCode, transferErrorCode } from "@/lib/remittance/transfers";

/**
 * M2c-6a « Virements » commands (design §11, §16). Authorization (admins and ops managers at aal2; the pain.001
 * version: admins), compare and set (the file's version), idempotency, the statement's evidence and the four eyes of a
 * cancellation after download (review T1) are in the SQL commands; errors become codes, never the database's text.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

function version(formData: FormData): number | null {
  const v = field(formData, "expected_version");
  return /^\d+$/.test(v) ? Number(v) : null;
}

function done(error: { message: string } | null, file?: string, code = transferErrorCode): ActionResult {
  if (error) {
    console.error("transfer file command failed", { error: error.message });
    return { error: code(error.message) };
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

/**
 * « Annuler le fichier » before download: it is replaced (nothing left the bank). A downloaded or sent file goes through
 * the two steps below (review T1), never through this one.
 */
export async function cancelFile(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const file = field(formData, "file_id");
  const v = version(formData);
  const reason = field(formData, "reason");
  if (!UUID.test(key) || !UUID.test(file) || v === null) return { error: "unknown" };
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("cancel_transfer_file", {
    p_idempotency_key: key,
    p_file_id: file,
    p_expected_version: v,
    p_reason: reason,
  });
  return done(error, file);
}

/**
 * The two steps of a cancellation after download (review T1; money#1, security#1, pain001#1): one person asks — with
 * the attestation for a file —, another confirms; the database checks the statement's evidence at both steps and that
 * the confirmer is not the requester. `file_id` (with the file's version) or `transfer_id` names the target.
 */
async function cancellationStepAction(step: "request" | "confirm", formData: FormData): Promise<ActionResult> {
  const target = field(formData, "transfer_id") ? "transfer" : "file";
  const call = cancellationCall(step, target, (name) => field(formData, name));
  if ("error" in call) return call;
  const { supabase } = await staffSession();
  const { error } = await cancellationRpc(supabase)(call.fn, call.args);
  const file = field(formData, "file_id");
  return done(error, UUID.test(file) ? file : undefined);
}

/** « Demander l'annulation » of a downloaded or sent file, or of one transfer in it (step 1 of 2). */
export async function requestCancellation(formData: FormData): Promise<ActionResult> {
  return cancellationStepAction("request", formData);
}

/** « Confirmer l'annulation » asked by someone else (step 2 of 2): the transfers go back « à mettre dans un fichier ». */
export async function confirmCancellation(formData: FormData): Promise<ActionResult> {
  return cancellationStepAction("confirm", formData);
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

/**
 * « Nom vérifié »: another person lifts the payee check — not who recorded it, nor who proposed or confirmed the
 * flagged IBAN (review T5: the database refuses them, `same_person`).
 */
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
  return done(error, undefined, payeeCheckErrorCode);
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
