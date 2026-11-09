import Link from "next/link";
import { ActionForm } from "@/components/action-form";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, Section, Stats, WidePage, buttonClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { checkLabel } from "@/lib/payments/debits";
import { money } from "@/lib/payments/statements";
import { requestChecks } from "../debits/actions";

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
};

function frenchDateTime(iso: string): string {
  return new Intl.DateTimeFormat("fr-FR", { dateStyle: "short", timeStyle: "short", timeZone: "Europe/Paris" }).format(
    new Date(iso),
  );
}

/** Where a result leads: the payment, the statement, or the queue that holds what ages. */
function subjectLink(r: Result): string | null {
  if (r.subject_type === "payment" && r.subject_id) return `/backoffice/encaissements/paiements/${r.subject_id}`;
  if (r.subject_type === "bank_statement" && r.subject_id) return `/backoffice/encaissements/releves/${r.subject_id}`;
  if (r.code === "debit_unclassified") return "/backoffice/encaissements/debits";
  if (r.code === "duplicate_unresolved") return "/backoffice/encaissements/debits?onglet=doublons";
  if (r.code === "unmatched_ageing" || r.code === "unallocated_ageing") return "/backoffice/encaissements/a-traiter";
  return null;
}

/**
 * M2b-6 « Contrôles » (design §9 `invariants`, `suspense_ageing`): the last nightly run of the payments checks —
 * violations of the books' invariants (client money closed, bank cash = its payments, each payment's position against
 * its status, receivables, receipts, notifications, statements) and ageing alerts — phone-first, each leading where
 * it can be fixed. « Lancer les contrôles » runs the same job now. Admins and ops managers.
 */
export default async function ChecksPage() {
  const { supabase, claims } = await staffSession();
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
    .select("id, started_at, finished_at, violations, alerts")
    .eq("organization_id", staff.organization_id)
    .order("started_at", { ascending: false })
    .limit(1);
  const run = runs?.[0] ?? null;
  const { data: resultRows } = run
    ? await supabase
        .from("payment_check_result")
        .select("id, code, severity, subject_type, subject_id, currency, amount:amount_minor::text, count, oldest_days")
        .eq("run_id", run.id)
        .order("severity", { ascending: false })
        .order("code")
        .limit(200)
    : { data: [] };
  const results = (resultRows ?? []) as unknown as Result[];
  const running = run !== null && run.finished_at === null;

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

      {run ? (
        <Section title="Résultats" testId="check-results">
          {results.length === 0 ? (
            <p className="text-sm" data-testid="check-clean">
              Aucune anomalie ni alerte : les comptes de fonds de tiers sont cohérents.
            </p>
          ) : (
            <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
              {results.map((r) => {
                const l = checkLabel(r.code);
                const to = subjectLink(r);
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
                      {r.oldest_days !== null ? `le plus ancien : ${r.oldest_days} jours` : ""}
                      {to ? (
                        <>
                          {" "}
                          <Link href={to} className="underline underline-offset-4">
                            Ouvrir
                          </Link>
                        </>
                      ) : null}
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </Section>
      ) : null}
    </WidePage>
  );
}
