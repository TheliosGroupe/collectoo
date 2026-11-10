import { createHash } from "node:crypto";
import type { createClient } from "@/lib/supabase/server";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** The documents M2c-5 draws: a run's statement (PDF, CSV) and the PDF of an invoice or credit note. */
export const REMITTANCE_KINDS = new Set(["remittance_statement_pdf", "remittance_statement_csv", "commission_invoice_pdf"]);

type Supabase = Awaited<ReturnType<typeof createClient>>;

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
}

/**
 * M2c-5: a statement's PDF or CSV, or an invoice's PDF, read with the caller's session — RLS on `document` and the
 * storage policy of the private bucket decide who may (money staff; the client's members with access to the whole
 * client; an invoice's PDF only when the buyer accepted electronic invoices, CGI 289 VI). The bytes are checked
 * against the SHA-256 recorded when the document was drawn before they are served (CGI 289 V: integrity).
 */
export async function remittanceDocumentResponse(supabase: Supabase, id: string): Promise<Response> {
  if (!UUID.test(id)) return text(404, "Document introuvable.");
  const { data: doc } = await supabase
    .from("document")
    .select("kind, storage_bucket, storage_path, sha256, mime_type, file_name")
    .eq("id", id)
    .maybeSingle();
  if (!doc || !REMITTANCE_KINDS.has(doc.kind)) return text(404, "Document introuvable.");
  const { data: blob, error } = await supabase.storage.from(doc.storage_bucket).download(doc.storage_path);
  if (error || !blob) return text(502, "Le fichier est momentanément indisponible. Réessayez.");
  const bytes = Buffer.from(await blob.arrayBuffer());
  if (createHash("sha256").update(bytes).digest("hex") !== doc.sha256) {
    console.error("remittance document does not match its recorded hash", id);
    return text(500, "Le fichier stocké ne correspond pas au document enregistré.");
  }
  const name = (doc.file_name ?? "document").replace(/["\\\r\n]/g, "_");
  const csv = doc.kind === "remittance_statement_csv";
  return new Response(bytes, {
    headers: {
      "Content-Type": csv ? "text/csv; charset=utf-8" : doc.mime_type,
      "Content-Disposition": `${csv ? "attachment" : "inline"}; filename="${name}"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
