"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { staffSession } from "@/lib/auth/staff";
import { commandError, mappingOverrides } from "@/lib/boarding/forms";

const UUID = /^[0-9a-f-]{36}$/;

function batchId(formData: FormData): string {
  const id = String(formData.get("batch_id") ?? "");
  if (!UUID.test(id)) throw new Error("bad batch id");
  return id;
}

function done(id: string, error?: { message: string } | null): never {
  const path = `/backoffice/reprises/${id}`;
  revalidatePath(path);
  redirect(error ? `${path}?erreur=${encodeURIComponent(commandError(error.message))}` : path);
}

/** Accept the proposals; selects changed by the reviewer become overrides. */
export async function approveMapping(formData: FormData) {
  const id = batchId(formData);
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
  done(id, error);
}

export async function commitBatch(formData: FormData) {
  const id = batchId(formData);
  const { supabase } = await staffSession();
  const reason = String(formData.get("reason") ?? "").trim();
  const { error } = await supabase.rpc("commit_boarding_batch", {
    p_batch_id: id,
    p_override_reason: reason || undefined,
  });
  done(id, error);
}

export async function rollbackBatch(formData: FormData) {
  const id = batchId(formData);
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("rollback_boarding_batch", {
    p_batch_id: id,
    p_reason: String(formData.get("reason") ?? ""),
  });
  done(id, error);
}

export async function confirmBatch(formData: FormData) {
  const id = batchId(formData);
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("confirm_boarding_batch", { p_batch_id: id });
  done(id, error);
}
