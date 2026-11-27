"use client";

import { useRouter } from "next/navigation";
import { type FormEvent, useEffect, useState, useTransition } from "react";
import { ErrorNote, buttonClass, inputClass } from "@/components/ui";
import { money } from "@/lib/payments/statements";
import {
  type TransferLineOptions,
  type TransferLinePreview,
  type TransferLineProposal,
  memberInLine,
  membersMore,
  pendingLineNote,
  transferLineActionLabel,
  transferLineButton,
  transferLineEffects,
  transferLineRefusalText,
} from "@/lib/payments/transfer-lines";
import { ConfirmSheet, secondaryClass } from "../a-traiter/queue-actions";
import { bookTransferLine, previewTransferLine, transferLineOptions } from "./actions";

const MOTIF = "Motif (ce que montre le relevé ou la banque)";

/**
 * M2c-6b-2c « Comptabiliser… » (plan §7.3; critic CSO-4, F6, F8): offered on a line of « À classer » from the queue's
 * cheap `bookable_as`; the line's options are read only when its sheet opens (public.transfer_line_options), each
 * proposal with its effects worded from the preview the database returned. An entry kept unsplit is checked again
 * (« Vérifier », public.transfer_line_preview) before it is booked. The motif is required; the parts and the preview's
 * text go back to the command as the database gave them, which refuses if anything changed in between.
 */
export function BookTransferLine({
  lineId,
  currency,
  idempotencyKey,
  labelReference = false,
}: {
  lineId: string;
  currency: string;
  idempotencyKey: string;
  /** M2c-7e-3 (plan §7.3 exit (a), §7.4): « Oui, c'est son retour » on a credit whose label cites our payout or sweep —
   * the same sheet, its options class L (the cited transfer's return at exactly its amount, or the refusal) */
  labelReference?: boolean;
}) {
  return (
    <ConfirmSheet
      label={labelReference ? "Oui, c'est son retour" : "Comptabiliser…"}
      title={labelReference ? "Retour du virement cité" : "Comptabiliser depuis le relevé"}
      buttonClassName={secondaryClass}
      testId={labelReference ? "label-reference-return" : "book-transfer-line"}
    >
      {(close) => <Sheet lineId={lineId} currency={currency} idempotencyKey={idempotencyKey} close={close} />}
    </ConfirmSheet>
  );
}

function Sheet({
  lineId,
  currency,
  idempotencyKey,
  close,
}: {
  lineId: string;
  currency: string;
  idempotencyKey: string;
  close: () => void;
}) {
  const [state, setState] = useState<{ loaded: false } | { loaded: true; options: TransferLineOptions | null }>({
    loaded: false,
  });
  useEffect(() => {
    let live = true;
    transferLineOptions(lineId).then((options) => {
      if (live) setState({ loaded: true, options });
    });
    return () => {
      live = false;
    };
  }, [lineId]);
  if (!state.loaded)
    return (
      <p className="text-sm text-zinc-600 dark:text-zinc-400" aria-busy="true">
        Lecture de la ligne…
      </p>
    );
  const o = state.options;
  if (!o) return <ErrorNote>Cette ligne ne peut pas être lue pour l&apos;instant : actualisez la page.</ErrorNote>;
  // review 6b-2c (pages-5): the pending debit's tab (« Doublons possibles » when it is held), the sheet closed on the way
  const pending = pendingLineNote(o);
  return (
    <div className="flex flex-col gap-4">
      {o.refusal ? (
        <p className="text-sm text-amber-900 dark:text-amber-200" data-testid="transfer-line-refusal">
          {transferLineRefusalText(o.refusal, o.refusal_detail)}
          {pending ? (
            <>
              {pending.text ? ` ${pending.text}` : null}{" "}
              <a href={pending.href} onClick={close} className="underline underline-offset-4">
                {pending.label}
              </a>
            </>
          ) : null}
        </p>
      ) : null}
      {o.proposals.length === 0 && !o.refusal ? (
        <p className="text-sm">Collectoo ne trouve rien à comptabiliser pour cette ligne : demandez le détail à la banque.</p>
      ) : null}
      {/* review M2c-6b-2d round 1 (pages-e2e-5): the lot's members before the proposals — ops see which member the
          line does not debit before they reach « Comptabiliser » */}
      {o.members ? <Members options={o} currency={currency} /> : null}
      {o.proposals.map((p, i) => (
        <Proposal
          key={`${p.action}-${i}`}
          lineId={lineId}
          options={o}
          proposal={p}
          currency={currency}
          idempotencyKey={idempotencyKey}
          close={close}
        />
      ))}
    </div>
  );
}

// the members' columns (plan §7.3: Reversement, Client, Référence, Montant, Dans cette ligne): two rows on a phone (the
// run and its amount, then the reference and what the line does of it), one aligned row from `sm` up
const MEMBER_COLS =
  "grid-cols-[minmax(0,1fr)_auto] gap-x-3 sm:grid-cols-[minmax(0,2fr)_minmax(0,1.4fr)_7rem_minmax(0,1.6fr)]";

/**
 * A lot's members (at most 50 listed, the rest counted) and what this line does of each (critic F6, critic2 CSO2-3).
 * Review M2c-6b-2d round 1 (pages-e2e-5): fixed columns, the amounts right-aligned, with each member's end-to-end
 * reference.
 */
function Members({ options, currency }: { options: TransferLineOptions; currency: string }) {
  const parts = options.proposals[0]?.parts ?? [];
  const more = membersMore(options);
  // review 6b-2c (pages-3): a credit returns its members; a lot no booking is proposed for holds the bank's to confirm
  const line = { direction: options.direction, decided: options.proposals.length > 0 && !options.refusal };
  return (
    <div className="flex flex-col gap-1 text-sm" data-testid="transfer-line-members">
      <p className="font-medium">Virements du lot</p>
      <div className={`hidden ${MEMBER_COLS} text-xs text-zinc-600 sm:grid dark:text-zinc-400`} aria-hidden="true">
        <span>Reversement</span>
        <span>Référence</span>
        <span className="text-right">Montant</span>
        <span>Dans cette ligne</span>
      </div>
      <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
        {(options.members ?? []).map((m) => (
          <li key={m.transfer_id} className={`grid ${MEMBER_COLS} gap-y-0.5 py-1`}>
            <span className="order-1 min-w-0 break-words sm:order-none">
              {m.run_number ?? "Virement"}
              {m.client_name ? ` (${m.client_name})` : ""}
            </span>
            <span className="order-3 col-span-2 min-w-0 break-all text-zinc-600 sm:order-none sm:col-span-1 dark:text-zinc-400">
              <span className="sm:sr-only">Référence : </span>
              {m.end_to_end_id ?? "—"}
            </span>
            <span className="order-2 text-right tabular-nums sm:order-none">
              {m.amount_minor ? money(m.amount_minor, currency) : ""}
            </span>
            <span className="order-4 col-span-2 text-zinc-600 sm:order-none sm:col-span-1 dark:text-zinc-400">
              <span className="sm:sr-only">Dans cette ligne : </span>
              {memberInLine(m, parts, line)}
            </span>
          </li>
        ))}
      </ul>
      {more ? <p className="text-zinc-600 dark:text-zinc-400">{more}</p> : null}
    </div>
  );
}

function Proposal({
  lineId,
  options,
  proposal,
  currency,
  idempotencyKey,
  close,
}: {
  lineId: string;
  options: TransferLineOptions;
  proposal: TransferLineProposal;
  currency: string;
  idempotencyKey: string;
  close: () => void;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  // an entry kept unsplit is checked again before it is booked (« Vérifier », critic F8)
  const unsplit = options.class === "U";
  const [checked, setChecked] = useState<TransferLinePreview | null>(unsplit ? null : proposal.preview);
  const preview = checked ?? proposal.preview;
  const shown: TransferLineProposal = { ...proposal, preview };

  function verify() {
    setError(null);
    startTransition(async () => {
      const r = await previewTransferLine(lineId, proposal.request);
      if ("preview" in r) setChecked(r.preview);
      else setError(transferLineRefusalText(r.refusal, r.detail));
    });
  }
  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending) return;
    const formData = new FormData(event.currentTarget);
    setError(null);
    startTransition(async () => {
      const r = await bookTransferLine(formData);
      if ("refusal" in r) setError(transferLineRefusalText(r.refusal, r.detail));
      else {
        close();
        router.refresh();
      }
    });
  }

  return (
    <section className="flex flex-col gap-2 rounded-lg border border-zinc-200 p-3 dark:border-zinc-800" data-testid="transfer-line-proposal">
      <h4 className="font-medium">{transferLineActionLabel(proposal.action, options.class, proposal.parts)}</h4>
      <ul className="flex list-disc flex-col gap-1 pl-5 text-sm" data-testid="transfer-line-effects">
        {transferLineEffects(options, shown, currency).map((s) => (
          <li key={s}>{s}</li>
        ))}
      </ul>
      {!preview.ok && preview.why ? (
        <p className="text-sm text-amber-900 dark:text-amber-200" data-testid="transfer-line-refusal">
          {transferLineRefusalText(preview.why, preview.detail)}
        </p>
      ) : null}
      {unsplit && checked === null ? (
        <>
          {error ? <ErrorNote>{error}</ErrorNote> : null}
          <button type="button" className={buttonClass} disabled={pending} aria-busy={pending} onClick={verify}>
            {pending ? "Patientez…" : "Vérifier"}
          </button>
        </>
      ) : preview.ok && preview.expected_text ? (
        <form onSubmit={onSubmit} className="flex flex-col gap-2">
          <input type="hidden" name="idempotency_key" value={idempotencyKey} />
          <input type="hidden" name="bank_transaction_id" value={lineId} />
          <input type="hidden" name="parts" value={JSON.stringify(proposal.request)} />
          <input type="hidden" name="expected_text" value={preview.expected_text} />
          <label className="flex flex-col gap-1 text-sm">
            {MOTIF}
            <input name="reason" required maxLength={2000} className={inputClass} />
          </label>
          {error ? <ErrorNote>{error}</ErrorNote> : null}
          <button type="submit" disabled={pending} aria-busy={pending} className={buttonClass}>
            {pending ? "Patientez…" : transferLineButton(proposal.action, options.class)}
          </button>
        </form>
      ) : error ? (
        <ErrorNote>{error}</ErrorNote>
      ) : null}
    </section>
  );
}
