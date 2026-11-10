"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, useState, useTransition } from "react";
import { ErrorNote, buttonClass, dangerButtonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { errorText } from "@/lib/boarding/forms";
import { type CreditNotePreview, REASON_CATEGORIES, effectLines, vatSplitText } from "@/lib/remittance/credit-notes";
import { issueCreditNote, previewCreditNote } from "../actions";

/**
 * « Émettre un avoir » (M2c-5b; design §14.1, risk R2): the amount HT, the file it is limited to (or the whole invoice,
 * spread in proportion to what each file still charges), the reason category the credit note states and the reason
 * staff keep. « Voir l'effet » shows what the database computes (HT, VAT, TTC, what it takes off what the invoice owes,
 * the refund owed beyond it, what the invoice still owes after); « Émettre l'avoir » issues it against the remaining HT
 * the page read (compare and set). An admin at aal2 only: the page shows the panel to admins, the command refuses
 * anyone else.
 */
export function CreditNotePanel({
  invoiceId,
  invoiceNumber,
  remainingHt,
  files,
  currency,
}: {
  invoiceId: string;
  invoiceNumber: string;
  remainingHt: string;
  files: { account_id: string; reference: string | null; open_ht: string }[];
  currency: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState<CreditNotePreview | null>(null);
  const [issued, setIssued] = useState<string | null>(null);
  const [key, setKey] = useState(() => crypto.randomUUID());
  const lines = effectLines(preview, currency);
  const vat = vatSplitText(preview, currency);

  function onPreview(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending) return;
    const formData = new FormData(event.currentTarget);
    setError(null);
    setIssued(null);
    startTransition(async () => {
      const result = await previewCreditNote(formData);
      if ("error" in result) {
        setPreview(null);
        setError(errorText(result.error));
      } else {
        setPreview(result.preview);
        setKey(crypto.randomUUID());
      }
    });
  }

  function onIssue(form: HTMLFormElement | null) {
    if (pending || !form) return;
    const formData = new FormData(form);
    formData.set("idempotency_key", key);
    formData.set("expected_remaining", remainingHt);
    setError(null);
    startTransition(async () => {
      const result = await issueCreditNote(formData);
      if ("error" in result) setError(errorText(result.error));
      else {
        setIssued(result.number);
        setPreview(null);
        form.reset();
        router.refresh();
      }
    });
  }

  return (
    <form onSubmit={onPreview} className="flex flex-col gap-3" data-testid="credit-note-form" id="credit-note-form">
      <input type="hidden" name="invoice_id" value={invoiceId} />
      <p className="text-sm text-zinc-600 dark:text-zinc-400">
        Un avoir rectifie la facture {invoiceNumber} (une erreur de facturation) : il est numéroté dans la série des
        factures, porte le motif choisi et la TVA au taux de la facture.
      </p>
      <label className="flex flex-col gap-1 text-sm">
        Montant HT de l&apos;avoir (€)
        <input name="amount" inputMode="decimal" className={inputClass} placeholder="ex. 30,00" required onChange={() => setPreview(null)} />
      </label>
      <label className="flex flex-col gap-1 text-sm">
        Sur
        <select name="account_id" className={inputClass} defaultValue="" onChange={() => setPreview(null)}>
          <option value="">Toute la facture (au prorata des dossiers)</option>
          {files.map((f) => (
            <option key={f.account_id} value={f.account_id}>
              Dossier {f.reference ?? f.account_id.slice(0, 8)}
            </option>
          ))}
        </select>
      </label>
      <fieldset className="flex flex-col gap-2 text-sm">
        <legend className="mb-1">Motif porté sur l&apos;avoir</legend>
        {REASON_CATEGORIES.map((c, i) => (
          <label key={c.code} className="flex items-start gap-2">
            <input type="radio" name="reason_code" value={c.code} defaultChecked={i === 0} className="mt-1 h-4 w-4" onChange={() => setPreview(null)} />
            {c.label}
          </label>
        ))}
      </fieldset>
      <label className="flex flex-col gap-1 text-sm">
        Motif détaillé (interne, jamais sur l&apos;avoir)
        <textarea name="reason" className={inputClass} rows={2} required maxLength={2000} onChange={() => setPreview(null)} />
      </label>
      {issued !== null ? (
        <p role="status" className="rounded-md bg-emerald-50 p-3 text-sm text-emerald-900 dark:bg-emerald-950 dark:text-emerald-200" data-testid="credit-note-issued">
          Avoir {issued} émis. Son PDF est en préparation.
        </p>
      ) : null}
      {error ? <ErrorNote>{error}</ErrorNote> : null}
      {lines ? (
        <div className="flex flex-col gap-2 rounded-md border border-amber-300 bg-amber-50 p-3 text-sm dark:border-amber-800 dark:bg-amber-950" data-testid="credit-note-effect">
          <h3 className="font-medium">Effet de l&apos;avoir</h3>
          <dl className="grid grid-cols-[1fr_auto] gap-x-4 gap-y-1">
            {lines.map((l) => (
              <div key={l.label} className="contents">
                <dt>{l.label}</dt>
                <dd className="text-right tabular-nums">{l.value}</dd>
              </div>
            ))}
          </dl>
          {vat ? <p className="text-xs text-zinc-600 dark:text-zinc-400">{vat}</p> : null}
          {preview?.allocations && preview.allocations.length > 1 ? (
            <p className="text-xs text-zinc-600 dark:text-zinc-400">Réparti sur {preview.allocations.length} dossiers.</p>
          ) : null}
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              className={dangerButtonClass}
              disabled={pending}
              aria-busy={pending}
              onClick={(e) => onIssue(e.currentTarget.form)}
              data-testid="credit-note-confirm"
            >
              {pending ? "Patientez…" : "Émettre l'avoir"}
            </button>
            <button type="button" className={inlineButtonClass} onClick={() => setPreview(null)}>
              Modifier
            </button>
          </div>
        </div>
      ) : (
        <button type="submit" className={buttonClass} disabled={pending} aria-busy={pending} data-testid="credit-note-preview">
          {pending ? "Patientez…" : "Voir l'effet"}
        </button>
      )}
    </form>
  );
}
