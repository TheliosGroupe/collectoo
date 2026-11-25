"use client";

import { useState } from "react";
import { ActionForm } from "@/components/action-form";
import { buttonClass, inputClass } from "@/components/ui";
import { FULL_CHECK } from "@/lib/payments/remitted";
import { DISPOSITION_KIND } from "@/lib/remittance/declarations";
import {
  coverRemittedReversal,
  recordLiquidationPayoutDisposition,
  recordSetOffOutcome,
  requestFullAdvanceCheck,
} from "./actions";

type Evidence = { id: string; file_name: string | null };

/** M2c-7a « Couvrir » on a remitted_reversal_uncovered row (admins): the sentence says the amount, the client and the
 * date the reversal was recorded, as the row's facts give them (the gap is re-checked in SQL). */
export function CoverReversal({
  reversalId,
  expectedGap,
  prompt,
  idempotencyKey,
}: {
  reversalId: string;
  expectedGap: string;
  prompt: string;
  idempotencyKey: string;
}) {
  return (
    <div className="flex flex-col gap-2" data-testid="cover-reversal">
      <p className="text-sm">{prompt}</p>
      <ActionForm action={coverRemittedReversal} submitLabel="Couvrir" buttonClassName={buttonClass}>
        <input type="hidden" name="idempotency_key" value={idempotencyKey} />
        <input type="hidden" name="reversal_id" value={reversalId} />
        <input type="hidden" name="expected_gap" value={expectedGap} />
      </ActionForm>
    </div>
  );
}

/** M2c-7a « Vérification complète des avances » (admins; plan §3.7 [check 2]): its help, and its toast once asked. */
export function FullAdvanceCheck({ organizationId, idempotencyKey }: { organizationId: string; idempotencyKey: string }) {
  const [asked, setAsked] = useState(false);
  return (
    <div className="flex flex-col gap-2" data-testid="full-advance-check">
      <p className="text-xs text-zinc-600 dark:text-zinc-400">{FULL_CHECK.help}</p>
      <ActionForm
        action={requestFullAdvanceCheck}
        submitLabel={FULL_CHECK.label}
        buttonClassName={buttonClass}
        onDone={() => setAsked(true)}
      >
        <input type="hidden" name="idempotency_key" value={idempotencyKey} />
        <input type="hidden" name="organization_id" value={organizationId} />
      </ActionForm>
      {asked ? (
        <p role="status" className="text-sm font-medium" data-testid="full-advance-check-asked">
          {FULL_CHECK.toast}
        </p>
      ) : null}
    </div>
  );
}

/** The client's status evidences to join (« Justificatif d'événement »), or how to add one. */
function EvidenceField({ evidence }: { evidence: Evidence[] }) {
  return evidence.length === 0 ? (
    <p className="text-sm text-zinc-600 dark:text-zinc-400">
      Joignez d&apos;abord la pièce au client (section « Documents du client », type « Justificatif d&apos;événement »).
    </p>
  ) : (
    <label className="flex flex-col gap-1 text-sm">
      Pièce
      <select name="evidence_document_id" className={inputClass}>
        {evidence.map((d) => (
          <option key={d.id} value={d.id}>
            {d.file_name ?? "justificatif"}
          </option>
        ))}
      </select>
    </label>
  );
}

/** M2c-7d-3 « Enregistrer la suite » on a payout_after_liquidation row whose payout was debited (admins): what became
 * of it, with its evidence and a note (checked in SQL: a payout made to the client after its liquidation, once). */
export function LiquidationPayoutDisposition({
  transferId,
  evidence,
  idempotencyKey,
}: {
  transferId: string;
  evidence: Evidence[];
  idempotencyKey: string;
}) {
  return (
    <details className="rounded-md border border-zinc-200 p-2 dark:border-zinc-800" data-testid="payout-disposition">
      <summary className="cursor-pointer text-sm">Enregistrer la suite</summary>
      <ActionForm
        action={recordLiquidationPayoutDisposition}
        submitLabel="Enregistrer la suite"
        buttonClassName={buttonClass}
        className="mt-2 flex max-w-xl flex-col gap-2"
      >
        <input type="hidden" name="idempotency_key" value={idempotencyKey} />
        <input type="hidden" name="transfer_id" value={transferId} />
        <label className="flex flex-col gap-1 text-sm">
          Suite
          <select name="kind" className={inputClass}>
            {Object.entries(DISPOSITION_KIND).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <EvidenceField evidence={evidence} />
        <label className="flex flex-col gap-1 text-sm">
          Note (facultative)
          <input name="note" maxLength={2000} className={inputClass} />
        </label>
      </ActionForm>
    </details>
  );
}

/** M2c-7d-3 « Compensation maintenue » on a set_off_after_bar row (admins): counsel's answer, its evidence, a note. */
export function SetOffOutcome({
  entryId,
  evidence,
  idempotencyKey,
}: {
  entryId: string;
  evidence: Evidence[];
  idempotencyKey: string;
}) {
  return (
    <details className="rounded-md border border-zinc-200 p-2 dark:border-zinc-800" data-testid="set-off-outcome">
      <summary className="cursor-pointer text-sm">Compensation maintenue (avis de l&apos;avocat)</summary>
      <ActionForm
        action={recordSetOffOutcome}
        submitLabel="Compensation maintenue"
        buttonClassName={buttonClass}
        className="mt-2 flex max-w-xl flex-col gap-2"
      >
        <input type="hidden" name="idempotency_key" value={idempotencyKey} />
        <input type="hidden" name="entry_id" value={entryId} />
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          À enregistrer quand l&apos;avocat conclut que la compensation est maintenue : l&apos;alerte s&apos;arrête.
          Rendre la somme au client ne se fait pas encore dans Collectoo.
        </p>
        <EvidenceField evidence={evidence} />
        <label className="flex flex-col gap-1 text-sm">
          Note (facultative)
          <input name="note" maxLength={2000} className={inputClass} />
        </label>
      </ActionForm>
    </details>
  );
}
