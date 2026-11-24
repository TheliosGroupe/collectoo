"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { ErrorNote, InfoNote, buttonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { money } from "@/lib/payments/statements";
import {
  type RepaymentPreview,
  parseRepaymentPreview,
  parseWithdrawal,
  refusalText,
  repaymentRefusal,
  requestSheetEffect,
  withdrawSheetText,
} from "@/lib/remittance/requests";
import { createClient } from "@/lib/supabase/browser";

export type RequestCandidate = { advance_id: string; label: string; open_minor: string };

/**
 * M2c-7c-2 (plan §5.2.7, §5.5): « Demander le remboursement » — a letter asking the client to repay advances of the
 * servicer no claw-back clause recovers. The advances of one client and currency are ticked; the total and each one's
 * refusal come from SQL (public.advance_repayment_preview: never computed here); the command
 * (public.request_advance_repayment) compares the total the sheet showed. It moves no money: the letter is drawn by
 * the worker and put in the client space, to print for the post. On success the page reloads with ?demande=<number>.
 */
export function RepaymentRequestSheet({
  clientId,
  clientName,
  currency,
  candidates,
  initial,
  label = "Demander le remboursement",
  back,
}: {
  clientId: string;
  clientName: string;
  currency: string;
  candidates: RequestCandidate[];
  initial: string[];
  label?: string;
  back: string;
}) {
  const router = useRouter();
  const key = useRef<{ signature: string; key: string } | null>(null);
  const asked = useRef(0);
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string[]>(initial);
  const [preview, setPreview] = useState<{ ids: string; p: RepaymentPreview } | null>(null);
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const ids = candidates.map((c) => c.advance_id).filter((id) => selected.includes(id));
  const signature = ids.join(",");

  // the preview of the ticked advances (debounced; an answer to earlier ticks is dropped)
  useEffect(() => {
    if (!open || ids.length === 0) return;
    const n = ++asked.current;
    const these = signature;
    const timer = setTimeout(async () => {
      const { data, error: e } = await createClient().rpc("advance_repayment_preview", {
        p_client_organization_id: clientId,
        p_currency: currency,
        p_advance_ids: these.split(","),
      });
      if (n !== asked.current) return;
      const p = e ? null : parseRepaymentPreview(data);
      if (!p) return setError("Le total ne peut pas être calculé pour l'instant. Réessayez.");
      setError(null);
      setPreview({ ids: these, p });
    }, 150);
    return () => clearTimeout(timer);
  }, [open, signature, ids.length, clientId, currency]);

  const current = preview && preview.ids === signature ? preview.p : null;
  const refused = current ? current.refusal !== null || current.rows.some((r) => r.refusal !== null) : true;

  async function onConfirm() {
    if (progress !== null || !current || refused) return;
    setError(null);
    if (key.current?.signature !== signature) key.current = { signature, key: crypto.randomUUID() };
    setProgress("Envoi de la demande…");
    const { data, error: e } = await createClient().rpc("request_advance_repayment", {
      p_idempotency_key: key.current.key,
      p_client_organization_id: clientId,
      p_currency: currency,
      p_advance_ids: ids,
      p_expected_total_text: current.total_minor,
    });
    setProgress(null);
    if (e) return setError(repaymentRefusal(e.message, e.details));
    const number = (data as { number?: string } | null)?.number ?? "";
    key.current = null;
    setOpen(false);
    router.push(`${back}${back.includes("?") ? "&" : "?"}demande=${encodeURIComponent(number)}`);
    router.refresh();
  }

  if (!open)
    return (
      <button type="button" className={inlineButtonClass} onClick={() => setOpen(true)} data-testid="request-open">
        {label}
      </button>
    );
  const refusalOf = (id: string) => current?.rows.find((r) => r.advance_id === id);
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Demander le remboursement"
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center"
    >
      <div
        className="flex max-h-full w-full max-w-lg flex-col gap-3 overflow-y-auto rounded-t-xl bg-white p-4 dark:bg-zinc-950 sm:rounded-xl"
        data-testid="request-sheet"
      >
        <h2 className="text-lg font-semibold">Demander le remboursement</h2>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          {clientName} · avances du cabinet qu&apos;aucune clause de reprise ne récupère. La lettre « Demande de
          remboursement d&apos;avance »
          n&apos;est pas une facture.
        </p>
        <fieldset className="flex flex-col gap-2 text-sm">
          <legend className="mb-1 font-medium">Avances demandées</legend>
          {candidates.map((c) => {
            const r = refusalOf(c.advance_id);
            return (
              <label key={c.advance_id} className="flex flex-col gap-0.5" data-testid="request-advance">
                <span className="flex items-start gap-2">
                  <input
                    type="checkbox"
                    checked={selected.includes(c.advance_id)}
                    onChange={(e) =>
                      setSelected((s) => (e.target.checked ? [...s, c.advance_id] : s.filter((x) => x !== c.advance_id)))
                    }
                  />
                  <span>
                    {c.label} · {money(c.open_minor, currency)}
                  </span>
                </span>
                {r?.refusal ? (
                  <span className="pl-6 text-red-700 dark:text-red-400" data-testid="request-advance-refusal">
                    {refusalText(r.refusal, r.detail)}
                  </span>
                ) : null}
              </label>
            );
          })}
        </fieldset>
        {current ? (
          <>
            <p className="font-medium" data-testid="request-total">
              Total demandé : {money(current.total_minor, currency)}
            </p>
            {current.refusal ? (
              <ErrorNote>{refusalText(current.refusal, current.detail)}</ErrorNote>
            ) : (
              <p className="text-sm" data-testid="request-effect">
                {requestSheetEffect(current.total_minor, currency)}
              </p>
            )}
          </>
        ) : ids.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Cochez au moins une avance.</p>
        ) : (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Calcul du total…</p>
        )}
        {error ? <ErrorNote>{error}</ErrorNote> : null}
        {progress ? (
          <div role="status" aria-live="polite">
            <InfoNote>{progress}</InfoNote>
          </div>
        ) : null}
        <div className="flex flex-wrap gap-3">
          <button
            type="button"
            disabled={progress !== null || refused}
            className={buttonClass}
            onClick={() => void onConfirm()}
            data-testid="request-confirm"
          >
            Adresser la demande
          </button>
          <button type="button" className={inlineButtonClass} onClick={() => setOpen(false)}>
            Annuler
          </button>
        </div>
      </div>
    </div>
  );
}

/**
 * M2c-7c-2 ([critic] « Retirer la demande »): the request withdrawn, with a motif (staff only: no client reads it); its
 * advances can then be taken back by the claw-back clause or requested anew, but for those another request not
 * withdrawn still names (review round 1, UI-1: a reminder withdrawn leaves the first request). The page reloads with
 * ?retrait=<number>&reste=<the requests that still name them> (the command's still_requested_by).
 */
export function WithdrawRequestSheet({ requestId, number, back }: { requestId: string; number: string; back: string }) {
  const router = useRouter();
  const key = useRef<{ reason: string; key: string } | null>(null);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [progress, setProgress] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function onConfirm() {
    if (progress !== null) return;
    setError(null);
    if (key.current?.reason !== reason) key.current = { reason, key: crypto.randomUUID() };
    setProgress("Retrait de la demande…");
    const { data, error: e } = await createClient().rpc("withdraw_advance_repayment_request", {
      p_idempotency_key: key.current.key,
      p_request_id: requestId,
      p_reason: reason,
    });
    setProgress(null);
    if (e) return setError(repaymentRefusal(e.message, e.details));
    key.current = null;
    setOpen(false);
    const still = parseWithdrawal(data)?.still_requested_by ?? [];
    const reste = still.length > 0 ? `&reste=${encodeURIComponent(still.join(","))}` : "";
    router.push(`${back}${back.includes("?") ? "&" : "?"}retrait=${encodeURIComponent(number)}${reste}`);
    router.refresh();
  }

  if (!open)
    return (
      <button type="button" className={inlineButtonClass} onClick={() => setOpen(true)} data-testid="withdraw-open">
        Retirer la demande
      </button>
    );
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Retirer la demande"
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center"
    >
      <div
        className="flex max-h-full w-full max-w-lg flex-col gap-3 overflow-y-auto rounded-t-xl bg-white p-4 dark:bg-zinc-950 sm:rounded-xl"
        data-testid="withdraw-sheet"
      >
        <h2 className="text-lg font-semibold">Retirer la demande {number}</h2>
        <p className="text-sm" data-testid="withdraw-effect">
          {withdrawSheetText(number)}
        </p>
        <label className="flex flex-col gap-1 text-sm">
          Motif (interne, non transmis au client)
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            required
            maxLength={2000}
            rows={3}
            className={inputClass}
          />
        </label>
        {error ? <ErrorNote>{error}</ErrorNote> : null}
        {progress ? (
          <div role="status" aria-live="polite">
            <InfoNote>{progress}</InfoNote>
          </div>
        ) : null}
        <div className="flex flex-wrap gap-3">
          <button
            type="button"
            disabled={progress !== null || reason.trim().length === 0}
            className={buttonClass}
            onClick={() => void onConfirm()}
            data-testid="withdraw-confirm"
          >
            Retirer la demande
          </button>
          <button type="button" className={inlineButtonClass} onClick={() => setOpen(false)}>
            Annuler
          </button>
        </div>
      </div>
    </div>
  );
}
