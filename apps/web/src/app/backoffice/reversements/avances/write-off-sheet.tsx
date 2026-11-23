"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, useRef, useState } from "react";
import { ErrorNote, InfoNote, buttonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { money } from "@/lib/payments/statements";
import { writeOffEffect, writeOffRefusalOf } from "@/lib/remittance/advances";
import { createClient } from "@/lib/supabase/browser";

const MIME: Readonly<Record<string, string>> = { "application/pdf": "pdf", "image/png": "png", "image/jpeg": "jpg" };
const EUROS = /^\d{1,12}([.,]\d{1,2})?$/;

async function sha256Hex(file: File): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** The euros typed, as minor units text (string digits only, never a float), or null when it is not an amount. */
function typedMinor(text: string): string | null {
  const t = text.replace(/[\s  ]/g, "");
  if (!EUROS.test(t)) return null;
  const [units, cents = ""] = t.split(/[.,]/);
  return String(BigInt(units) * BigInt(100) + BigInt((cents + "00").slice(0, 2)));
}

/** « 1 234,56 » from minor units text (the field's default: the open part the page read). */
function eurosText(minor: string): string {
  const v = BigInt(minor);
  return `${(v / BigInt(100)).toString()},${(v % BigInt(100)).toString().padStart(2, "0")}`;
}

/**
 * M2c-7b (plan §4.1.6, §4.3; founder Q5's default): « Passer une avance en perte », an administrator's, at aal2 (the
 * database checks it). The evidence goes to the private bucket at the client's key and is registered (kind
 * advance_write_off_evidence: read by money staff only), then public.write_off_advance posts the loss with the open
 * part the page showed (compare and set). The sheet states every effect: a loss of the servicer (6780), Collectoo no
 * longer claims the sum, nothing is sent to the client — not a remission of the debt. Irreversible. A retry keeps its
 * keys.
 */
export function WriteOffSheet({
  advanceId,
  servicerId,
  clientId,
  clientName,
  currency,
  openMinor,
}: {
  advanceId: string;
  servicerId: string;
  clientId: string;
  clientName: string;
  currency: string;
  openMinor: string;
}) {
  const router = useRouter();
  const attempt = useRef<{ signature: string; id: string; key: string; command: string } | null>(null);
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState(eurosText(openMinor));
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const minor = typedMinor(amount);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (progress !== null) return;
    setError(null);
    const data = new FormData(event.currentTarget);
    const file = data.get("evidence");
    const reason = String(data.get("reason") ?? "");
    if (!(file instanceof File) || file.size === 0) return setError("Joignez la pièce justificative.");
    const ext = MIME[file.type];
    if (!ext || file.size > 10 * 1024 * 1024) return setError("La pièce doit être un PDF, un PNG ou un JPEG de 10 Mo au plus.");
    const signature = JSON.stringify([amount, reason, file.name, file.size, file.lastModified]);
    if (attempt.current?.signature !== signature)
      attempt.current = { signature, id: crypto.randomUUID(), key: crypto.randomUUID(), command: crypto.randomUUID() };
    const path = `client/${servicerId}/${clientId}/${attempt.current.id}.${ext}`;
    const supabase = createClient();
    setProgress(`Envoi de ${file.name}…`);
    const { error: e1 } = await supabase.storage.from("documents").upload(path, file, { contentType: file.type });
    if (e1 && !/already exists|duplicate/i.test(e1.message)) {
      setProgress(null);
      return setError("La pièce n'a pas pu être envoyée. Réessayez.");
    }
    setProgress("Enregistrement de la pièce…");
    const { data: doc, error: e2 } = await supabase.rpc("register_client_document", {
      p_idempotency_key: attempt.current.key,
      p_client_organization_id: clientId,
      p_kind: "advance_write_off_evidence",
      p_storage_path: path,
      p_file_name: file.name.replace(/[/\\]/g, "_").slice(0, 255),
      p_sha256: await sha256Hex(file),
      p_mime_type: file.type,
    });
    const documentId = (doc as { document_id?: string } | null)?.document_id;
    if (e2 || !documentId) {
      setProgress(null);
      return setError("La pièce n'a pas pu être enregistrée. Réessayez.");
    }
    setProgress("Passage en perte…");
    const { error: e3 } = await supabase.rpc("write_off_advance", {
      p_idempotency_key: attempt.current.command,
      p_advance_id: advanceId,
      p_amount_text: amount,
      p_expected_open_text: openMinor,
      p_reason: reason,
      p_evidence_document_id: documentId,
    });
    setProgress(null);
    // (review round 1, tests-ui-5) in_flight names the run from the refusal's detail (one approved after the page loaded)
    if (e3) return setError(writeOffRefusalOf(e3, { open_minor: openMinor, currency }));
    attempt.current = null;
    setOpen(false);
    router.push(`/backoffice/reversements/avances?perte=${advanceId}`);
    router.refresh();
  }

  if (!open)
    return (
      <button type="button" className={inlineButtonClass} onClick={() => setOpen(true)} data-testid="write-off-open">
        Passer en perte
      </button>
    );
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Passer une avance en perte"
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center"
    >
      <form
        onSubmit={onSubmit}
        className="flex max-h-full w-full max-w-lg flex-col gap-3 overflow-y-auto rounded-t-xl bg-white p-4 dark:bg-zinc-950 sm:rounded-xl"
        data-testid="write-off-sheet"
      >
        <h2 className="text-lg font-semibold">Passer une avance en perte</h2>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          {clientName} · reste à récupérer {money(openMinor, currency)}
        </p>
        <label className="flex flex-col gap-1 text-sm">
          Montant (€)
          <input name="amount" value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" required className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Motif (interne, non transmis au client)
          <textarea name="reason" required maxLength={2000} rows={3} className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Pièce justificative (PDF, PNG ou JPEG, 10 Mo au plus)
          <input type="file" name="evidence" required accept="application/pdf,image/png,image/jpeg" className={inputClass} />
        </label>
        <p className="text-sm" data-testid="write-off-effect">
          {minor ? writeOffEffect(minor, currency) : "Montant invalide (en euros, deux décimales au plus)."}
        </p>
        {error ? <ErrorNote>{error}</ErrorNote> : null}
        {progress ? (
          <div role="status" aria-live="polite">
            <InfoNote>{progress}</InfoNote>
          </div>
        ) : null}
        <div className="flex flex-wrap gap-3">
          <button type="submit" disabled={progress !== null || !minor} className={buttonClass} data-testid="write-off-confirm">
            Passer en perte
          </button>
          <button type="button" className={inlineButtonClass} onClick={() => setOpen(false)}>
            Annuler
          </button>
        </div>
      </form>
    </div>
  );
}
