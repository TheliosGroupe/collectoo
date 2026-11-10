import Link from "next/link";
import { redirect } from "next/navigation";
import { Badge, InfoNote, Section, Stats, WidePage } from "@/components/ui";
import type { SessionClaims } from "@/lib/auth/access";
import { money } from "@/lib/payments/statements";
import { clientOfUser } from "@/lib/remittance/client-space";
import { frenchDay, runStatusText } from "@/lib/remittance/documents";
import { createClient } from "@/lib/supabase/server";

type Summary = {
  owed: { currency: string; owed_minor: string }[];
  in_flight: { number: string; status: string; currency: string; net_minor: string; requested_execution_date: string | null }[];
  next_run_day: string | null;
};
type Totals = { gross_minor: string; net_minor: string; invoice_ttc_minor: string; credit_ttc_minor: string };

/**
 * M2c-5 « Reversements » (client space, design §17.7; C. civ. 1993: the account of what we collected): what is owed to
 * the client today (its running 4670 balance), the payout in flight (« ordonné » until the bank's debit, never « payé »),
 * the next scheduled run, and every statement with its PDF and CSV (SHA-256 shown). The client's members with access to
 * the whole client only (OQ-48: a user restricted to some portfolios reads that it is not covered); RLS decides.
 */
export default async function ClientRemittancesPage() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const claims = (data?.claims ?? null) as SessionClaims | null;
  if (!claims?.sub) redirect("/connexion");
  const back = { href: "/client", label: "Espace client" };
  const { client, restricted } = await clientOfUser(supabase, claims);
  if (!client) {
    return (
      <WidePage title="Reversements" back={back}>
        <InfoNote>Aucun client rattaché à votre compte.</InfoNote>
      </WidePage>
    );
  }
  if (restricted) {
    return (
      <WidePage title="Reversements" back={back}>
        <InfoNote>
          Vos accès ne couvrent pas les relevés de reversement : ils portent sur tous les portefeuilles du client.
        </InfoNote>
      </WidePage>
    );
  }
  const [{ data: summaryData, error }, { data: statements }] = await Promise.all([
    supabase.rpc("client_remittance_summary", { p_client_organization_id: client.id }),
    supabase
      .from("remittance_statement")
      .select(
        "run_id, number, issue_date, currency, line_count, file_count, pdf_document_id, csv_document_id, csv_sha256, totals:payload->totals, status:payload->>status",
      )
      .eq("client_organization_id", client.id)
      .order("issue_date", { ascending: false })
      .order("number", { ascending: false })
      .limit(100),
  ]);
  const summary = (summaryData ?? null) as unknown as Summary | null;
  const owed = summary?.owed ?? [];
  return (
    <WidePage title="Reversements" back={back}>
      <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="remittances-client">
        {client.name} · les sommes encaissées pour votre compte et leurs reversements. Chaque reversement a son relevé (PDF)
        et le détail de chaque encaissement (CSV).
      </p>
      {error ? <InfoNote>Les reversements ne peuvent pas être affichés pour l&apos;instant. Réessayez.</InfoNote> : null}
      <Stats
        items={[
          {
            label: "À reverser à ce jour",
            value: owed.length > 0 ? owed.map((o) => money(o.owed_minor, o.currency)).join(" · ") : money("0", "EUR"),
            testId: "owed-today",
          },
          {
            label: "Prochain reversement prévu",
            value: summary?.next_run_day ? `le ${frenchDay(summary.next_run_day)}` : "—",
            testId: "next-run",
          },
        ]}
      />
      <p className="text-xs text-zinc-600 dark:text-zinc-400">
        Un reversement peut intervenir plus tôt : chaque encaissement vous est reversé au plus tard dans le délai de votre
        mandat, et jamais plus d&apos;un mois après sa réception.
      </p>
      {(summary?.in_flight ?? []).map((r) => (
        <InfoNote key={r.number}>
          Reversement {r.number} : virement de {money(r.net_minor, r.currency)} ordonné
          {r.requested_execution_date ? `, exécution demandée le ${frenchDay(r.requested_execution_date)}` : ""}.
        </InfoNote>
      ))}
      <Section title="Relevés de reversement" testId="statements">
        {(statements ?? []).length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun relevé pour l&apos;instant.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {(statements ?? []).map((s) => {
              const t = (s.totals ?? null) as unknown as Totals | null;
              return (
                <li key={s.run_id} className="flex flex-col gap-1 py-3" data-testid="statement-row">
                  <span className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-medium">
                      Relevé {s.number} du {frenchDay(s.issue_date)}
                    </span>
                    <span className="text-lg font-semibold tabular-nums">{t ? money(t.net_minor, s.currency) : "—"}</span>
                  </span>
                  <span className="flex flex-wrap items-center gap-2 text-sm text-zinc-600 dark:text-zinc-400">
                    <Badge tone={s.status === "cancelled" ? "error" : "neutral"}>
                      {runStatusText(String(s.status ?? ""), t?.net_minor ?? null)}
                    </Badge>
                    {s.line_count} encaissement(s) · {s.file_count} dossier(s)
                    {t ? ` · brut ${money(t.gross_minor, s.currency)}` : ""}
                  </span>
                  <span className="flex flex-wrap gap-4 text-sm">
                    <a
                      href={`/client/reversements/documents/${s.pdf_document_id}`}
                      className="font-medium underline underline-offset-4"
                      data-testid="statement-pdf"
                    >
                      Relevé (PDF)
                    </a>
                    <a
                      href={`/client/reversements/documents/${s.csv_document_id}`}
                      className="font-medium underline underline-offset-4"
                      data-testid="statement-csv"
                    >
                      Détail (CSV)
                    </a>
                  </span>
                  <span className="break-all text-xs text-zinc-500">CSV SHA-256 {s.csv_sha256}</span>
                </li>
              );
            })}
          </ul>
        )}
      </Section>
      <Link href="/client/factures" className="text-sm font-medium underline underline-offset-4" data-testid="client-invoices-link">
        Factures et avoirs de commission
      </Link>
    </WidePage>
  );
}
