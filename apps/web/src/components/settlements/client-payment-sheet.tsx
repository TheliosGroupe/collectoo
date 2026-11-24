"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, useEffect, useRef, useState } from "react";
import { ErrorNote, InfoNote, buttonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { money } from "@/lib/payments/statements";
import { evidenceFileProblem, uploadEvidence } from "@/lib/remittance/evidence";
import {
  type OpenDocuments,
  type PaymentPreview,
  clientPaymentRefusal,
  currentPreview,
  parsePaymentPreview,
  parsePaymentResult,
  paymentEffect,
  previewInputs,
  resultEffect,
  writtenOffChoice,
} from "@/lib/remittance/settlements";
import { createClient } from "@/lib/supabase/browser";

function frenchDay(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

/**
 * M2c-7c-1 (plan §5.2.4, §5.5): « Enregistrer un règlement du client » — the client's transfer received on the
 * servicer's own account, recorded on proof (its evidence uploaded and registered, then public.record_client_payment).
 * [critic] L16: the client designates what it pays (« Oui », with the evidence of its designation and the documents in
 * its order), else the default order applies — ops never choose. The live effect is SQL's plan
 * (public.client_payment_preview); the command compares what it may settle with what the preview showed.
 * (review round 1, TUI-2, CC-1) A preview counts only for the inputs it was computed for (the amount as typed, the
 * value date, the designation): until the one of the current inputs is back, there is no effect and no « Enregistrer
 * le règlement »; a late answer to earlier inputs is dropped. The note once recorded states what the command posted.
 */
export function ClientPaymentSheet({
  servicerId,
  clientId,
  clientName,
  docs,
}: {
  servicerId: string;
  clientId: string;
  clientName: string;
  docs: OpenDocuments;
}) {
  const router = useRouter();
  const attempt = useRef<{ signature: string; ids: string[]; command: string } | null>(null);
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState("");
  const [valueDate, setValueDate] = useState(docs.today);
  const [designated, setDesignated] = useState(false);
  const [named, setNamed] = useState<string[]>([]);
  const [recover, setRecover] = useState<string[]>([]);
  const asked = useRef(0);
  const [stamped, setStamped] = useState<{ inputs: string; preview: PaymentPreview | null } | null>(null);
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  const inputs = previewInputs({ amount, valueDate, designated, named, recover });
  const preview = currentPreview(stamped, inputs);

  useEffect(() => {
    if (!open || amount.trim() === "") return;
    const n = ++asked.current;
    const these = previewInputs({ amount, valueDate, designated, named, recover });
    const timer = setTimeout(async () => {
      const { data } = await createClient().rpc("client_payment_preview", {
        p_client_organization_id: clientId,
        p_currency: docs.currency,
        p_amount_text: amount,
        p_documents: designated && named.length ? named : null,
        p_recover_written_off: designated && recover.length ? recover : null,
        p_on: valueDate,
      } as never);
      if (n !== asked.current) return; // the inputs changed since: a later preview is asked for
      setStamped({ inputs: these, preview: parsePaymentPreview(data) });
    }, 300);
    return () => clearTimeout(timer);
  }, [open, amount, valueDate, designated, named, recover, clientId, docs.currency]);

  function toggle(list: string[], id: string): string[] {
    return list.includes(id) ? list.filter((x) => x !== id) : [...list, id];
  }

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (progress !== null || !preview || preview.refusal || preview.amount_minor === null) return;
    setError(null);
    const data = new FormData(event.currentTarget);
    const evidence = data.get("evidence");
    const designation = data.get("designation");
    const problem = evidenceFileProblem(evidence);
    if (problem) return setError(problem);
    if (designated && evidenceFileProblem(designation))
      return setError("Joignez la pièce où le client désigne ce qu'il règle ; sinon l'ordre par défaut s'applique.");
    const ev = evidence as File;
    const signature = JSON.stringify([amount, valueDate, designated, named, recover, ev.name, ev.size, ev.lastModified]);
    if (attempt.current?.signature !== signature)
      attempt.current = { signature, ids: [crypto.randomUUID(), crypto.randomUUID(), crypto.randomUUID(), crypto.randomUUID()], command: crypto.randomUUID() };
    const [objectId, key, designationObject, designationKey] = attempt.current.ids;
    const supabase = createClient();
    setProgress(`Envoi de ${ev.name}…`);
    const up = await uploadEvidence(supabase, { servicerId, clientId, file: ev, kind: "client_payment_evidence", objectId, key });
    if ("error" in up) {
      setProgress(null);
      return setError(up.error);
    }
    let designationId: string | null = null;
    if (designated) {
      const d = await uploadEvidence(supabase, {
        servicerId,
        clientId,
        file: designation as File,
        kind: "payment_designation_evidence",
        objectId: designationObject,
        key: designationKey,
      });
      if ("error" in d) {
        setProgress(null);
        return setError(d.error);
      }
      designationId = d.id;
    }
    setProgress("Enregistrement du règlement…");
    const { data: posted, error: e } = await supabase.rpc("record_client_payment", {
      p_idempotency_key: attempt.current.command,
      p_client_organization_id: clientId,
      p_currency: docs.currency,
      p_amount_text: amount,
      p_value_date: valueDate,
      p_evidence_document_id: up.id,
      p_documents: designated && named.length ? named : null,
      p_designation_document_id: designationId,
      p_recover_written_off: designated && recover.length ? recover : null,
      p_expected_open_text: preview.open_minor,
      p_reason: String(data.get("reason") ?? "") || null,
    } as never);
    setProgress(null);
    if (e) return setError(clientPaymentRefusal(e.message, (e as { details?: string }).details));
    attempt.current = null;
    const result = parsePaymentResult(posted);
    setDone(result ? `Règlement enregistré : ${resultEffect(result, docs)}.` : "Règlement enregistré.");
    setOpen(false);
    router.refresh();
  }

  const effect = preview
    ? preview.refusal
      ? clientPaymentRefusal(`client payment refused: ${preview.refusal}`, preview.refusal_detail)
      : paymentEffect(preview, docs)
    : amount.trim() === ""
      ? "Indiquez le montant reçu."
      : stamped?.inputs === inputs
        ? "L'effet du règlement n'a pas pu être calculé. Rechargez la page."
        : "Calcul de l'effet du règlement…";
  const docLabel = (id: string): string => {
    const i = docs.invoices.find((x) => x.id === id);
    if (i) return `${i.number} (${money(i.open_minor, docs.currency)})`;
    const a = docs.advances.find((x) => x.id === id);
    return a ? `avance du ${frenchDay(a.born_on)} (${money(a.open_minor, docs.currency)})` : id;
  };

  return (
    <div className="flex flex-col gap-2">
      {done ? (
        <div role="status" aria-live="polite" data-testid="client-payment-done">
          <InfoNote>{done}</InfoNote>
        </div>
      ) : null}
      {!open ? (
        <button
          type="button"
          className={buttonClass}
          onClick={() => setOpen(true)}
          disabled={!docs.own_account}
          data-testid="client-payment-open"
        >
          Enregistrer un règlement
        </button>
      ) : (
        <div
          role="dialog"
          aria-modal="true"
          aria-label="Enregistrer un règlement du client"
          className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center"
        >
          <form
            onSubmit={onSubmit}
            className="flex max-h-full w-full max-w-lg flex-col gap-3 overflow-y-auto rounded-t-xl bg-white p-4 dark:bg-zinc-950 sm:rounded-xl"
            data-testid="client-payment-sheet"
          >
            <h2 className="text-lg font-semibold">Enregistrer un règlement du client</h2>
            <p className="text-sm text-zinc-600 dark:text-zinc-400">
              {clientName} · virement reçu sur le compte propre du cabinet
            </p>
            <label className="flex flex-col gap-1 text-sm">
              Montant reçu (€)
              <input name="amount" value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" required className={inputClass} />
            </label>
            <label className="flex flex-col gap-1 text-sm">
              Date de valeur
              <input type="date" name="value_date" value={valueDate} max={docs.today} onChange={(e) => setValueDate(e.target.value)} required className={inputClass} />
            </label>
            <label className="flex flex-col gap-1 text-sm">
              Preuve du virement
              <input type="file" name="evidence" required accept="application/pdf,image/png,image/jpeg" className={inputClass} />
            </label>
            <fieldset className="flex flex-col gap-2 text-sm">
              <legend className="mb-1">Le client a-t-il désigné ce qu&apos;il règle ?</legend>
              <label className="flex items-center gap-2">
                <input type="radio" name="designated" checked={!designated} onChange={() => setDesignated(false)} />
                Non : ordre par défaut (factures échues, avances, autres factures)
              </label>
              <label className="flex items-center gap-2">
                <input type="radio" name="designated" checked={designated} onChange={() => setDesignated(true)} />
                Oui : documents désignés par le client
              </label>
            </fieldset>
            {designated ? (
              <>
                <label className="flex flex-col gap-1 text-sm">
                  Pièce de la désignation (référence du virement ou courrier)
                  <input type="file" name="designation" required accept="application/pdf,image/png,image/jpeg" className={inputClass} />
                </label>
                <fieldset className="flex flex-col gap-1 text-sm">
                  <legend className="mb-1">Documents, dans l&apos;ordre du client</legend>
                  {[...docs.invoices, ...docs.advances].map((d) => (
                    <label key={d.id} className="flex items-center gap-2">
                      <input type="checkbox" checked={named.includes(d.id)} onChange={() => setNamed(toggle(named, d.id))} />
                      {docLabel(d.id)}
                      {named.includes(d.id) ? ` — n° ${named.indexOf(d.id) + 1}` : ""}
                    </label>
                  ))}
                  {docs.written_off.map((w) => (
                    <label key={w.id} className="flex items-center gap-2">
                      <input type="checkbox" checked={recover.includes(w.id)} onChange={() => setRecover(toggle(recover, w.id))} />
                      {writtenOffChoice(w, docs.currency)}
                    </label>
                  ))}
                </fieldset>
              </>
            ) : null}
            <label className="flex flex-col gap-1 text-sm">
              Motif (interne, facultatif)
              <textarea name="reason" maxLength={2000} rows={2} className={inputClass} />
            </label>
            <p className="text-sm" data-testid="client-payment-effect">
              {effect}
            </p>
            {error ? <ErrorNote>{error}</ErrorNote> : null}
            {progress ? (
              <div role="status" aria-live="polite">
                <InfoNote>{progress}</InfoNote>
              </div>
            ) : null}
            <div className="flex flex-wrap gap-3">
              <button
                type="submit"
                disabled={progress !== null || !preview || preview.refusal !== null || preview.amount_minor === null}
                className={buttonClass}
                data-testid="client-payment-confirm"
              >
                Enregistrer le règlement
              </button>
              <button type="button" className={inlineButtonClass} onClick={() => setOpen(false)}>
                Annuler
              </button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
}
