import { createHash } from "node:crypto";
import { NextResponse } from "next/server";
import { staffSession } from "@/lib/auth/staff";
import { supabaseEnv } from "@/lib/supabase/env";
import { transferFileReader } from "@/lib/supabase/transfer-file-bytes";
import { type DownloadRefusal, type DownloadOutcome, downloadOutcome, refusalUrl } from "@/lib/remittance/transfers";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
}

/** Back to the file's page, which says what happened (review tests-ui#9: never a bare text page the browser lands on). */
function refused(request: Request, id: string, code: DownloadRefusal, outcome?: DownloadOutcome): Response {
  const blocked = outcome?.kind === "refused" ? outcome.blocked : [];
  return NextResponse.redirect(new URL(refusalUrl(id, code, blocked), request.url), { status: 303 });
}

/**
 * The bytes, read only once the command accepted the download (review T4): through a URL the command minted, else with
 * the service role (no storage policy reads the bucket), else — an older policy — with the caller's session.
 */
async function readBytes(
  supabase: Awaited<ReturnType<typeof staffSession>>["supabase"],
  outcome: Extract<DownloadOutcome, { kind: "ok" }>,
  storagePath: string,
): Promise<Buffer<ArrayBuffer> | null> {
  if (outcome.signedUrl) {
    // only our own Supabase's storage (the URL comes from our database, never from the request)
    const own = new URL(supabaseEnv().url);
    const url = new URL(outcome.signedUrl, own);
    if (url.origin !== own.origin) return null;
    const res = await fetch(url, { cache: "no-store" });
    return res.ok ? Buffer.from(await res.arrayBuffer()) : null;
  }
  // the file's own row gave the path (read with the caller's session, RLS); the command answers for that file
  if (outcome.storagePath !== null && outcome.storagePath !== storagePath) return null;
  const read = transferFileReader();
  if (read) return read(storagePath);
  const { data: blob, error } = await supabase.storage.from("transfer-files").download(storagePath);
  return error || !blob ? null : Buffer.from(await blob.arrayBuffer());
}

/**
 * M2c-6a « Télécharger » a transfer file (design §11, ops critique #33; risk R4). Review fixes:
 * - T2 (pain001#0, money#0, security#0): the command `transfer_file_download` runs **first**. Under the generation's
 *   locks it re-runs the date rule, the payee blockers, the per-client cap and the cash check; a stale or blocked file
 *   is replaced and refused (`file_stale`, `file_blocked` with the transfers and their reasons). It records every
 *   download and refuses a second one unless the warning was acknowledged (`?confirme=1`).
 * - T4 (money#3, security#2): only then are the bytes read — no storage policy reads the bucket: with the service role
 *   (`lib/supabase/transfer-file-bytes.ts`, server-side only), or through a signed URL should the command return one —
 *   and served only if their SHA-256 is the one the job recorded (the command is given that recorded hash: the check of
 *   the bytes themselves is this route's). A superseded, rejected or failed file never passes the command.
 * - tests-ui#9: every refusal sends the browser back to the file's page with what happened (the second-download
 *   warning opened, « Régénérer » for a replaced file), with a 303.
 */
export async function GET(request: Request, context: RouteContext<"/backoffice/reversements/virements/[id]/telecharger">) {
  const { id } = await context.params;
  if (!UUID.test(id)) return text(404, "Fichier introuvable.");
  const { supabase } = await staffSession();
  const { data: file } = await supabase
    .from("transfer_file")
    .select("number, status, storage_path, file_sha256")
    .eq("id", id)
    .maybeSingle();
  if (!file) return text(404, "Fichier introuvable.");
  if (!file.storage_path || !file.file_sha256) return refused(request, id, file.status === "pending" ? "not_ready" : "not_downloadable");
  const acknowledged = new URL(request.url).searchParams.get("confirme") === "1";
  const { data, error } = await supabase.rpc("transfer_file_download", {
    p_file_id: id,
    p_sha256: file.file_sha256,
    p_acknowledged: acknowledged,
  });
  const outcome = downloadOutcome(data, error ? { message: error.message, details: error.details } : null);
  if (outcome.kind === "refused") {
    if (outcome.code === "unknown") console.error("transfer file download refused", { id, error: error?.message ?? null });
    return refused(request, id, outcome.code, outcome);
  }
  const bytes = await readBytes(supabase, outcome, file.storage_path);
  if (!bytes) {
    console.error("transfer file bytes unavailable after the download was recorded", id);
    return refused(request, id, "unavailable");
  }
  const digest = createHash("sha256").update(bytes).digest("hex");
  if (digest !== file.file_sha256) {
    console.error("transfer file does not match its recorded hash", id);
    return refused(request, id, "hash_mismatch");
  }
  return new Response(bytes, {
    headers: {
      "Content-Type": "application/xml",
      "Content-Disposition": `attachment; filename="${file.number.replace(/[^A-Z0-9-]/g, "_")}.xml"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
