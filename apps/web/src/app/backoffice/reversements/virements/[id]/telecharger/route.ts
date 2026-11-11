import { createHash } from "node:crypto";
import { staffSession } from "@/lib/auth/staff";
import { downloadWarning } from "@/lib/remittance/transfers";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
}

/**
 * M2c-6a « Télécharger » a transfer file (design §11, ops critique #33; risk R4). Read with the caller's session (RLS and
 * the storage policy of the private bucket `transfer-files`: money staff at aal2), the bytes checked against the
 * SHA-256 the job recorded, then the download recorded by `transfer_file_download` — which refuses a second download
 * unless the warning was acknowledged (`?confirme=1`) — and only then served. The bytes come from our route after the
 * hash check, never from a signed URL the browser would fetch unchecked.
 */
export async function GET(request: Request, context: RouteContext<"/backoffice/reversements/virements/[id]/telecharger">) {
  const { id } = await context.params;
  if (!UUID.test(id)) return text(404, "Fichier introuvable.");
  const { supabase } = await staffSession();
  const { data: file } = await supabase
    .from("transfer_file")
    .select("number, status, storage_path, file_sha256, download_count, first_downloaded_at")
    .eq("id", id)
    .maybeSingle();
  if (!file || !file.storage_path || !file.file_sha256) return text(404, "Fichier introuvable ou pas encore écrit.");
  const { data: blob, error } = await supabase.storage.from("transfer-files").download(file.storage_path);
  if (error || !blob) return text(502, "Le fichier est momentanément indisponible. Réessayez.");
  const bytes = Buffer.from(await blob.arrayBuffer());
  const digest = createHash("sha256").update(bytes).digest("hex");
  if (digest !== file.file_sha256) {
    console.error("transfer file does not match its recorded hash", id);
    return text(500, "Le fichier stocké ne correspond pas au fichier généré : il n'est pas servi. Prévenez le support.");
  }
  const acknowledged = new URL(request.url).searchParams.get("confirme") === "1";
  const { error: recorded } = await supabase.rpc("transfer_file_download", {
    p_file_id: id,
    p_sha256: digest,
    p_acknowledged: acknowledged,
  });
  if (recorded) {
    if (recorded.message.includes("already_downloaded")) {
      // who downloaded it first, as the file's detail names them (the users' names are read by the definer function)
      const { data: detail } = await supabase.rpc("transfer_file_detail", { p_file_id: id, p_after_seq: 0, p_limit: 1 });
      const d = (detail ?? {}) as { first_downloaded_by?: string | null };
      const warning = downloadWarning({
        download_count: file.download_count,
        first_downloaded_at: file.first_downloaded_at,
        first_downloaded_by: d.first_downloaded_by ?? null,
      });
      return text(409, `${warning ?? "Déjà téléchargé"}. Confirmez l'avertissement sur la page pour le télécharger de nouveau.`);
    }
    console.error("transfer file download refused", { id, error: recorded.message });
    return text(409, "Ce fichier ne peut pas être téléchargé (remplacé, rejeté ou en cours d'écriture). Rechargez la page.");
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
