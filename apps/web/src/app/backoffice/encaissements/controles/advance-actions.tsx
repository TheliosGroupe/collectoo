"use client";

import { useState } from "react";
import { ActionForm } from "@/components/action-form";
import { buttonClass } from "@/components/ui";
import { FULL_CHECK } from "@/lib/payments/remitted";
import { coverRemittedReversal, requestFullAdvanceCheck } from "./actions";

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
