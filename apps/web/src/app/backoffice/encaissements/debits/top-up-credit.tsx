"use client";

import { useEffect, useState } from "react";
import { ActionForm } from "@/components/action-form";
import { ErrorNote, buttonClass, inputClass } from "@/components/ui";
import { type TopUpCreditOption, topUpOptionLabel } from "@/lib/remittance/top-ups";
import { ConfirmSheet, secondaryClass } from "../a-traiter/queue-actions";
import { bookTopUpCredit, topUpCreditOptions } from "./actions";

/**
 * M2c-7e-1 « Rattacher à TOP… » ([check 1] gap 12; plan §7.4): a credit from the own account that carries no TOP id
 * (the bank dropped the reference) booked as one of the open top-ups of exactly its amount, read when the sheet opens
 * (public.top_up_credit_options). The motif is required; public.book_top_up_credit re-checks everything under its locks.
 */
export function BookTopUpCredit({ lineId, effect, idempotencyKey }: { lineId: string; effect: string; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Rattacher à TOP…" title="Rattacher à un approvisionnement" buttonClassName={secondaryClass} testId="book-top-up-credit">
      {(close) => <Sheet lineId={lineId} effect={effect} idempotencyKey={idempotencyKey} close={close} />}
    </ConfirmSheet>
  );
}

/**
 * M2c-7e-3 (founder Q15's added question, default a — still open): « C'est cet approvisionnement » on a credit held
 * because its label cites our top-up, still awaited, at exactly its amount, on a statement that gives no sending
 * account — that top-up only (the queue's `label_transfer`, by key), booked by public.book_top_up_credit, which refuses
 * any other top-up (label_reference_transfer), a line that names its sending account, another amount or a top-up no
 * longer awaited. The motif is required.
 */
export function LabelTopUp({
  lineId,
  transferId,
  effect,
  idempotencyKey,
}: {
  lineId: string;
  transferId: string;
  effect: string;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet
      label="C'est cet approvisionnement"
      title="C'est cet approvisionnement"
      buttonClassName={secondaryClass}
      testId="label-reference-top-up"
    >
      {(close) => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            {effect}
          </p>
          <ActionForm onDone={close} action={bookTopUpCredit} submitLabel="Comptabiliser l'approvisionnement" buttonClassName={buttonClass}>
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <input type="hidden" name="bank_transaction_id" value={lineId} />
            <input type="hidden" name="transfer_id" value={transferId} />
            <label className="flex flex-col gap-1 text-sm">
              Motif (ce que montre le relevé ou la banque)
              <input name="reason" required maxLength={2000} className={inputClass} />
            </label>
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

function Sheet({ lineId, effect, idempotencyKey, close }: { lineId: string; effect: string; idempotencyKey: string; close: () => void }) {
  const [state, setState] = useState<{ loaded: false } | { loaded: true; options: TopUpCreditOption[] | null }>({ loaded: false });
  useEffect(() => {
    let live = true;
    topUpCreditOptions(lineId).then((options) => {
      if (live) setState({ loaded: true, options });
    });
    return () => {
      live = false;
    };
  }, [lineId]);
  if (!state.loaded)
    return (
      <p className="text-sm text-zinc-600 dark:text-zinc-400" aria-busy="true">
        Lecture des approvisionnements…
      </p>
    );
  if (!state.options) return <ErrorNote>Les approvisionnements ne peuvent pas être lus pour l&apos;instant : actualisez la page.</ErrorNote>;
  if (state.options.length === 0)
    return (
      <p className="text-sm" data-testid="top-up-credit-none">
        Aucun approvisionnement en attente de ce montant, du compte propre qui a envoyé ce crédit vers ce compte : comptabilisez le
        crédit avec « Approvisionnement par le compte propre ».
      </p>
    );
  return (
    <>
      <p className="text-sm">{effect}</p>
      <ActionForm onDone={close} action={bookTopUpCredit} submitLabel="Rattacher" buttonClassName={buttonClass} testId="book-top-up-credit-confirm">
        <input type="hidden" name="idempotency_key" value={idempotencyKey} />
        <input type="hidden" name="bank_transaction_id" value={lineId} />
        <fieldset className="flex flex-col gap-2 text-sm">
          <legend className="mb-1">Approvisionnement</legend>
          {state.options.map((o, i) => (
            <label key={o.transfer_id} className="flex items-start gap-2" data-testid="top-up-credit-option">
              <input type="radio" name="transfer_id" value={o.transfer_id} defaultChecked={i === 0} required className="mt-1" />
              <span className="break-all">{topUpOptionLabel(o)}</span>
            </label>
          ))}
        </fieldset>
        <label className="flex flex-col gap-1 text-sm">
          Motif (ce que montre le relevé ou la banque)
          <input name="reason" required maxLength={2000} className={inputClass} />
        </label>
      </ActionForm>
    </>
  );
}
