"use client";

import { ActionForm } from "@/components/action-form";
import { buttonClass, dangerButtonClass, inputClass } from "@/components/ui";
import { CANCEL_TOP_UP_EFFECT, CANCEL_TOP_UP_FILE_EFFECT, GENERATE_TOP_UP_FILE_EFFECT } from "@/lib/remittance/top-ups";
import { ConfirmSheet, secondaryClass } from "../../encaissements/a-traiter/queue-actions";
import { cancelTopUpFile, cancelTopUpOrder, generateTopUpFile } from "./actions";

/**
 * M2c-7e-1 « Approvisionnements du compte dédié » sheets (plan §7.2, §7.4; the sheet states the effect before the
 * command): the own account's file, its cancellation (before or after download, whatever the switch), and one order's.
 */
export function GenerateTopUpFile({
  accountId,
  orderedCount,
  idempotencyKey,
  label = "Générer le fichier (compte propre)",
}: {
  accountId: string;
  orderedCount: number;
  idempotencyKey: string;
  label?: string;
}) {
  return (
    <ConfirmSheet label={label} title="Générer le fichier du compte propre" buttonClassName={buttonClass} testId="generate-top-up-file">
      {(close) => (
        <>
          <p className="text-sm">
            {orderedCount} approvisionnement{orderedCount > 1 ? "s" : ""} à exécuter. {GENERATE_TOP_UP_FILE_EFFECT}
          </p>
          <ActionForm onDone={close} action={generateTopUpFile} submitLabel="Générer" buttonClassName={buttonClass} testId="generate-top-up-confirm">
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <input type="hidden" name="own_bank_account_id" value={accountId} />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

export function CancelTopUpFile({ fileId, number, idempotencyKey }: { fileId: string; number: string; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Annuler le fichier" title={`Annuler le fichier ${number}`} buttonClassName={secondaryClass} testId="cancel-top-up-file">
      {(close) => (
        <>
          <p className="text-sm" data-testid="cancel-top-up-file-effect">
            {CANCEL_TOP_UP_FILE_EFFECT}
          </p>
          <ActionForm onDone={close} action={cancelTopUpFile} submitLabel="Annuler le fichier" buttonClassName={dangerButtonClass} testId="cancel-top-up-file-confirm">
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <input type="hidden" name="file_id" value={fileId} />
            <label className="flex flex-col gap-1 text-sm">
              Motif (non déposé, refusé par la banque…)
              <input name="reason" required maxLength={2000} className={inputClass} />
            </label>
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

export function CancelTopUpOrder({ transferId, reference, idempotencyKey }: { transferId: string; reference: string; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Annuler" title={`Annuler l'approvisionnement ${reference}`} buttonClassName={secondaryClass} testId="cancel-top-up">
      {(close) => (
        <>
          <p className="text-sm">{CANCEL_TOP_UP_EFFECT}</p>
          <ActionForm onDone={close} action={cancelTopUpOrder} submitLabel="Annuler l'approvisionnement" buttonClassName={dangerButtonClass} testId="cancel-top-up-confirm">
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <input type="hidden" name="transfer_id" value={transferId} />
            <label className="flex flex-col gap-1 text-sm">
              Motif (non exécuté, crédit déjà comptabilisé sans sa référence…)
              <input name="reason" required maxLength={2000} className={inputClass} />
            </label>
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}
