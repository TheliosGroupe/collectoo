import { randomUUID } from "node:crypto";
import Link from "next/link";
import { ActionForm } from "@/components/action-form";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, Section, Stats, WidePage, buttonClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import {
  CHECK_RESULTS_SHOWN,
  checkCutText,
  groupCheckResults,
  hiddenRowText,
  orderCheckResults,
  unlistedText,
} from "@/lib/payments/check-results";
import { checkLabel, checkOldestDays, checkSubjectLink } from "@/lib/payments/debits";
import { coverPrompt } from "@/lib/payments/remitted";
import { money } from "@/lib/payments/statements";
import { requestChecks } from "../debits/actions";
import { CoverReversal, FullAdvanceCheck } from "./advance-actions";

type Result = {
  id: string;
  code: string;
  severity: string;
  subject_type: string;
  subject_id: string | null;
  currency: string | null;
  amount: string | null;
  count: number | null;
  oldest_days: number | null;
  details: Record<string, unknown> | null;
};

function frenchDateTime(iso: string): string {
  return new Intl.DateTimeFormat("fr-FR", { dateStyle: "short", timeStyle: "short", timeZone: "Europe/Paris" }).format(
    new Date(iso),
  );
}

/**
 * M2b-6 « Contrôles » (design §9 `invariants`, `suspense_ageing`): the last nightly run of the payments checks —
 * violations of the books' invariants (client money closed, bank cash = its payments, each payment's position against
 * its status, receivables, receipts, notifications, statements) and ageing alerts — phone-first, each leading where
 * it can be fixed. « Lancer les contrôles » runs the same job now. Admins and ops managers.
 * M2c-6b-3b part 3 (PR #39's known limit): it reads at most CHECK_RESULTS_SHOWN results, in one total order
 * (CHECK_RESULT_ORDER: the rows of a code always the same, the oldest first — the query's order by orderCheckResults, the
 * rows listed in it by groupCheckResults), and says, per code, how many results of the run it does not list — the run's own count by code (`summary`) minus the rows read: a count, never an amount.
 */
export default async function ChecksPage() {
  const { supabase, claims } = await staffSession();
  // M2c-6b-3a: the cancellation-after-download switch, for the texts worded both ways
  const { data: cancellationOn } = await supabase.rpc("cancellation_after_download");
  const cancellationAfterDownload = cancellationOn === true;
  const back = { href: "/backoffice/encaissements", label: "Relevés bancaires" };
  const { data: memberships } = await supabase
    .from("membership")
    .select("role, organization_id, organization:organization_id(kind)")
    .eq("user_id", claims.sub ?? "");
  const staff = (memberships ?? []).find(
    (m) => m.organization?.kind === "servicer" && (m.role === "admin" || m.role === "ops_manager"),
  );
  if (!staff) {
    return (
      <WidePage title="Contrôles des encaissements" back={back}>
        <InfoNote>Les contrôles sont réservés aux administrateurs et aux responsables des opérations.</InfoNote>
      </WidePage>
    );
  }
  const { data: runs } = await supabase
    .from("payment_check_run")
    .select("id, started_at, finished_at, violations, alerts, summary")
    .eq("organization_id", staff.organization_id)
    .order("started_at", { ascending: false })
    .limit(1);
  const run = runs?.[0] ?? null;
  let resultRows: unknown[] | null = [];
  if (run) {
    // review round 1 (tests-ui-3): the query's order is CHECK_RESULT_ORDER's (orderCheckResults, unit-tested)
    const query = orderCheckResults(
      supabase
        .from("payment_check_result")
        .select(
          "id, code, severity, subject_type, subject_id, currency, amount:amount_minor::text, count, oldest_days, details",
        )
        .eq("run_id", run.id),
    );
    ({ data: resultRows } = await query.limit(CHECK_RESULTS_SHOWN));
  }
  const results = (resultRows ?? []) as unknown as Result[];
  const running = run !== null && run.finished_at === null;
  // what the page does not list: per code, the run's count (its summary, once finished) minus the rows read
  const summary =
    run?.summary && typeof run.summary === "object" && !Array.isArray(run.summary)
      ? (run.summary as Record<string, unknown>)
      : null;
  const grouped = groupCheckResults(results, summary);
  // M2c-7a: « Couvrir » and the full check are an admin's; the clients the uncovered reversals name, by name
  const isAdmin = staff.role === "admin";
  const uncoveredClients = [
    ...new Set(
      results
        .filter((r) => r.code === "remitted_reversal_uncovered")
        .map((r) => (typeof r.details?.client_id === "string" ? r.details.client_id : null))
        .filter((x): x is string => x !== null),
    ),
  ];
  const { data: clientRows } =
    isAdmin && uncoveredClients.length > 0
      ? await supabase.from("organization").select("id, legal_name").in("id", uncoveredClients)
      : { data: [] as { id: string; legal_name: string }[] };
  const clientName = new Map((clientRows ?? []).map((c) => [c.id, c.legal_name]));

  return (
    <WidePage title="Contrôles des encaissements" back={back}>
      <AutoRefresh active={running} abandonable={false} everyMs={2000} maxMs={60_000} />
      <InfoNote>
        Chaque nuit, la comptabilité des paiements est vérifiée : fonds de tiers équilibrés, trésorerie de chaque compte
        égale à ses paiements, état de chaque paiement conforme à ses écritures, quittances et informations du client,
        continuité des relevés ; et l&apos;ancienneté des fonds non imputés, des remboursements et des débits à classer.
      </InfoNote>
      {run ? (
        <Stats
          items={[
            { label: "Dernier contrôle", value: frenchDateTime(run.started_at) },
            { label: "Anomalies", value: String(run.violations ?? 0), testId: "check-violations" },
            { label: "Alertes", value: String(run.alerts ?? 0), testId: "check-alerts" },
          ]}
        />
      ) : (
        <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun contrôle n&apos;a encore été lancé.</p>
      )}
      <ActionForm action={requestChecks} submitLabel="Lancer les contrôles" buttonClassName={buttonClass} testId="run-checks">
        <input type="hidden" name="organization_id" value={staff.organization_id} />
      </ActionForm>
      <p className="text-xs text-zinc-600 dark:text-zinc-400">
        Le contrôle s&apos;exécute en arrière-plan, en quelques secondes : actualisez la page pour voir le nouveau résultat.
      </p>
      {isAdmin ? <FullAdvanceCheck organizationId={staff.organization_id} idempotencyKey={randomUUID()} /> : null}

      {run ? (
        <Section title="Résultats" testId="check-results">
          {results.length === 0 && grouped.hidden === 0 ? (
            <p className="text-sm" data-testid="check-clean">
              Aucune anomalie ni alerte : les comptes de fonds de tiers sont cohérents.
            </p>
          ) : (
            <>
              {grouped.hidden > 0 ? (
                <InfoNote testId="check-cut">{checkCutText(results.length, grouped.total)}</InfoNote>
              ) : null}
              <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
                {grouped.groups.flatMap((g) => [
                  ...g.rows.map((r) => {
                    const l = checkLabel(r.code, { cancellationAfterDownload, details: r.details });
                    const to = checkSubjectLink(r);
                    return (
                      <li key={r.id} className="flex flex-col gap-1 py-3" data-testid="check-row" data-code={r.code}>
                        <span className="flex flex-wrap items-center gap-2">
                          <Badge tone={r.severity === "violation" ? "error" : "action"}>
                            {r.severity === "violation" ? "Anomalie" : "Alerte"}
                          </Badge>
                          <span className="font-medium">{l.label}</span>
                        </span>
                        <span className="text-sm text-zinc-600 dark:text-zinc-400">{l.help}</span>
                        <span className="text-sm">
                          {r.count !== null ? `${r.count} · ` : ""}
                          {r.amount !== null && r.currency ? `${money(r.amount, r.currency)} · ` : ""}
                          {r.oldest_days !== null ? checkOldestDays(r.oldest_days) : ""}
                          {to ? (
                            <>
                              {" "}
                              <Link href={to} className="underline underline-offset-4">
                                Ouvrir
                              </Link>
                            </>
                          ) : null}
                        </span>
                        {isAdmin &&
                        r.code === "remitted_reversal_uncovered" &&
                        r.subject_id &&
                        r.amount !== null &&
                        r.currency &&
                        typeof r.details?.recorded_on === "string" ? (
                          <CoverReversal
                            reversalId={r.subject_id}
                            expectedGap={r.amount}
                            prompt={coverPrompt(
                              r.amount,
                              r.currency,
                              clientName.get(String(r.details?.client_id)) ?? "",
                              r.details.recorded_on,
                            )}
                            idempotencyKey={randomUUID()}
                          />
                        ) : null}
                      </li>
                    );
                  }),
                  // M2c-6b-3b part 3: the code's results beyond those read, counted (the run's summary)
                  ...(g.hidden > 0
                    ? [
                        <li
                          key={`hidden-${g.code}`}
                          className="py-3 text-sm italic text-zinc-600 dark:text-zinc-400"
                          data-testid="check-hidden"
                          data-code={g.code}
                        >
                          {hiddenRowText(g.hidden)}
                        </li>,
                      ]
                    : []),
                ])}
                {grouped.unlisted.map((u) => (
                  <li
                    key={`unlisted-${u.code}`}
                    className="flex flex-col gap-1 py-3"
                    data-testid="check-unlisted"
                    data-code={u.code}
                  >
                    <span className="font-medium">{checkLabel(u.code).label}</span>
                    <span className="text-sm italic text-zinc-600 dark:text-zinc-400">{unlistedText(u.count)}</span>
                  </li>
                ))}
              </ul>
            </>
          )}
        </Section>
      ) : null}
    </WidePage>
  );
}
