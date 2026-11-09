"use client";

import { ActionForm } from "@/components/action-form";
import { buttonClass, dangerButtonClass, inputClass } from "@/components/ui";
import { ConfirmSheet, secondaryClass } from "../a-traiter/queue-actions";
import { linkDebit, resolveDuplicate } from "./actions";

function Reason({ label = "Motif (interne)" }: { label?: string }) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      {label}
      <input name="reason" required maxLength={2000} className={inputClass} />
    </label>
  );
}

/** « Lier au paiement »: the return of a payment (the effect said before anything is sent). */
export function LinkReturn({
  lineId,
  paymentId,
  leftMinor,
  primary,
  label,
  effect,
  idempotencyKey,
}: {
  lineId: string;
  paymentId: string;
  leftMinor: string;
  /** a payment the line's references name (else a payment of the same account ops may choose) */
  primary: boolean;
  label: string;
  effect: string;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet
      label={label}
      title="Retour d'un paiement"
      buttonClassName={primary ? buttonClass : secondaryClass}
      testId="link-return"
    >
      {(close) => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            {effect}
          </p>
          <ActionForm onDone={close} action={linkDebit} submitLabel="Confirmer le retour" buttonClassName={buttonClass}>
            <input type="hidden" name="bank_transaction_id" value={lineId} />
            <input type="hidden" name="kind" value="return" />
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="expected_left_minor" value={leftMinor} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <Reason />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/** « Lier au remboursement »: our refund executed (a debit), or our refund come back unpaid (a credit). */
export function LinkRefund({
  lineId,
  refundId,
  kind,
  label,
  effect,
  idempotencyKey,
}: {
  lineId: string;
  refundId: string;
  kind: "refund" | "refund_returned";
  label: string;
  effect: string;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet label={label} title="Remboursement" buttonClassName={buttonClass} testId="link-refund">
      {(close) => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            {effect}
          </p>
          <ActionForm onDone={close} action={linkDebit} submitLabel="Confirmer" buttonClassName={buttonClass}>
            <input type="hidden" name="bank_transaction_id" value={lineId} />
            <input type="hidden" name="kind" value={kind} />
            <input type="hidden" name="refund_request_id" value={refundId} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <Reason />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/** « Classer sans comptabiliser » (founder #20: fees and the like are not booked in M2b): the motif is kept. */
export function Explain({ lineId, idempotencyKey }: { lineId: string; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Classer sans comptabiliser" title="Classer sans comptabiliser" buttonClassName={secondaryClass} testId="explain">
      {(close) => (
        <>
          <p className="text-sm">
            La ligne restera hors comptabilité (écart expliqué avec le solde bancaire) : à réserver aux frais repris, aux
            corrections de la banque, aux mouvements qui ne concernent aucun paiement reçu.
          </p>
          <ActionForm onDone={close} action={linkDebit} submitLabel="Classer" buttonClassName={buttonClass}>
            <input type="hidden" name="bank_transaction_id" value={lineId} />
            <input type="hidden" name="kind" value="explained" />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <Reason label="Explication (interne)" />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/** A CSV line held as a suspected duplicate: released (booked as what it is) or confirmed (never booked). */
export function ResolveDuplicate({
  lineId,
  releaseEffect,
  idempotencyKey,
}: {
  lineId: string;
  releaseEffect: string;
  idempotencyKey: string;
}) {
  return (
    <div className="flex flex-wrap gap-2">
      <ConfirmSheet label="Libérer" title="Ce n'est pas un doublon" buttonClassName={buttonClass} testId="release-duplicate">
        {(close) => (
          <>
            <p className="text-sm" data-testid="sheet-effect">
              {releaseEffect}
            </p>
            <ActionForm onDone={close} action={resolveDuplicate} submitLabel="Libérer la ligne" buttonClassName={buttonClass}>
              <input type="hidden" name="bank_transaction_id" value={lineId} />
              <input type="hidden" name="decision" value="release" />
              <input type="hidden" name="idempotency_key" value={idempotencyKey} />
              <Reason />
            </ActionForm>
          </>
        )}
      </ConfirmSheet>
      <ConfirmSheet label="Doublon confirmé" title="Confirmer le doublon" buttonClassName={dangerButtonClass} testId="confirm-duplicate">
        {(close) => (
          <>
            <p className="text-sm">
              La ligne est la même opération qu&apos;une ligne déjà importée : elle ne sera jamais comptabilisée.
            </p>
            <ActionForm onDone={close} action={resolveDuplicate} submitLabel="Confirmer le doublon" buttonClassName={buttonClass}>
              <input type="hidden" name="bank_transaction_id" value={lineId} />
              <input type="hidden" name="decision" value="duplicate" />
              <input type="hidden" name="idempotency_key" value={idempotencyKey} />
              <Reason />
            </ActionForm>
          </>
        )}
      </ConfirmSheet>
    </div>
  );
}
