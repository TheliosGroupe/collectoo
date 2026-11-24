import type { createClient } from "@/lib/supabase/browser";

// M2c-7c-1 (plan §5.1): a client's evidence uploaded by money staff — the proof of a client's transfer
// (client_payment_evidence), of the servicer's transfer back (client_refund_evidence), the client's designation of what
// it pays (payment_designation_evidence) — to the private bucket at the client's key, then registered
// (public.register_client_document: read by money staff only). The keys are the caller's (a retry reuses them).

const MIME: Readonly<Record<string, string>> = { "application/pdf": "pdf", "image/png": "png", "image/jpeg": "jpg" };

export type EvidenceKind = "client_payment_evidence" | "client_refund_evidence" | "payment_designation_evidence";

async function sha256Hex(file: File): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** The file's problem in French, or null when it may be uploaded (a PDF, a PNG or a JPEG of 10 MB at most). */
export function evidenceFileProblem(file: unknown): string | null {
  if (!(file instanceof File) || file.size === 0) return "Joignez la pièce.";
  if (!MIME[file.type] || file.size > 10 * 1024 * 1024) return "La pièce doit être un PDF, un PNG ou un JPEG de 10 Mo au plus.";
  return null;
}

/** The evidence uploaded and registered: its document id, or the French reason it failed. */
export async function uploadEvidence(
  supabase: ReturnType<typeof createClient>,
  a: { servicerId: string; clientId: string; file: File; kind: EvidenceKind; objectId: string; key: string },
): Promise<{ id: string } | { error: string }> {
  const path = `client/${a.servicerId}/${a.clientId}/${a.objectId}.${MIME[a.file.type]}`;
  const { error: e1 } = await supabase.storage.from("documents").upload(path, a.file, { contentType: a.file.type });
  if (e1 && !/already exists|duplicate/i.test(e1.message)) return { error: "La pièce n'a pas pu être envoyée. Réessayez." };
  const { data, error: e2 } = await supabase.rpc("register_client_document", {
    p_idempotency_key: a.key,
    p_client_organization_id: a.clientId,
    p_kind: a.kind,
    p_storage_path: path,
    p_file_name: a.file.name.replace(/[/\\]/g, "_").slice(0, 255),
    p_sha256: await sha256Hex(a.file),
    p_mime_type: a.file.type,
  });
  const id = (data as { document_id?: string } | null)?.document_id;
  return e2 || !id ? { error: "La pièce n'a pas pu être enregistrée. Réessayez." } : { id };
}
