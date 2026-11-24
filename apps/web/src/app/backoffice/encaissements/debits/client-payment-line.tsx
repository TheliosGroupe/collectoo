"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, useRef, useState } from "react";
import { ErrorNote, InfoNote, buttonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { money } from "@/lib/payments/statements";
import {
  type OpenDocuments,
  type PaymentPreview,
  clientPaymentRefusal,
  dedicatedLineEffect,
  designationSentence,
  parseOpenDocuments,
  parsePaymentPreview,
  parsePaymentResult,
  paymentEffect,
  resultEffect,
} from "@/lib/remittance/settlements";
import { createClient } from "@/lib/supabase/browser";
import { secondaryClass } from "../a-traiter/queue-actions";

type LineFacts = {
  client_id: string | null;
  client_name: string | null;
  currency: string;
  amount_minor: string;
  booking_date: string;
  label: string | null;
  named_documents: string[];
  refusal: string | null;
  preview: unknown;
};

function frenchDay(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

/**
 * M2c-7c-1 (plan §5.2.5, §5.5): « Règlement d'une facture ou d'une avance du cabinet » on a credit of the dedicated account
 * from a client's confirmed payout IBAN — the client paying the servicer there. The client, what its label designates
 * ([critic] L16: the invoices whose number it names) and the payment's effect are SQL's (public.client_payment_line,
 * public.client_open_documents), read on open; public.book_client_payment_line books it (« Règlement du client »): the
 * servicer's share on 4679 grows by it and the next file sweeps it to the own account. The sheet stays open on its
 * result; the list reloads when it closes. (review round 1, TUI-3, TUI-7) What the label designates and where the money
 * goes are worded from SQL's plan (a pre-opening invoice is never « imputé »; a credit held back is never « au
 * cabinet »); its refusals never offer to record without the label's designation; the note states what was posted.
 */
export function ClientPaymentLine({ lineId }: { lineId: string }) {
  const router = useRouter();
  const key = useRef<string | null>(null);
  const [open, setOpen] = useState(false);
  const [facts, setFacts] = useState<LineFacts | null>(null);
  const [docs, setDocs] = useState<OpenDocuments | null>(null);
  const [preview, setPreview] = useState<PaymentPreview | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  async function onOpen() {
    setOpen(true);
    setError(null);
    setDone(null);
    key.current = crypto.randomUUID();
    const supabase = createClient();
    const { data, error: e } = await supabase.rpc("client_payment_line", { p_bank_transaction_id: lineId } as never);
    if (e || !data) return setError(clientPaymentRefusal(e?.message ?? "", null, "line"));
    let f = data as unknown as LineFacts;
    if (f.refusal || !f.client_id) {
      setFacts(f);
      return setError(clientPaymentRefusal(`client payment refused: ${f.refusal ?? "not_a_client_credit"}`, null, "line"));
    }
    if (f.named_documents.length > 0) {
      const again = await supabase.rpc("client_payment_line", {
        p_bank_transaction_id: lineId,
        p_documents: f.named_documents,
      } as never);
      if (again.data) f = again.data as unknown as LineFacts;
    }
    const o = await supabase.rpc("client_open_documents", { p_client_organization_id: f.client_id, p_currency: f.currency } as never);
    setFacts(f);
    setDocs(parseOpenDocuments(o.data));
    setPreview(parsePaymentPreview(f.preview));
  }

  function onClose() {
    setOpen(false);
    if (done) router.refresh();
  }

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy || !facts || !preview || preview.refusal || !docs) return;
    setError(null);
    const reason = String(new FormData(event.currentTarget).get("reason") ?? "").trim();
    if (!reason) return setError(clientPaymentRefusal("client payment refused: reason_required", null, "line"));
    setBusy(true);
    const { data: posted, error: e } = await createClient().rpc("book_client_payment_line", {
      p_idempotency_key: key.current,
      p_bank_transaction_id: lineId,
      p_documents: facts.named_documents.length ? facts.named_documents : null,
      p_designation_document_id: null,
      p_recover_written_off: null,
      p_expected_open_text: preview.open_minor,
      p_reason: reason,
    } as never);
    setBusy(false);
    if (e) return setError(clientPaymentRefusal(e.message, (e as { details?: string }).details, "line"));
    const result = parsePaymentResult(posted);
    setDone(result ? `Règlement du client enregistré : ${resultEffect(result, docs)}.` : "Règlement du client enregistré.");
  }

  const named = facts && docs ? designationSentence(facts.named_documents, preview, docs) : null;
  const effect =
    preview && docs
      ? preview.refusal
        ? clientPaymentRefusal(`client payment refused: ${preview.refusal}`, preview.refusal_detail, "line")
        : paymentEffect(preview, docs)
      : null;

  return (
    <>
      <button type="button" className={secondaryClass} onClick={onOpen} data-testid="client-payment-line-open">
        Règlement d&apos;une facture ou d&apos;une avance du cabinet
      </button>
      {open ? (
        <div
          role="dialog"
          aria-modal="true"
          aria-label="Règlement d'une facture ou d'une avance du cabinet"
          className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center"
        >
          <form
            onSubmit={onSubmit}
            className="flex max-h-full w-full max-w-lg flex-col gap-3 overflow-y-auto rounded-t-xl bg-white p-4 dark:bg-zinc-950 sm:rounded-xl"
            data-testid="client-payment-line-sheet"
          >
            <h2 className="text-lg font-semibold">Règlement d&apos;une facture ou d&apos;une avance du cabinet</h2>
            {facts && facts.client_id ? (
              <p className="text-sm">
                {facts.client_name} · {money(facts.amount_minor, facts.currency)} reçus le {frenchDay(facts.booking_date)} sur
                le compte de reversement
                {facts.label ? ` · « ${facts.label} »` : ""}
              </p>
            ) : null}
            {named ? (
              <p className="text-sm">{named}</p>
            ) : facts && facts.client_id ? (
              <p className="text-sm">
                Le libellé ne désigne aucune facture : ordre par défaut (factures échues, avances, autres factures).
              </p>
            ) : null}
            {effect ? (
              <p className="text-sm" data-testid="client-payment-effect">
                {effect}
              </p>
            ) : null}
            {facts && facts.client_id ? <p className="text-sm">{dedicatedLineEffect(preview, facts.currency)}</p> : null}
            {done ? (
              <div role="status" aria-live="polite" data-testid="client-payment-line-done">
                <InfoNote>{done}</InfoNote>
              </div>
            ) : facts && facts.client_id ? (
              <label className="flex flex-col gap-1 text-sm">
                Motif
                <textarea name="reason" required maxLength={2000} rows={2} className={inputClass} />
              </label>
            ) : null}
            {error ? <ErrorNote>{error}</ErrorNote> : null}
            <div className="flex flex-wrap gap-3">
              {!done ? (
                <button
                  type="submit"
                  disabled={busy || !preview || preview.refusal !== null || !docs}
                  className={buttonClass}
                  data-testid="client-payment-line-confirm"
                >
                  {busy ? "Enregistrement…" : "Comptabiliser le règlement"}
                </button>
              ) : null}
              <button type="button" className={inlineButtonClass} onClick={onClose}>
                {done ? "Fermer" : "Annuler"}
              </button>
            </div>
          </form>
        </div>
      ) : null}
    </>
  );
}
