"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { type FormEvent, useMemo, useState, useTransition } from "react";
import { Badge, ErrorNote, InfoNote, buttonClass, inputClass } from "@/components/ui";
import { errorText } from "@/lib/boarding/forms";
import { money } from "@/lib/payments/statements";
import {
  type RunCard,
  TRIGGER_LABEL,
  blockerLabel,
  confirmedAgo,
  deadlineChip,
  failureLabel,
  frenchDate,
  runStatus,
  sumMinor,
} from "@/lib/remittance/runs";
import { approveRuns } from "./actions";

/** A run whose draft can be approved now (prepared, nothing in flight, nothing blocking its payout). */
function approvable(r: RunCard): boolean {
  if (r.status !== "draft" || r.job !== null || r.prepared_at === null || r.inputs_hash === null) return false;
  if (r.net_minor !== null && BigInt(r.net_minor) < BigInt(0)) return false;
  return !(r.net_minor !== null && BigInt(r.net_minor) > BigInt(0) && r.blockers.length > 0);
}

/**
 * « À valider » (§17.1): a card per draft — the net in large type, what it is made of, the deadline chip, the
 * blockers — with a box to select it; a sticky « Valider n reversements · total » opens the sheet that states every
 * effect before approving (one approver, founder #11).
 */
export function ApprovePanel({
  runs,
  nextBusinessDay,
  canApprove,
}: {
  runs: RunCard[];
  nextBusinessDay: string;
  canApprove: boolean;
}) {
  const router = useRouter();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [sheet, setSheet] = useState(false);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [summary, setSummary] = useState<string | null>(null);
  const [date, setDate] = useState(nextBusinessDay);
  const [lateReason, setLateReason] = useState("");
  const chosen = useMemo(() => runs.filter((r) => selected.has(r.id)), [runs, selected]);
  const total = sumMinor(chosen.map((r) => r.net_minor));
  const transfers = chosen.filter((r) => r.net_minor !== null && BigInt(r.net_minor) > BigInt(0)).length;
  const invoices = chosen.filter((r) => r.invoice_ttc_minor && r.invoice_ttc_minor !== "0").length;
  const credits = chosen.filter((r) => r.credit_ttc_minor && r.credit_ttc_minor !== "0").length;
  const late = chosen.some((r) => r.earliest_latest_execution_date !== null && date > r.earliest_latest_execution_date);

  function toggle(id: string) {
    setSelected((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending) return;
    const formData = new FormData(event.currentTarget);
    setError(null);
    startTransition(async () => {
      const result = await approveRuns(formData);
      if ("error" in result) setError(errorText(result.error));
      else {
        setSummary(result.summary);
        setSheet(false);
        setSelected(new Set());
        router.refresh();
      }
    });
  }

  return (
    <div className="flex flex-col gap-3">
      {summary ? (
        <p className="rounded-md bg-emerald-50 p-3 text-sm text-emerald-900 dark:bg-emerald-950 dark:text-emerald-200" data-testid="approve-summary">
          {summary}
        </p>
      ) : null}
      <ul className="flex flex-col gap-3" data-testid="runs">
        {runs.map((r) => {
          const status = runStatus(r);
          const chip = deadlineChip(r.earliest_latest_execution_date, r.deadline_state);
          const ok = approvable(r);
          return (
            <li key={r.id} className="rounded-lg border border-zinc-200 p-4 dark:border-zinc-800" data-testid="run-card" data-number={r.number}>
              <div className="flex items-start gap-3">
                {canApprove ? (
                  <input
                    type="checkbox"
                    className="mt-2 h-5 w-5"
                    aria-label={`Sélectionner ${r.number} (${r.client_name})`}
                    disabled={!ok}
                    checked={selected.has(r.id)}
                    onChange={() => toggle(r.id)}
                    data-testid="run-select"
                  />
                ) : null}
                <div className="flex min-w-0 flex-1 flex-col gap-1">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <Link href={`/backoffice/reversements/${r.id}`} className="font-medium underline underline-offset-4">
                      {r.client_name}
                    </Link>
                    <Badge tone={status.tone}>{status.label}</Badge>
                  </div>
                  <p className="text-2xl font-semibold tabular-nums" data-testid="run-net">
                    {r.net_minor !== null ? money(r.net_minor, r.currency) : "—"}
                  </p>
                  <p className="text-sm text-zinc-600 dark:text-zinc-400">
                    {r.number} · {r.line_count ?? r.item_count} encaissement{(r.line_count ?? r.item_count) > 1 ? "s" : ""}
                    {r.gross_minor !== null ? ` · brut ${money(r.gross_minor, r.currency)}` : ""}
                    {r.invoice_ttc_minor && r.invoice_ttc_minor !== "0"
                      ? ` · commission ${money(r.invoice_ttc_minor, r.currency)} TTC`
                      : ""}
                    {r.credit_ttc_minor && r.credit_ttc_minor !== "0" ? ` · avoir ${money(r.credit_ttc_minor, r.currency)} TTC` : ""}
                  </p>
                  <div className="flex flex-wrap gap-2">
                    {chip ? <Badge tone={chip.tone}>{chip.label}</Badge> : null}
                    {r.trigger !== "manual" ? <Badge tone="neutral">{TRIGGER_LABEL[r.trigger] ?? r.trigger}</Badge> : null}
                    {r.payout ? (
                      <Badge tone={r.payout.new_iban ? "action" : "neutral"}>
                        {r.payout.new_iban ? "Nouvel IBAN · " : ""}
                        {confirmedAgo(r.payout.confirmed_at) ?? `IBAN …${r.payout.iban_last4}`}
                      </Badge>
                    ) : null}
                    {r.unmeetable_count > 0 ? <Badge tone="error">Délai intenable : {r.unmeetable_count}</Badge> : null}
                  </div>
                  {r.blockers.length > 0 ? (
                    <ul className="text-sm text-red-800 dark:text-red-300" data-testid="run-blockers">
                      {r.blockers.map((b) => (
                        <li key={b}>Bloqué : {blockerLabel(b)}</li>
                      ))}
                    </ul>
                  ) : null}
                  {r.commission_blockers.length > 0 ? (
                    <p className="text-sm text-amber-800 dark:text-amber-300">
                      Commission en attente : {blockerLabel(r.commission_blockers[0])} (reversement brut)
                    </p>
                  ) : null}
                  {r.last_failure ? (
                    <p className="text-sm text-amber-800 dark:text-amber-300" data-testid="run-failure">
                      Renvoyé en brouillon : {failureLabel(r.last_failure.code)}
                    </p>
                  ) : null}
                </div>
              </div>
            </li>
          );
        })}
      </ul>

      {canApprove && chosen.length > 0 ? (
        <div className="sticky bottom-0 -mx-4 border-t border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-950">
          <button type="button" className={buttonClass + " w-full"} onClick={() => setSheet(true)} data-testid="approve-open">
            Valider {chosen.length} reversement{chosen.length > 1 ? "s" : ""} · {money(total, chosen[0]?.currency ?? "EUR")}
          </button>
        </div>
      ) : null}

      {sheet ? (
        <div role="dialog" aria-modal="true" aria-label="Valider les reversements" className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center">
          <form onSubmit={submit} className="flex w-full max-w-lg flex-col gap-3 rounded-t-xl bg-white p-4 dark:bg-zinc-950 sm:rounded-xl" data-testid="approve-sheet">
            <h2 className="text-lg font-semibold">Valider {chosen.length} reversement{chosen.length > 1 ? "s" : ""}</h2>
            <input type="hidden" name="idempotency_key" value={crypto.randomUUID()} />
            {chosen.map((r) => (
              <input key={r.id} type="hidden" name="run" value={`${r.id}|${r.inputs_hash}|${r.net_minor}`} />
            ))}
            <label className="flex flex-col gap-1 text-sm">
              Exécution demandée le
              <input type="date" name="requested_execution_date" className={inputClass} value={date} min={nextBusinessDay > date ? date : undefined}
                onChange={(e) => setDate(e.target.value)} required />
            </label>
            <p className="text-sm" data-testid="approve-effects">
              {transfers} virement{transfers > 1 ? "s" : ""} depuis le compte dédié, exécution demandée le {frenchDate(date)}.{" "}
              {invoices} facture{invoices > 1 ? "s" : ""}
              {credits > 0 ? ` et ${credits} avoir${credits > 1 ? "s" : ""}` : ""}{" "}
              {credits > 0 ? "seront numérotés" : invoices > 1 ? "seront numérotées" : "sera numérotée"}.
              {" "}Commission à régler par compensation lors des virements, quand le mandat le prévoit. Rien ne quitte le compte dédié avant le débit de la banque.
            </p>
            {late ? (
              <label className="flex flex-col gap-1 text-sm">
                Motif du retard (la date dépasse une date limite de reversement, art. R124-6 CPCE)
                <textarea name="late_reason" className={inputClass} value={lateReason} onChange={(e) => setLateReason(e.target.value)} required />
              </label>
            ) : null}
            {error ? <ErrorNote>{error}</ErrorNote> : null}
            <div className="flex gap-2">
              <button type="button" className="flex-1 rounded-md border border-zinc-300 px-4 py-2 dark:border-zinc-700" onClick={() => setSheet(false)}>
                Retour
              </button>
              <button type="submit" className={buttonClass + " flex-1"} disabled={pending} data-testid="approve-confirm">
                {pending ? "Patientez…" : "Valider"}
              </button>
            </div>
          </form>
        </div>
      ) : null}
      {runs.length === 0 ? <InfoNote>Aucun reversement à valider.</InfoNote> : null}
    </div>
  );
}
