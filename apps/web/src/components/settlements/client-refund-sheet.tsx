"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, useRef, useState } from "react";
import { ErrorNote, InfoNote, buttonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { minorToEuros } from "@/lib/payments/matching";
import { evidenceFileProblem, uploadEvidence } from "@/lib/remittance/evidence";
import { type CreditCause, clientRefundRefusal, refundHeader } from "@/lib/remittance/settlements";
import { createClient } from "@/lib/supabase/browser";

/**
 * M2c-7c-1 (plan §5.2.6, §5.5): « Enregistrer le remboursement » — what the servicer owes a client back (a credit note
 * on a paid invoice, or a credit from its payment: a surplus) repaid by transfer from the servicer's own account, on
 * proof (public.record_client_refund). The amount defaults to what is owed (SQL's, as text); a part may be refunded.
 * (review round 1, TUI-4) A credit held for the client's procedure is rendered to the procedure (the administrator,
 * mandataire or liquidator named in the evidence: plan §5.2.6), never worded as owed to the client.
 * The command compares what is owed with what the page showed. On success the page reloads with ?remboursement=1
 * (the row itself may be gone: nothing is owed any more). (review round 4) The transfer's date runs from `earliest` —
 * the day what it pays back came into being (a credit's receipt, a credit note's issue), SQL's own floor — to today.
 */
export function ClientRefundSheet({
  servicerId,
  clientId,
  documentId,
  kind,
  cause = null,
  title,
  owedMinor,
  currency,
  today,
  earliest,
}: {
  servicerId: string;
  clientId: string;
  documentId: string;
  kind: "credit_note" | "client_credit";
  cause?: CreditCause | null;
  title: string;
  owedMinor: string;
  currency: string;
  today: string;
  earliest: string;
}) {
  const router = useRouter();
  const attempt = useRef<{ signature: string; objectId: string; key: string; command: string } | null>(null);
  const [open, setOpen] = useState(false);
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (progress !== null) return;
    setError(null);
    const data = new FormData(event.currentTarget);
    const evidence = data.get("evidence");
    const problem = evidenceFileProblem(evidence);
    if (problem) return setError(problem);
    const ev = evidence as File;
    const amount = String(data.get("amount") ?? "");
    const paidOn = String(data.get("paid_on") ?? "");
    const signature = JSON.stringify([amount, paidOn, ev.name, ev.size, ev.lastModified]);
    if (attempt.current?.signature !== signature)
      attempt.current = { signature, objectId: crypto.randomUUID(), key: crypto.randomUUID(), command: crypto.randomUUID() };
    const supabase = createClient();
    setProgress(`Envoi de ${ev.name}…`);
    const up = await uploadEvidence(supabase, {
      servicerId,
      clientId,
      file: ev,
      kind: "client_refund_evidence",
      objectId: attempt.current.objectId,
      key: attempt.current.key,
    });
    if ("error" in up) {
      setProgress(null);
      return setError(up.error);
    }
    setProgress("Enregistrement du remboursement…");
    const { error: e } = await supabase.rpc("record_client_refund", {
      p_idempotency_key: attempt.current.command,
      p_document_id: documentId,
      p_amount_text: amount,
      p_paid_on: paidOn,
      p_evidence_document_id: up.id,
      p_expected_owed_text: owedMinor,
      p_reason: String(data.get("reason") ?? "") || null,
    } as never);
    if (e) {
      setProgress(null);
      return setError(
        clientRefundRefusal(e.message, { owed_minor: owedMinor, currency, kind, cause }, (e as { details?: string }).details),
      );
    }
    attempt.current = null;
    setOpen(false);
    setProgress(null);
    router.replace(`${window.location.pathname}?remboursement=1`);
  }

  if (!open)
    return (
      <button type="button" className={inlineButtonClass} onClick={() => setOpen(true)} data-testid="client-refund-open">
        Enregistrer le remboursement
      </button>
    );
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Enregistrer le remboursement"
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center"
    >
      <form
        onSubmit={onSubmit}
        className="flex max-h-full w-full max-w-lg flex-col gap-3 overflow-y-auto rounded-t-xl bg-white p-4 dark:bg-zinc-950 sm:rounded-xl"
        data-testid="client-refund-sheet"
      >
        <h2 className="text-lg font-semibold">Enregistrer le remboursement</h2>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          {refundHeader({ title, owed_minor: owedMinor, currency, cause: kind === "client_credit" ? cause : null })}
        </p>
        <label className="flex flex-col gap-1 text-sm">
          Montant remboursé (€)
          <input name="amount" defaultValue={minorToEuros(BigInt(owedMinor))} inputMode="decimal" required className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Date du virement
          <input type="date" name="paid_on" defaultValue={today} min={earliest} max={today} required className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Preuve
          <input type="file" name="evidence" required accept="application/pdf,image/png,image/jpeg" className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Motif (interne, facultatif)
          <textarea name="reason" maxLength={2000} rows={2} className={inputClass} />
        </label>
        {error ? <ErrorNote>{error}</ErrorNote> : null}
        {progress ? (
          <div role="status" aria-live="polite">
            <InfoNote>{progress}</InfoNote>
          </div>
        ) : null}
        <div className="flex flex-wrap gap-3">
          <button type="submit" disabled={progress !== null} className={buttonClass} data-testid="client-refund-confirm">
            Enregistrer le remboursement
          </button>
          <button type="button" className={inlineButtonClass} onClick={() => setOpen(false)}>
            Annuler
          </button>
        </div>
      </form>
    </div>
  );
}
