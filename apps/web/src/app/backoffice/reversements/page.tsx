import Link from "next/link";
import { ActionForm } from "@/components/action-form";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, Section, WidePage, inlineButtonClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { money } from "@/lib/payments/statements";
import { RUN_TABS, type RunCard, deadlineChip, frenchDate, runBusy, runStatus, runTab } from "@/lib/remittance/runs";
import { requestRun } from "./actions";
import { ApprovePanel } from "./approve-panel";

type Overview = {
  tab: string;
  runs: RunCard[];
  to_prepare: {
    client_id: string;
    client_name: string;
    currency: string;
    owed_minor: string;
    items: number;
    earliest_latest_execution_date: string | null;
    deadline_state: RunCard["deadline_state"];
  }[];
  counts: Record<string, number>;
  today: string;
  next_business_day: string;
  can_approve: boolean;
  can_cancel: boolean;
};

/**
 * M2c-4 « Reversements » (design §17.1): « À valider » — the drafts, oldest deadline first, each card's net, what
 * it is made of, its deadline chip and blockers, approved one by one or together (the sheet states every effect);
 * the clients with collections waiting and no run (« Préparer maintenant »); « En cours » — approved, their transfer
 * ordered (M2c-6 files and books it); « Terminés ». Admins and ops managers at aal2 (the database checks it).
 */
export default async function RemittancesPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const tab = runTab((await searchParams).onglet);
  const { supabase } = await staffSession();
  const back = { href: "/backoffice", label: "Back-office" };
  const { data, error } = await supabase.rpc("remittance_overview", { p_tab: tab });
  if (error || !data) {
    return (
      <WidePage title="Reversements" back={back}>
        <InfoNote>Les reversements sont réservés aux administrateurs et aux responsables des opérations.</InfoNote>
      </WidePage>
    );
  }
  const o = data as unknown as Overview;
  // a job in flight refreshes the page; a failed preparation does not (it waits for « Actualiser »)
  const busy = o.runs.some(runBusy);
  return (
    <WidePage title="Reversements" back={back}>
      <AutoRefresh active={busy} abandonable={false} everyMs={2000} maxMs={120_000} />
      <nav className="flex flex-wrap gap-2" aria-label="Onglets">
        {Object.entries(RUN_TABS).map(([key, t]) => (
          <Link
            key={key}
            href={key === "a-valider" ? "/backoffice/reversements" : `/backoffice/reversements?onglet=${key}`}
            className={`rounded-full px-3 py-1 text-sm ${key === tab ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900" : "border border-zinc-300 dark:border-zinc-700"}`}
            aria-current={key === tab ? "page" : undefined}
            data-testid={`tab-${key}`}
          >
            {t.label}
            {o.counts[key] ? ` (${o.counts[key]})` : ""}
          </Link>
        ))}
      </nav>

      {tab === "a-valider" ? (
        <>
          <InfoNote>
            Chaque client reçoit au plus un reversement à la fois. La commission est facturée à la validation (une facture
            par mandat, numérotée dans la série annuelle) ; le virement est ordonné et rien ne quitte le compte dédié avant
            le débit de la banque. Délai : un mois au plus après l&apos;encaissement (art. R124-6 CPCE), plus court si le
            mandat le prévoit.
          </InfoNote>
          <ApprovePanel runs={o.runs} today={o.today} nextBusinessDay={o.next_business_day} canApprove={o.can_approve} />
          <Section title="Encaissements en attente sans reversement" testId="to-prepare">
            {o.to_prepare.length === 0 ? (
              <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun encaissement n&apos;attend hors reversement.</p>
            ) : (
              <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
                {o.to_prepare.map((c) => {
                  const chip = deadlineChip(c.earliest_latest_execution_date, c.deadline_state);
                  return (
                    <li key={`${c.client_id}-${c.currency}`} className="flex flex-wrap items-center justify-between gap-2 py-3" data-testid="prepare-row">
                      <span className="flex flex-col">
                        <span className="font-medium">{c.client_name}</span>
                        <span className="text-sm text-zinc-600 dark:text-zinc-400">
                          {money(c.owed_minor, c.currency)} · {c.items} encaissement{c.items > 1 ? "s" : ""}
                        </span>
                        {chip ? (
                          <span>
                            <Badge tone={chip.tone}>{chip.label}</Badge>
                          </span>
                        ) : null}
                      </span>
                      {o.can_approve ? (
                        <ActionForm action={requestRun} submitLabel="Préparer maintenant" buttonClassName={inlineButtonClass} testId="prepare-now">
                          <input type="hidden" name="idempotency_key" value={crypto.randomUUID()} />
                          <input type="hidden" name="client_organization_id" value={c.client_id} />
                          <input type="hidden" name="currency" value={c.currency} />
                        </ActionForm>
                      ) : null}
                    </li>
                  );
                })}
              </ul>
            )}
          </Section>
        </>
      ) : (
        <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800" data-testid="runs">
          {o.runs.length === 0 ? <InfoNote>Aucun reversement.</InfoNote> : null}
          {o.runs.map((r) => {
            const s = runStatus(r);
            return (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 py-3" data-testid="run-row">
                <span className="flex flex-col">
                  <Link href={`/backoffice/reversements/${r.id}`} className="font-medium underline underline-offset-4">
                    {r.client_name} · {r.number}
                  </Link>
                  <span className="text-sm text-zinc-600 dark:text-zinc-400">
                    net {r.net_minor !== null ? money(r.net_minor, r.currency) : "—"}
                    {r.requested_execution_date ? ` · exécution demandée le ${frenchDate(r.requested_execution_date)}` : ""}
                    {r.booked_on ? ` · comptabilisé le ${frenchDate(r.booked_on)}` : ""}
                    {r.cancel_reason ? ` · ${r.cancel_reason}` : ""}
                  </span>
                </span>
                <Badge tone={s.tone}>{s.label}</Badge>
              </li>
            );
          })}
        </ul>
      )}
    </WidePage>
  );
}
