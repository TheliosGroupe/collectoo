"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, useRef, useState } from "react";
import { ErrorNote, InfoNote, buttonClass, inputClass } from "@/components/ui";
import { errorText } from "@/lib/boarding/forms";
import { identityErrorCode } from "@/lib/remittance/terms";
import { createClient } from "@/lib/supabase/browser";

const MIME: Readonly<Record<string, string>> = { "application/pdf": "pdf", "image/png": "png", "image/jpeg": "jpg" };

async function sha256Hex(file: File): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * M2c-2: « Joindre un document » of a client (its RIB, its signed mandate or an amendment, the evidence of an event).
 * The file goes to the private bucket at the client's key (the storage policy accepts only that, for money staff), then
 * the document is registered with its SHA-256; the forms of the page then name it. A retry keeps its key.
 */
export function ClientDocumentUpload({ servicerId, clientId }: { servicerId: string; clientId: string }) {
  const router = useRouter();
  const attempt = useRef<{ signature: string; id: string; key: string } | null>(null);
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (progress !== null) return;
    setError(null);
    const form = event.currentTarget;
    const data = new FormData(form);
    const file = data.get("file");
    const kind = String(data.get("kind") ?? "");
    if (!(file instanceof File) || file.size === 0) return setError("Choisissez le fichier.");
    const ext = MIME[file.type];
    if (!ext || file.size > 10 * 1024 * 1024) return setError(errorText("document_invalid"));
    const signature = JSON.stringify([kind, file.name, file.size, file.lastModified]);
    if (attempt.current?.signature !== signature)
      attempt.current = { signature, id: crypto.randomUUID(), key: crypto.randomUUID() };
    const path = `client/${servicerId}/${clientId}/${attempt.current.id}.${ext}`;
    const supabase = createClient();
    setProgress(`Envoi de ${file.name}…`);
    const { error: e1 } = await supabase.storage.from("documents").upload(path, file, { contentType: file.type });
    if (e1 && !/already exists|duplicate/i.test(e1.message)) {
      console.error("client document upload failed", e1.message);
      setProgress(null);
      return setError(errorText("document_not_uploaded"));
    }
    setProgress("Enregistrement…");
    const { error: e2 } = await supabase.rpc("register_client_document", {
      p_idempotency_key: attempt.current.key,
      p_client_organization_id: clientId,
      p_kind: kind,
      p_storage_path: path,
      p_file_name: file.name.replace(/[/\\]/g, "_").slice(0, 255),
      p_sha256: await sha256Hex(file),
      p_mime_type: file.type,
    });
    setProgress(null);
    if (e2) {
      console.error("client document registration failed", e2.message);
      return setError(errorText(identityErrorCode(e2.message)));
    }
    attempt.current = null;
    form.reset();
    router.refresh();
  }

  return (
    <form onSubmit={onSubmit} className="flex max-w-xl flex-col gap-3" data-testid="client-document-upload">
      <label className="flex flex-col gap-1 text-sm">
        Type de document
        <select name="kind" defaultValue="payout_rib" className={inputClass}>
          <option value="payout_rib">RIB du client</option>
          <option value="mandate_document">Mandat signé ou avenant</option>
          <option value="client_status_evidence">Justificatif d&apos;événement (jugement, acte…)</option>
        </select>
      </label>
      <label className="flex flex-col gap-1 text-sm">
        Fichier (PDF, PNG ou JPEG, 10 Mo au plus)
        <input type="file" name="file" required accept="application/pdf,image/png,image/jpeg" className={inputClass} />
      </label>
      {error ? <ErrorNote>{error}</ErrorNote> : null}
      {progress ? (
        <div role="status" aria-live="polite">
          <InfoNote>{progress}</InfoNote>
        </div>
      ) : null}
      <button type="submit" disabled={progress !== null} className={buttonClass}>
        Joindre le document
      </button>
    </form>
  );
}
