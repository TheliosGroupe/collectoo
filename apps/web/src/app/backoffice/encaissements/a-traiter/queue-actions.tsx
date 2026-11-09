"use client";

import { type ReactNode, useEffect, useId, useState, useSyncExternalStore, useTransition } from "react";
import { ActionForm } from "@/components/action-form";
import { ErrorNote, buttonClass, dangerButtonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { errorText } from "@/lib/boarding/forms";
import {
  type AcceptResult,
  type QueueAccount,
  acceptNotice,
  fileLabel,
  gatingOutcome,
  outcomeText,
  pendingText,
} from "@/lib/payments/matching";
import { type Tone, money } from "@/lib/payments/statements";
import { acceptSuggestions, assignPayment, searchFiles, unassignPayment } from "./actions";

const secondaryClass =
  "rounded-md border border-zinc-300 px-4 py-2 text-sm font-medium hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900";

/** The payment a sheet acts on: its id, its amount as shown, and what the gating reads of it. */
export type PaymentFacts = { id: string; amount: string; currency: string; booking_date: string };

// What the last accept did, shown above the list: it outlives the card or form that sent it (a card
// leaves the queue once accepted; a skipped one may lose its button when its suggestion changed).
type Notice = { text: string; tone: Tone } | null;
let notice: Notice = null;
const listeners = new Set<() => void>();
function showNotice(next: Notice) {
  notice = next;
  for (const listener of listeners) listener();
}
function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
function noticeOf(result: Extract<AcceptResult, { ok: true }>) {
  showNotice(acceptNotice(result.accepted, result.skipped));
}

const NOTICE_CLASS: Record<string, string> = {
  ok: "bg-emerald-50 text-emerald-900 dark:bg-emerald-950 dark:text-emerald-200",
  action: "bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200",
};

/**
 * « 2 suggestions acceptées ; 1 paiement ignoré : suggestion modifiée entre-temps (1)… ». It survives the
 * refresh that follows an action; the page keys it by its URL, so another tab, filter or page clears it.
 */
export function QueueNotice() {
  useEffect(() => () => showNotice(null), []);
  const current = useSyncExternalStore(
    subscribe,
    () => notice,
    () => null,
  );
  if (!current) return null;
  return (
    <div
      role="status"
      data-testid="queue-notice"
      className={`flex items-start justify-between gap-3 rounded-md px-3 py-2 text-sm ${NOTICE_CLASS[current.tone] ?? NOTICE_CLASS.action}`}
    >
      <span>{current.text}</span>
      <button type="button" className="text-xs underline" onClick={() => showNotice(null)}>
        Fermer
      </button>
    </div>
  );
}

/**
 * A button that opens a confirmation sheet: at the bottom of the screen on a phone (never taller than
 * the screen: it scrolls inside), in place on a desktop. The sheet says what will happen before anything
 * is sent.
 */
function ConfirmSheet({
  label,
  title,
  buttonClassName,
  testId,
  children,
}: {
  label: string;
  title: string;
  buttonClassName: string;
  testId?: string;
  children: (close: () => void) => ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const titleId = useId();
  return (
    <div data-testid={testId}>
      <button type="button" className={buttonClassName} onClick={() => setOpen(true)} aria-expanded={open}>
        {label}
      </button>
      {open ? (
        <>
          <div className="fixed inset-0 z-10 bg-black/30 sm:hidden" aria-hidden onClick={() => setOpen(false)} />
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby={titleId}
            className="fixed inset-x-0 bottom-0 z-20 flex max-h-[85dvh] flex-col gap-3 overflow-y-auto overscroll-contain rounded-t-xl border-t border-zinc-200 bg-white p-4 shadow-lg sm:static sm:mt-3 sm:max-h-none sm:overflow-visible sm:rounded-lg sm:border sm:shadow-none dark:border-zinc-800 dark:bg-zinc-950"
          >
            <h3 id={titleId} className="font-medium">
              {title}
            </h3>
            {children(() => setOpen(false))}
            <button type="button" className={secondaryClass} onClick={() => setOpen(false)}>
              Annuler
            </button>
          </div>
        </>
      ) : null}
    </div>
  );
}

/** What the assignment will do: the file, its balance, then what the gating will say (as SQL does). */
function Effect({ payment, file }: { payment: PaymentFacts; file: QueueAccount }) {
  const pending = pendingText(file);
  const outcome = gatingOutcome(file, payment);
  return (
    <p className="text-sm" data-testid="sheet-effect">
      Le paiement de <strong>{payment.amount}</strong> sera rattaché au dossier <strong>{file.external_ref}</strong> (
      {file.client_name}
      {file.debtor_name ? `, ${file.debtor_name}` : ""}). Solde du dossier : {money(file.balance_minor, file.currency)}
      {pending ? ` (${pending})` : ""}.{" "}
      <span className={outcome ? "font-medium text-amber-900 dark:text-amber-200" : undefined}>{outcomeText(outcome)}</span>
    </p>
  );
}

/** The best suggestion as one button (« Affecter à M-0042 · … »), then a sheet stating the effect. */
export function AcceptSuggestion({
  payment,
  file,
  idempotencyKey,
}: {
  payment: PaymentFacts;
  file: QueueAccount;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet
      label={`Affecter à ${fileLabel(file)}`}
      title="Accepter la suggestion"
      buttonClassName={`${inlineButtonClass} w-full text-left sm:w-auto`}
      testId="accept-suggestion"
    >
      {(close) => (
        <>
          <Effect payment={payment} file={file} />
          <ActionForm
            action={acceptSuggestions}
            onDone={(result) => {
              noticeOf(result);
              close();
            }}
            submitLabel="Confirmer l'affectation"
            buttonClassName={buttonClass}
          >
            {/* the file this sheet names: the command assigns it only if it is still the suggestion */}
            <input type="hidden" name="item" value={`${payment.id}:${file.account_id}`} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

function AssignForm({
  paymentId,
  accountId,
  idempotencyKey,
  defaultReason,
}: {
  paymentId: string;
  accountId: string;
  idempotencyKey: string;
  defaultReason: string;
}) {
  return (
    <ActionForm action={assignPayment} submitLabel="Confirmer l'affectation" buttonClassName={buttonClass}>
      <input type="hidden" name="payment_id" value={paymentId} />
      <input type="hidden" name="account_id" value={accountId} />
      <input type="hidden" name="idempotency_key" value={idempotencyKey} />
      <label className="flex flex-col gap-1 text-sm">
        Motif (gardé dans l&apos;historique)
        <input name="reason" required maxLength={2000} defaultValue={defaultReason} className={inputClass} />
      </label>
    </ActionForm>
  );
}

/** One of the files the rules proposed (several possible): ops choose it, with a reason. */
export function ChooseFile({
  payment,
  file,
  idempotencyKey,
}: {
  payment: PaymentFacts;
  file: QueueAccount;
  idempotencyKey: string;
}) {
  return (
    <ConfirmSheet
      label="Choisir ce dossier"
      title={`Affecter à ${file.external_ref}`}
      buttonClassName={secondaryClass}
      testId="choose-file"
    >
      {() => (
        <>
          <Effect payment={payment} file={file} />
          <AssignForm
            paymentId={payment.id}
            accountId={file.account_id}
            idempotencyKey={idempotencyKey}
            defaultReason="Choix parmi les dossiers proposés"
          />
        </>
      )}
    </ConfirmSheet>
  );
}

/** Search a file by reference (file, invoice, RF) or debtor name, then assign with a reason. */
export function SearchAndAssign({ payment, idempotencyKey }: { payment: PaymentFacts; idempotencyKey: string }) {
  const [query, setQuery] = useState("");
  const [files, setFiles] = useState<(QueueAccount & { found_by: string })[] | null>(null);
  const [chosen, setChosen] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const [pending, startTransition] = useTransition();
  const searchId = useId();

  function search() {
    setFailed(false);
    setChosen(null);
    startTransition(async () => {
      const result = await searchFiles(payment.id, query);
      if ("error" in result) setFailed(true);
      else setFiles(result.files);
    });
  }

  const file = files?.find((f) => f.account_id === chosen) ?? null;
  return (
    <ConfirmSheet label="Chercher un dossier" title="Affecter à un dossier" buttonClassName={secondaryClass} testId="search-file">
      {() => (
        <>
          <div className="flex gap-2">
            <label htmlFor={searchId} className="sr-only">
              Dossier, facture, référence RF ou nom du débiteur
            </label>
            <input
              id={searchId}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  search();
                }
              }}
              placeholder="Dossier, facture, RF ou nom"
              className={inputClass}
            />
            <button type="button" className={inlineButtonClass} onClick={search} disabled={pending || query.trim().length < 3}>
              {pending ? "…" : "Chercher"}
            </button>
          </div>
          {failed ? <ErrorNote>{errorText("unknown")}</ErrorNote> : null}
          {files !== null && files.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun dossier confirmé ne correspond.</p>
          ) : null}
          {files && files.length > 0 ? (
            <fieldset className="flex flex-col gap-2" data-testid="search-results">
              <legend className="sr-only">Dossiers trouvés</legend>
              {files.map((f) => (
                <label key={f.account_id} className="flex items-start gap-2 rounded-md border border-zinc-200 p-2 text-sm dark:border-zinc-800">
                  <input type="radio" name="file" checked={chosen === f.account_id} onChange={() => setChosen(f.account_id)} />
                  <span>
                    {fileLabel(f)}
                    <span className="block text-xs text-zinc-600 dark:text-zinc-400">
                      {f.client_name}
                      {f.status.startsWith("closed") ? " · clôturé" : ""}
                    </span>
                  </span>
                </label>
              ))}
            </fieldset>
          ) : null}
          {file ? (
            <>
              <Effect payment={payment} file={file} />
              <AssignForm paymentId={payment.id} accountId={file.account_id} idempotencyKey={idempotencyKey} defaultReason="" />
            </>
          ) : null}
        </>
      )}
    </ConfirmSheet>
  );
}

/** Take a payment off its file (wrong file): back to the queue; the rules will not propose it again. */
export function Unassign({ paymentId, idempotencyKey }: { paymentId: string; idempotencyKey: string }) {
  return (
    <ConfirmSheet label="Désaffecter" title="Désaffecter ce paiement" buttonClassName={dangerButtonClass} testId="unassign">
      {() => (
        <>
          <p className="text-sm">
            Le paiement revient dans la file « à traiter » ; ce dossier ne lui sera plus proposé automatiquement. Rien
            n&apos;est encore imputé : aucune écriture n&apos;est à corriger.
          </p>
          <ActionForm action={unassignPayment} submitLabel="Confirmer" buttonClassName={buttonClass}>
            <input type="hidden" name="payment_id" value={paymentId} />
            <input type="hidden" name="idempotency_key" value={idempotencyKey} />
            <label className="flex flex-col gap-1 text-sm">
              Motif (gardé dans l&apos;historique)
              <input name="reason" required maxLength={2000} className={inputClass} />
            </label>
          </ActionForm>
        </>
      )}
    </ConfirmSheet>
  );
}

/**
 * Bulk acceptance on desktop: the checked payments' one-tap suggestions (fields join by form id; each
 * checkbox carries « payment:file », the file its card shows).
 */
export function BulkAccept({ idempotencyKey, count }: { idempotencyKey: string; count: number }) {
  return (
    <ActionForm
      action={acceptSuggestions}
      onDone={noticeOf}
      id="bulk-accept"
      testId="bulk-accept"
      submitLabel={`Accepter les suggestions cochées (${count} proposées sur cette page)`}
      buttonClassName={secondaryClass}
      className="hidden flex-col gap-2 sm:flex"
    >
      <input type="hidden" name="idempotency_key" value={idempotencyKey} />
    </ActionForm>
  );
}
