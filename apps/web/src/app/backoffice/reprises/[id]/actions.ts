"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import { type ActionResult, commandErrorCode, mappingOverrides } from "@/lib/boarding/forms";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function batchId(formData: FormData): string | null {
  const id = String(formData.get("batch_id") ?? "");
  return UUID.test(id) ? id : null;
}

/** Authorization is in the SQL commands (can_board / has_role + aal2); errors become codes. */
function done(id: string, error: { message: string } | null): ActionResult {
  if (error) {
    console.error("boarding command failed", { batch: id, error: error.message });
    return { error: commandErrorCode(error.message) };
  }
  revalidatePath(`/backoffice/reprises/${id}`);
  return { ok: true };
}

/** Accept the proposals; selects changed by the reviewer become overrides. */
export async function approveMapping(formData: FormData): Promise<ActionResult> {
  const id = batchId(formData);
  if (!id) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { data: proposals } = await supabase
    .from("mapping_proposal")
    .select("file_id, source_column, target")
    .eq("batch_id", id);
  const overrides = mappingOverrides(proposals ?? [], (field) => {
    const v = formData.get(field);
    return v === null ? null : String(v);
  });
  const { error } = await supabase.rpc("approve_mapping", { p_batch_id: id, p_overrides: overrides });
  return done(id, error);
}

export async function commitBatch(formData: FormData): Promise<ActionResult> {
  const id = batchId(formData);
  if (!id) return { error: "unknown" };
  const { supabase } = await staffSession();
  const reason = String(formData.get("reason") ?? "").trim();
  const { error } = await supabase.rpc("commit_boarding_batch", {
    p_batch_id: id,
    p_override_reason: reason || undefined,
  });
  return done(id, error);
}

export async function rollbackBatch(formData: FormData): Promise<ActionResult> {
  const id = batchId(formData);
  if (!id) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("rollback_boarding_batch", {
    p_batch_id: id,
    p_reason: String(formData.get("reason") ?? ""),
  });
  return done(id, error);
}

export async function confirmBatch(formData: FormData): Promise<ActionResult> {
  const id = batchId(formData);
  if (!id) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("confirm_boarding_batch", { p_batch_id: id });
  return done(id, error);
}

export async function abandonBatch(formData: FormData): Promise<ActionResult> {
  const id = batchId(formData);
  if (!id) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("abandon_boarding_batch", {
    p_batch_id: id,
    p_reason: String(formData.get("reason") ?? ""),
  });
  return done(id, error);
}
