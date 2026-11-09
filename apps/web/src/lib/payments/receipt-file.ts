import { createHash } from "node:crypto";
import type { createClient } from "@/lib/supabase/server";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

type Supabase = Awaited<ReturnType<typeof createClient>>;

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
}

/**
 * M2b-5: the PDF of a receipt version, read with the caller's session — RLS on `receipt` and `document`, and the
 * storage policy of the private bucket, decide who may (money staff, whoever reads the portfolio: clients and
 * collectors their own). The bytes are checked against the SHA-256 recorded at issue before they are served. One
 * small object: well under the API's 8 s.
 */
export async function receiptPdfResponse(supabase: Supabase, id: string): Promise<Response> {
  if (!UUID.test(id)) return text(404, "Quittance introuvable.");
  const { data: receipt } = await supabase
    .from("receipt")
    .select("number, version, pdf_sha256, document_id")
    .eq("id", id)
    .maybeSingle();
  if (!receipt) return text(404, "Quittance introuvable.");
  const { data: doc } = await supabase
    .from("document")
    .select("storage_bucket, storage_path")
    .eq("id", receipt.document_id)
    .maybeSingle();
  if (!doc) return text(404, "Quittance introuvable.");
  const { data: blob, error } = await supabase.storage.from(doc.storage_bucket).download(doc.storage_path);
  if (error || !blob) {
    console.error("receipt download failed", error?.message);
    return text(502, "Le fichier de la quittance est momentanément indisponible. Réessayez.");
  }
  const bytes = Buffer.from(await blob.arrayBuffer());
  if (createHash("sha256").update(bytes).digest("hex") !== receipt.pdf_sha256) {
    console.error("receipt file does not match its recorded hash", id);
    return text(500, "Le fichier stocké ne correspond pas à la quittance enregistrée.");
  }
  return new Response(bytes, {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `inline; filename="${receipt.number}-v${receipt.version}.pdf"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
