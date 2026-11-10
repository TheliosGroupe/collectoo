import { createHash } from "node:crypto";
import type { createClient } from "@/lib/supabase/server";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const KINDS = new Set(["payout_rib", "mandate_document", "client_status_evidence"]);

type Supabase = Awaited<ReturnType<typeof createClient>>;

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
}

/**
 * M2c-2: a client document (the RIB of a payout account, the signed mandate or its amendment, the evidence of an event),
 * read with the caller's session — RLS on `document` and the storage policy decide who may: money staff, and for the RIB
 * and the mandate the client's administrators with access to the whole client. The bytes are checked against the
 * SHA-256 recorded at registration before they are served.
 */
export async function clientDocumentResponse(supabase: Supabase, id: string): Promise<Response> {
  if (!UUID.test(id)) return text(404, "Document introuvable.");
  const { data: doc } = await supabase
    .from("document")
    .select("kind, storage_bucket, storage_path, sha256, mime_type, file_name")
    .eq("id", id)
    .maybeSingle();
  if (!doc || !KINDS.has(doc.kind)) return text(404, "Document introuvable.");
  const { data: blob, error } = await supabase.storage.from(doc.storage_bucket).download(doc.storage_path);
  if (error || !blob) return text(404, "Le fichier de ce document n'est pas disponible.");
  const bytes = Buffer.from(await blob.arrayBuffer());
  if (createHash("sha256").update(bytes).digest("hex") !== doc.sha256) {
    console.error("client document does not match its recorded hash", id);
    return text(500, "Le fichier stocké ne correspond pas au document enregistré.");
  }
  const name = (doc.file_name ?? "document").replace(/["\\\r\n]/g, "_");
  return new Response(bytes, {
    headers: {
      "Content-Type": doc.mime_type,
      "Content-Disposition": `inline; filename="${name}"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
