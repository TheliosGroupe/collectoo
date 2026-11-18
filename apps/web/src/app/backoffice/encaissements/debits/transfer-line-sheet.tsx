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
}: {
  lineId: string;
  currency: string;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet
      label="Comptabiliser…"
      title="Comptabiliser depuis le relevé"
      buttonClassName={secondaryClass}
      testId="book-transfer-line"
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
      {o.members ? <Members options={o} currency={currency} /> : null}
    </div>
  );
}

/** A lot's members (at most 50 listed, the rest counted) and what this line does of each (critic F6, critic2 CSO2-3). */
function Members({ options, currency }: { options: TransferLineOptions; currency: string }) {
  const parts = options.proposals[0]?.parts ?? [];
  const more = membersMore(options);
  // review 6b-2c (pages-3): a credit returns its members; a lot no booking is proposed for holds the bank's to confirm
  const line = { direction: options.direction, decided: options.proposals.length > 0 && !options.refusal };
  return (
    <div className="flex flex-col gap-1 text-sm" data-testid="transfer-line-members">
      <p className="font-medium">Virements du lot</p>
      <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
        {(options.members ?? []).map((m) => (
          <li key={m.transfer_id} className="flex flex-wrap justify-between gap-2 py-1">
            <span>
              {m.run_number ?? m.end_to_end_id ?? "Virement"}
              {m.client_name ? ` (${m.client_name})` : ""}
            </span>
            <span className="tabular-nums">{m.amount_minor ? money(m.amount_minor, currency) : ""}</span>
            <span className="text-zinc-600 dark:text-zinc-400">Dans cette ligne : {memberInLine(m, parts, line)}</span>
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
