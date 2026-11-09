"use client";

import { ActionForm } from "@/components/action-form";
import { buttonClass, inputClass } from "@/components/ui";
import { ConfirmSheet, secondaryClass } from "../../encaissements/a-traiter/queue-actions";
import { recordDirectPayment } from "./actions";

type Doc = { id: string; label: string };
type Item = { id: string; ref: string };

/**
 * « Paiement direct au client » (design §8.1, §9): the debtor paid the client, whose statement (filed on the file) says
 * how much, when and for which invoices. The legal order applies (the invoices named first, interest first inside
 * each); no client money moves through the dedicated account, so no receipt and no notification.
 */
export function RecordDirectPayment({
  accountId,
  items,
  docs,
  today,
  idempotencyKey,
}: {
  accountId: string;
  items: Item[];
  docs: Doc[];
  today: string;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet
      label="Déclarer un paiement direct au client"
      title="Paiement reçu directement par le client"
      buttonClassName={secondaryClass}
      testId="direct-payment"
    >
      {() => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            La créance du dossier diminuera du montant payé, à la date du relevé du client, d&apos;abord sur les factures
            désignées puis dans l&apos;ordre légal (intérêts avant principal). Aucun fonds ne transite par le compte de
            fonds de tiers : pas de quittance de notre part. Un montant supérieur à ce que doit le dossier est refusé.
          </p>
          {docs.length === 0 ? (
            <p className="text-sm text-amber-900 dark:text-amber-200">
              Aucun document n&apos;est classé dans ce dossier : ajoutez d&apos;abord le relevé du client.
            </p>
          ) : (
            <ActionForm action={recordDirectPayment} submitLabel="Enregistrer" buttonClassName={buttonClass}>
              <input type="hidden" name="account_id" value={accountId} />
              <input type="hidden" name="idempotency_key" value={idempotencyKey} />
              <label className="flex flex-col gap-1 text-sm">
                Montant payé au client (€)
                <input name="amount" required inputMode="decimal" className={inputClass} />
              </label>
              <label className="flex flex-col gap-1 text-sm">
                Date du paiement (relevé du client)
                <input name="paid_on" type="date" required max={today} className={inputClass} />
              </label>
              {items.length > 0 ? (
                <fieldset className="flex flex-col gap-1 text-sm">
                  <legend className="mb-1">Factures désignées par le relevé (facultatif)</legend>
                  {items.map((it) => (
                    <label key={it.id} className="flex items-center gap-2">
                      <input type="checkbox" name="item_id" value={it.id} />
                      {it.ref}
                    </label>
                  ))}
                </fieldset>
              ) : null}
              <label className="flex flex-col gap-1 text-sm">
                Relevé du client
                <select name="evidence_document_id" required defaultValue="" className={inputClass}>
                  <option value="" disabled>
                    Choisir un document
                  </option>
                  {docs.map((d) => (
                    <option key={d.id} value={d.id}>
                      {d.label}
                    </option>
                  ))}
                </select>
              </label>
              <label className="flex flex-col gap-1 text-sm">
                Motif (interne)
                <input name="reason" required maxLength={2000} className={inputClass} />
              </label>
            </ActionForm>
          )}
        </>
      )}
    </ConfirmSheet>
  );
}
