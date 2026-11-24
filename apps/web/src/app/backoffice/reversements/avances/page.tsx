import Link from "next/link";
import { RepaymentRequestSheet, WithdrawRequestSheet } from "@/components/settlements/repayment-request-sheet";
import { InfoNote, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { money } from "@/lib/payments/statements";
import {
  advanceDates,
  advanceOrigin,
  advanceRecovered,
  advanceStatus,
  parseClientAdvances,
  requestCandidates,
} from "@/lib/remittance/advances";
import { requestedOn, stillRequestedParam, withdrawEffect } from "@/lib/remittance/requests";
import { WriteOffSheet } from "./write-off-sheet";

const PAGE = 50;

/**
 * M2c-7b « Avances » (plan §4.1.7, §4.3; design §17): the servicer's advances to its clients — a collection already
 * remitted then taken back, a payout beyond what was owed, a transfer executed outside any run — with what was recovered
 * and what is still open, and how: the claw-back clause of the advance's mandate (taken from the client's next
 * remittances), a repayment request (no clause, or no single mandate: 7c sends it), or the run in flight that takes it
 * back. Open ones by default (« Toutes » lists the others), newest first, a page at a time. « Passer en perte » for an
 * administrator. Money staff at aal2; the database decides (public.client_advances).
 *
 * M2c-7c-2 (plan §5.5): « Demander le remboursement » on an advance no claw-back clause recovers (the sheet ticks that
 * client's other advances on the page; its total from SQL), the column « Demandé le », « Retirer la demande ».
 */
export default async function AdvancesPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { supabase, claims } = await staffSession();
  const q = await searchParams;
  const all = q.vue === "toutes";
  const back = { href: "/backoffice/reversements", label: "Reversements" };
  const { data: memberships } = await supabase
    .from("membership")
    .select("role, organization_id, organization:organization_id(kind)")
    .eq("user_id", claims.sub ?? "");
  const staff = (memberships ?? []).find(
    (m) => m.organization?.kind === "servicer" && (m.role === "admin" || m.role === "ops_manager"),
  );
  if (!staff) {
    return (
      <WidePage title="Avances" back={back}>
        <InfoNote>Les avances sont réservées aux administrateurs et aux responsables des opérations.</InfoNote>
      </WidePage>
    );
  }
  const after =
    typeof q.apres === "string" && typeof q.id === "string" ? { created_at: q.apres, id: q.id } : null;
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
  const { data, error } = await supabase.rpc("client_advances", {
    p_organization_id: staff.organization_id,
    p_open_only: !all,
    p_after: after,
    p_limit: PAGE,
  });
  const read = error ? null : parseClientAdvances(data);
  if (!read) {
    return (
      <WidePage title="Avances" back={back}>
        <InfoNote>Les avances ne peuvent pas être affichées pour l&apos;instant. Réessayez.</InfoNote>
      </WidePage>
    );
  }
  const view = (v: string) => (v === "toutes" ? "/backoffice/reversements/avances?vue=toutes" : "/backoffice/reversements/avances");
  const next = read.next
    ? `/backoffice/reversements/avances?${new URLSearchParams({ ...(all ? { vue: "toutes" } : {}), apres: read.next.created_at, id: read.next.id })}`
    : null;
  return (
    <WidePage title="Avances" back={back}>
      <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="advances-intro">
        Les sommes que le cabinet a avancées à ses clients : un encaissement déjà reversé puis repris, un reversement débité
        au-delà de ce qui restait dû, un virement exécuté hors reversement. Avec une clause de reprise du mandat auquel
        elles sont rattachées, elles sont déduites des prochains reversements du client ; sinon elles restent à récupérer
        par une demande de remboursement — jamais déduites quand elles sont nées avant l&apos;ouverture d&apos;une
        procédure collective du client. Un administrateur peut en passer une en perte.
      </p>
      {typeof q.demande === "string" ? (
        <div role="status" aria-live="polite" data-testid="request-notice">
          <InfoNote>
            Demande {q.demande} adressée au client : la lettre est déposée dans son espace client ; imprimez-la pour un
            envoi postal.
          </InfoNote>
        </div>
      ) : null}
      {typeof q.retrait === "string" ? (
        <div role="status" aria-live="polite" data-testid="withdraw-notice">
          <InfoNote>{withdrawEffect(q.retrait, stillRequestedParam(q.reste))}</InfoNote>
        </div>
      ) : null}
      {typeof q.perte === "string" ? (
        <div role="status" aria-live="polite" data-testid="write-off-notice">
          <InfoNote>Avance passée en perte : Collectoo ne réclame plus cette somme au client.</InfoNote>
        </div>
      ) : null}
      <nav className="flex flex-wrap gap-2" aria-label="Avances affichées">
        {(["ouvertes", "toutes"] as const).map((v) => (
          <Link
            key={v}
            href={view(v)}
            className={`rounded-full px-3 py-1 text-sm ${(v === "toutes") === all ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900" : "border border-zinc-300 dark:border-zinc-700"}`}
            aria-current={(v === "toutes") === all ? "page" : undefined}
            data-testid={`advances-${v}`}
          >
            {v === "toutes" ? "Toutes" : "À récupérer"}
          </Link>
        ))}
      </nav>
      {read.rows.length === 0 ? (
        <InfoNote>{all ? "Aucune avance." : "Aucune avance à récupérer."}</InfoNote>
      ) : (
        // (review round 1, tests-ui-7) below `sm` each advance is a stacked card (one row, every cell labelled), its open
        // part and how it is recovered in full view; from `sm` the table
        <div className="sm:overflow-x-auto">
          <table className="block w-full text-left text-sm sm:table sm:min-w-[640px]" data-testid="advances">
            <thead className="hidden text-xs text-zinc-600 sm:table-header-group dark:text-zinc-400">
              <tr>
                <th className="py-2 pr-3 font-medium">Client</th>
                <th className="py-2 pr-3 font-medium">Née le</th>
                <th className="py-2 pr-3 font-medium">Origine</th>
                <th className="py-2 pr-3 text-right font-medium">Avancé</th>
                <th className="py-2 pr-3 text-right font-medium">Récupéré</th>
                <th className="py-2 pr-3 text-right font-medium">Reste</th>
                <th className="py-2 pr-3 font-medium">Récupération</th>
                <th className="py-2 pr-3 font-medium">Demandé le</th>
                {read.can_write_off ? <th className="py-2 font-medium" /> : null}
              </tr>
            </thead>
            <tbody className="block divide-y divide-zinc-200 sm:table-row-group dark:divide-zinc-800">
              {read.rows.map((r) => (
                <tr
                  key={r.advance_id}
                  className="grid grid-cols-2 gap-x-3 gap-y-1 py-3 sm:table-row sm:py-0"
                  data-testid="advance-row"
                  data-advance={r.advance_id}
                >
                  <td className="col-span-2 font-medium sm:py-2 sm:pr-3">{r.client_name}</td>
                  {/* (review round 2, advance-date-contradicts-barred) the advance's birth (the date its recovery's
                      barred rule reads), its recording date apart and labelled so */}
                  <td className="col-span-2 tabular-nums sm:py-2 sm:pr-3" data-testid="advance-born">
                    <span className="sm:hidden">Née le </span>
                    {advanceDates(r).born}
                    {advanceDates(r).recorded ? (
                      <span className="block text-xs text-zinc-600 dark:text-zinc-400">{advanceDates(r).recorded}</span>
                    ) : null}
                  </td>
                  <td className="col-span-2 sm:py-2 sm:pr-3">{advanceOrigin(r)}</td>
                  <td className="tabular-nums sm:py-2 sm:pr-3 sm:text-right">
                    <span className="block text-xs text-zinc-600 sm:hidden dark:text-zinc-400">Avancé</span>
                    {money(r.amount_minor, r.currency)}
                  </td>
                  <td className="tabular-nums sm:py-2 sm:pr-3 sm:text-right">
                    <span className="block text-xs text-zinc-600 sm:hidden dark:text-zinc-400">Récupéré</span>
                    {/* (review round 1, tests-ui-3) what was recovered, never what was passed as a loss: that apart */}
                    <span data-testid="advance-recovered">{money(advanceRecovered(r), r.currency)}</span>
                    {r.recovered.write_off !== "0" ? (
                      <span className="block text-xs text-zinc-600 dark:text-zinc-400" data-testid="advance-written-off">
                        {money(r.recovered.write_off, r.currency)} passés en perte
                      </span>
                    ) : null}
                  </td>
                  <td className="font-semibold tabular-nums sm:py-2 sm:pr-3 sm:text-right">
                    <span className="block text-xs font-normal text-zinc-600 sm:hidden dark:text-zinc-400">Reste</span>
                    <span data-testid="advance-open">{money(r.open_minor, r.currency)}</span>
                  </td>
                  <td className="sm:py-2 sm:pr-3" data-testid="advance-recovery">
                    {advanceStatus(r)}
                    {r.mandate_reference ? (
                      <span className="block text-xs text-zinc-600 dark:text-zinc-400">mandat {r.mandate_reference}</span>
                    ) : null}
                  </td>
                  {/* M2c-7c-2 (plan §5.5): the request that names it, its withdrawal; or the request itself */}
                  <td className="col-span-2 flex flex-col items-start gap-1 sm:table-cell sm:py-2 sm:pr-3">
                    {/* on a phone the cell has no column head: « — » alone would say nothing, so it shows only wider */}
                    <span data-testid="advance-requested" className={r.request ? undefined : "hidden sm:inline"}>
                      {requestedOn(r.request ?? null) ?? "—"}
                    </span>
                    {r.request ? (
                      <WithdrawRequestSheet requestId={r.request.request_id} number={r.request.number} back={view(all ? "toutes" : "ouvertes")} />
                    ) : null}
                    {requestCandidates(read.rows, r, today).length > 0 ? (
                      <RepaymentRequestSheet
                        clientId={r.client_id}
                        clientName={r.client_name}
                        currency={r.currency}
                        candidates={requestCandidates(read.rows, r, today)}
                        initial={[r.advance_id]}
                        label={r.request ? "Relancer" : "Demander le remboursement"}
                        back={view(all ? "toutes" : "ouvertes")}
                      />
                    ) : null}
                  </td>
                  {read.can_write_off ? (
                    <td className="self-end sm:py-2">
                      {r.open_minor !== "0" && !r.in_flight_run ? (
                        <WriteOffSheet
                          advanceId={r.advance_id}
                          servicerId={staff.organization_id}
                          clientId={r.client_id}
                          clientName={r.client_name}
                          currency={r.currency}
                          openMinor={r.open_minor}
                        />
                      ) : null}
                    </td>
                  ) : null}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {next ? (
        <Link href={next} className="text-sm underline underline-offset-4" data-testid="advances-next">
          Plus anciennes →
        </Link>
      ) : null}
    </WidePage>
  );
}
