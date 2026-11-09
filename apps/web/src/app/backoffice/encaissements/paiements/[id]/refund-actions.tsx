"use client";

import { useState } from "react";
import { ActionForm } from "@/components/action-form";
import { buttonClass, dangerButtonClass, inputClass } from "@/components/ui";
import { REFUND_REASON } from "@/lib/payments/debits";
import { ConfirmSheet, secondaryClass } from "../../a-traiter/queue-actions";
import { cancelRefund, requestRefund } from "./actions";

/**
 * « Rembourser » (founder #8 overpayment, #9 other currency, #11 rolled-back batch, #12 held file; C. civ. 1302-1:
 * « … doit le restituer à celui de qui il l'a indûment reçu »): to the payer's IBAN by default. The sheet says what
 * happens: nothing is booked until the bank's debit, carrying our RFD reference, appears on a statement.
 */
export function RequestRefund({
  paymentId,
  left,
  leftInput,
  leftMinor,
  reviewReason,
  reasons,
  payerName,
  payerIbanEnd,
  payerIbanValid,
  idempotencyKey,
}: {
  paymentId: string;
  left: string;
  leftInput: string;
  leftMinor: string;
  reviewReason: string | null;
  reasons: string[];
  payerName: string | null;
  payerIbanEnd: string | null;
  payerIbanValid: boolean;
  idempotencyKey: string;
}) {
  const [payee, setPayee] = useState(payerIbanValid ? "payer" : "other");
  // the bank may send the payer's IBAN without a name: request_refund needs one (its own, or the payer's)
  const payerNamed = (payerName ?? "").trim() !== "";
  return (
    <ConfirmSheet label="Rembourser" title="Rembourser le payeur" buttonClassName={secondaryClass} testId="request-refund">
      {(close) => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            {left} restent sur ce paiement. La demande crée une référence « RFD… » : dans la banque, saisissez-la comme
            « référence de bout en bout » du virement (pas seulement dans le libellé), c&apos;est elle qui fait reconnaître
            son débit sur le relevé. Le remboursement est comptabilisé quand ce débit apparaît sur le relevé du compte
            de fonds de tiers ; jamais plus que ce qui reste du paiement.
          </p>
          <ActionForm onDone={close} action={requestRefund} submitLabel="Demander le remboursement" buttonClassName={buttonClass}>
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="expected_left_minor" value={leftMinor} />
            <input type="hidden" name="expected_review_reason" value={reviewReason ?? ""} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <label className="flex flex-col gap-1 text-sm">
              Montant à rembourser (€)
              <input name="amount" required defaultValue={leftInput} inputMode="decimal" className={inputClass} />
            </label>
            <fieldset className="flex flex-col gap-2 text-sm">
              <legend className="mb-1">Bénéficiaire</legend>
              {payerIbanValid ? (
                <label className="flex items-center gap-2">
                  <input
                    type="radio"
                    name="payee"
                    value="payer"
                    checked={payee === "payer"}
                    onChange={() => setPayee("payer")}
                  />
                  Le payeur ({payerNamed ? payerName : "nom non transmis"}, IBAN …{payerIbanEnd})
                </label>
              ) : (
                <p className="text-amber-900 dark:text-amber-200">La banque n&apos;a pas transmis d&apos;IBAN utilisable du payeur.</p>
              )}
              <label className="flex items-center gap-2">
                <input type="radio" name="payee" value="other" checked={payee === "other"} onChange={() => setPayee("other")} />
                Un autre compte du payeur (sur sa demande)
              </label>
              {payee === "other" ? (
                <>
                  <label className="flex flex-col gap-1">
                    IBAN du bénéficiaire
                    <input name="payee_iban" required autoComplete="off" className={inputClass} />
                  </label>
                  <label className="flex flex-col gap-1">
                    Nom du bénéficiaire
                    <input name="payee_name" required={!payerNamed} maxLength={140} defaultValue={payerName ?? ""} className={inputClass} />
                  </label>
                </>
              ) : !payerNamed ? (
                <label className="flex flex-col gap-1">
                  Nom du bénéficiaire (la banque ne l&apos;a pas transmis)
                  <input name="payee_name" required maxLength={140} autoComplete="off" className={inputClass} />
                </label>
              ) : null}
            </fieldset>
            <label className="flex flex-col gap-1 text-sm">
              Motif du remboursement
              <select name="reason_code" required defaultValue={reasons[0] ?? "other"} className={inputClass}>
                {reasons.map((r) => (
                  <option key={r} value={r}>
                    {REFUND_REASON[r]?.label ?? r}
                  </option>
                ))}
              </select>
            </label>
            <label className="flex flex-col gap-1 text-sm">
              Précisions (internes)
              <input name="reason" required maxLength={2000} className={inputClass} />
            </label>
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/** « Annuler le remboursement »: before its debit appears (the transfer was not made). */
export function CancelRefund({
  paymentId,
  refundId,
  reference,
  idempotencyKey,
}: {
  paymentId: string;
  refundId: string;
  reference: string;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet label="Annuler" title="Annuler ce remboursement" buttonClassName={dangerButtonClass} testId="cancel-refund">
      {(close) => (
        <>
          <p className="text-sm">
            Confirmez que le virement {reference} n&apos;a pas été exécuté dans la banque. Le paiement retrouvera la
            situation qu&apos;il avait avant la demande.
          </p>
          <ActionForm onDone={close} action={cancelRefund} submitLabel="Confirmer l'annulation" buttonClassName={buttonClass}>
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="refund_request_id" value={refundId} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <label className="flex flex-col gap-1 text-sm">
              Motif (interne)
              <input name="reason" required maxLength={2000} className={inputClass} />
            </label>
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}
