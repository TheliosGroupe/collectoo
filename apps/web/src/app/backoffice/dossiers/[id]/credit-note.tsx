"use client";

import { ActionForm } from "@/components/action-form";
import { buttonClass } from "@/components/ui";
import { ConfirmSheet } from "../../encaissements/a-traiter/queue-actions";
import { applyCreditNote } from "./actions";

/** One tap applies the credit note the page proposes (the sheet says what will be booked, and why). */
export function ApplyCreditNote({
  accountId,
  proposalKey,
  summary,
  idempotencyKey,
}: {
  accountId: string;
  proposalKey: string;
  summary: string;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet label="Appliquer l'avoir" title="Appliquer l'avoir" buttonClassName={buttonClass} testId="apply-credit-note">
      {() => (
        <>
          <p className="text-sm" data-testid="sheet-effect">
            {summary} La compensation est invoquée pour le client (art. 1347 C. civ.) ; les paiements du dossier qui
            l&apos;attendaient seront ensuite imputés.
          </p>
          <ActionForm action={applyCreditNote} submitLabel="Confirmer" buttonClassName={buttonClass}>
            <input type="hidden" name="account_id" value={accountId} />
            <input type="hidden" name="proposal_key" value={proposalKey} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}
