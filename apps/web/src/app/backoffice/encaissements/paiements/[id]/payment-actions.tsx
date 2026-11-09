"use client";

import { ActionForm } from "@/components/action-form";
import { buttonClass, dangerButtonClass, inputClass } from "@/components/ui";
import { ConfirmSheet, secondaryClass } from "../../a-traiter/queue-actions";
import { allocatePayment, forwardPayment, releaseHold, reverseAllocation, unassignFromPage } from "./actions";

type Doc = { id: string; label: string };

/** Ops' motif: kept for staff, never in what the client reads (the client is given a reason code). */
function Reason({ label = "Motif interne (non transmis au client)" }: { label?: string }) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      {label}
      <input name="reason" required maxLength={2000} className={inputClass} />
    </label>
  );
}

function DocumentChoice({ docs, label, required }: { docs: Doc[]; label: string; required: boolean }) {
  if (docs.length === 0) {
    return (
      <p className="text-sm text-amber-900 dark:text-amber-200">
        Aucun document n&apos;est classé dans ce dossier : ajoutez d&apos;abord la pièce au dossier.
      </p>
    );
  }
  return (
    <label className="flex flex-col gap-1 text-sm">
      {label}
      <select name="evidence_document_id" required={required} defaultValue="" className={inputClass}>
        <option value="" disabled={required}>
          {required ? "Choisir un document" : "Aucun"}
        </option>
        {docs.map((d) => (
          <option key={d.id} value={d.id}>
            {d.label}
          </option>
        ))}
      </select>
    </label>
  );
}

/** « Désimputer » one file's allocation: the entries the page showed, reversed at their date (the effect worded by
 * the file reversed: the payment's own, or another file of the debtor). */
export function ReverseAllocation({
  paymentId,
  accountId,
  fileRef,
  effect,
  entryIds,
  idempotencyKey,
}: {
  paymentId: string;
  accountId: string;
  fileRef: string;
  effect: string;
  entryIds: string[];
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet
      label={`Désimputer (${fileRef})`}
      title="Annuler cette imputation"
      buttonClassName={dangerButtonClass}
      testId="reverse-allocation"
    >
      {() => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            {effect}
          </p>
          <ActionForm action={reverseAllocation} submitLabel="Confirmer l'annulation" buttonClassName={buttonClass}>
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="account_id" value={accountId} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            {entryIds.map((id) => (
              <input key={id} type="hidden" name="entry_id" value={id} />
            ))}
            <Reason />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/** « Imputer »: from the reason the page showed (the sheet says what will happen). */
export function Reallocate({
  paymentId,
  reason,
  effect,
  idempotencyKey,
}: {
  paymentId: string;
  reason: string;
  effect: string;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet label="Imputer" title="Imputer ce paiement" buttonClassName={buttonClass} testId="reallocate">
      {() => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            {effect}
          </p>
          <ActionForm action={allocatePayment} submitLabel="Confirmer" buttonClassName={buttonClass}>
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="expected_reason" value={reason} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <Reason />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/** What is left of the payment, for another file of the same debtor (his written request: founder #8). */
export function UseForOtherFile({
  paymentId,
  reason,
  left,
  files,
  docs,
  idempotencyKey,
}: {
  paymentId: string;
  reason: string;
  left: string;
  files: { account_id: string; external_ref: string }[];
  docs: Doc[];
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet
      label="Imputer le reste sur un autre dossier"
      title="Imputer le reste sur un autre dossier du débiteur"
      buttonClassName={secondaryClass}
      testId="other-file"
    >
      {() => (
        <>
          <p className="text-sm">
            {left} restent sur ce paiement. Ils ne sont jamais reversés au client ; à la demande écrite du débiteur, ils
            peuvent payer un autre de ses dossiers, dans l&apos;ordre légal. Sinon, ils lui seront remboursés.
          </p>
          <ActionForm action={allocatePayment} submitLabel="Confirmer" buttonClassName={buttonClass}>
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="expected_reason" value={reason} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <label className="flex flex-col gap-1 text-sm">
              Dossier du même débiteur
              <select name="account_id" required defaultValue="" className={inputClass}>
                <option value="" disabled>
                  Choisir un dossier
                </option>
                {files.map((f) => (
                  <option key={f.account_id} value={f.account_id}>
                    {f.external_ref}
                  </option>
                ))}
              </select>
            </label>
            <DocumentChoice docs={docs} label="Demande écrite du débiteur" required />
            <Reason />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/** « Lever le blocage »: the judge's authorisation, filed on the file (founder #12). */
export function ReleaseHold({ paymentId, docs, idempotencyKey }: { paymentId: string; docs: Doc[]; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Lever le blocage" title="Imputer malgré la procédure" buttonClassName={secondaryClass} testId="release-hold">
      {() => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            Le dossier reste bloqué (surendettement ou procédure collective). Ce paiement seul sera imputé, sur
            autorisation du juge (art. L722-5 C. conso, L622-7 C. com.), classée dans ce dossier ; s&apos;il attend
            encore une autre décision (paiement antérieur à la reprise, avoir à appliquer), il reviendra ici, cette
            autorisation conservée.
          </p>
          <ActionForm action={releaseHold} submitLabel="Imputer ce paiement" buttonClassName={buttonClass}>
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <DocumentChoice docs={docs} label="Autorisation du juge" required />
            <Reason />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/** « Reverser au client »: a recalled file, or a payment the client's balance already counts (#10). */
export function Forward({
  paymentId,
  left,
  leftMinor,
  client,
  docs,
  idempotencyKey,
}: {
  paymentId: string;
  left: string;
  leftMinor: string;
  client: string;
  docs: Doc[];
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet label="Reverser au client" title="Reverser au client sans imputation" buttonClassName={secondaryClass} testId="forward">
      {() => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            {left} seront dus à {client}, sans toucher à la créance du débiteur. Notification enregistrée pour le client
            (envoi : à venir).
          </p>
          <ActionForm action={forwardPayment} submitLabel="Confirmer le reversement" buttonClassName={buttonClass}>
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="expected_minor" value={leftMinor} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            {docs.length > 0 ? <DocumentChoice docs={docs} label="Pièce (facultative)" required={false} /> : null}
            <Reason />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/** Take the payment off its file (nothing is allocated): back to the queue. */
export function UnassignHere({ paymentId, idempotencyKey }: { paymentId: string; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Désaffecter" title="Désaffecter ce paiement" buttonClassName={dangerButtonClass} testId="unassign">
      {() => (
        <>
          <p className="text-sm">
            Rien n&apos;est imputé : le paiement revient dans la file « à traiter » et ce dossier ne lui sera plus proposé
            automatiquement.
          </p>
          <ActionForm action={unassignFromPage} submitLabel="Confirmer" buttonClassName={buttonClass}>
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <Reason />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}
