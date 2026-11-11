"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ActionResult, ErrorCode } from "@/lib/boarding/forms";
import type { Json } from "@/lib/database.types";
import { type ApprovalOutcome, approvalSummary, runErrorCode } from "@/lib/remittance/runs";

/**
 * M2c-4 « Reversements » commands. Authorization (admins and ops managers at aal2; cancellation: admins), compare and
 * set (the version, or each run's inputs hash and net as the page showed them) and idempotency are in the SQL
 * commands; errors become codes, never the database's text.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const HASH = /^[0-9a-f]{64}$/;

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

function version(formData: FormData): number | null {
  const v = field(formData, "expected_version");
  return /^\d+$/.test(v) ? Number(v) : null;
}

function done(error: { message: string } | null, run?: string): ActionResult {
  if (error) {
    console.error("remittance command failed", { error: error.message });
    return { error: runErrorCode(error.message) };
  }
  revalidatePath("/backoffice/reversements");
  if (run) revalidatePath(`/backoffice/reversements/${run}`);
  return { ok: true };
}

/** « Préparer maintenant » (§9.3 d). */
export async function requestRun(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const client = field(formData, "client_organization_id");
  const currency = field(formData, "currency") || "EUR";
  if (!UUID.test(key) || !UUID.test(client) || !/^[A-Z]{3}$/.test(currency)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("request_remittance_run", {
    p_idempotency_key: key,
    p_client_organization_id: client,
    p_currency: currency,
  });
  return done(error);
}

/** « Actualiser »: reserved again, prepared again (a new K). */
export async function refreshRun(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const run = field(formData, "run_id");
  const v = version(formData);
  if (!UUID.test(key) || !UUID.test(run) || v === null) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("refresh_remittance_run", {
    p_idempotency_key: key,
    p_run_id: run,
    p_expected_version: v,
  });
  return done(error, run);
}

/** « Abandonner » a draft: its items go back to the queue. */
export async function discardRun(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const run = field(formData, "run_id");
  const v = version(formData);
  const reason = field(formData, "reason");
  if (!UUID.test(key) || !UUID.test(run) || v === null) return { error: "unknown" };
  if (!reason) return { error: "reason_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("discard_remittance_run", {
    p_idempotency_key: key,
    p_run_id: run,
    p_expected_version: v,
    p_reason: reason,
  });
  return done(error, run);
}

/**
 * « Annuler » an approved run (admin): a full credit note per invoice. Before its file is downloaded the transfer is
 * cancelled (its file replaced); after download (M2c-6a) only with the attestation that the bank did not execute it,
 * once the statement of its execution day is imported without its debit.
 */
export async function cancelRun(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const run = field(formData, "run_id");
  const v = version(formData);
  const reason = field(formData, "reason");
  const attested = field(formData, "attestation") === "not_executed";
  if (!UUID.test(key) || !UUID.test(run) || v === null) return { error: "unknown" };
  if (!reason) return { error: "reason_required" };
  if (field(formData, "attestation_required") === "1" && !attested) return { error: "transfer_attestation_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("cancel_remittance_run", {
    p_idempotency_key: key,
    p_run_id: run,
    p_expected_version: v,
    p_reason: reason,
    p_attestation: (attested ? "not_executed" : null) as string,
  });
  return done(error, run);
}

export type ApproveResult = ({ ok: true } & ApprovalOutcome) | { error: ErrorCode };

/**
 * « Valider » one or many drafts (≤ 200): each checked box carries the run, its inputs hash and its net as the page
 * showed them (`run`: "id|hash|net"); the execution date requested (default: the next business day) and, past a
 * latest execution date, the reason. The jobs then approve each run in its own transaction. The command refuses a run
 * on its own (a run locked by a job: « busy ») and goes on with the others; the result counts the refused.
 */
export async function approveRuns(formData: FormData): Promise<ApproveResult> {
  const key = field(formData, "idempotency_key");
  const date = field(formData, "requested_execution_date");
  const lateReason = field(formData, "late_reason");
  if (!UUID.test(key) || (date && !DATE.test(date))) return { error: "unknown" };
  const items: { run_id: string; inputs_hash: string; net_text: string }[] = [];
  for (const raw of formData.getAll("run")) {
    const [run, hash, net] = String(raw).split("|");
    if (!UUID.test(run ?? "") || !HASH.test(hash ?? "") || !/^-?\d+$/.test(net ?? "")) return { error: "unknown" };
    items.push({ run_id: run, inputs_hash: hash, net_text: net });
  }
  if (items.length === 0) return { error: "run_none_selected" };
  if (items.length > 200) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("approve_remittance_runs", {
    p_idempotency_key: key,
    p_items: items as unknown as Json,
    p_requested_execution_date: date || undefined,
    p_late_reason: lateReason || undefined,
  });
  if (error) {
    console.error("remittance approval failed", { error: error.message });
    return { error: runErrorCode(error.message) };
  }
  revalidatePath("/backoffice/reversements");
  const results = ((data as { results?: unknown } | null)?.results ?? []) as {
    number: string | null;
    status: string;
    reason: string | null;
  }[];
  return { ok: true, ...approvalSummary(results) };
}
