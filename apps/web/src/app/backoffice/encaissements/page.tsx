import Link from "next/link";
import { InfoNote, Section, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { type StatementRow, STATEMENT_COLUMNS, StatementSummary } from "./statement-summary";
import { type BankAccountOption, StatementUploadForm } from "./upload-form";

/**
 * M2b-2 « Relevés »: statements of the client-funds accounts (CPCE R124-2). Each import books the
 * debtors' payments of every statement day at once (founder decision #1); debits and held lines wait
 * for later slices. Admins and ops managers only (third-party payer data, decision #18).
 */
export default async function StatementsPage() {
  const { supabase, claims } = await staffSession();
  const [{ data: memberships }, { data: accounts }, { data: statements }] = await Promise.all([
    supabase
      .from("membership")
      .select("role, organization:organization_id(kind)")
      .eq("user_id", claims.sub ?? ""),
    supabase.from("bank_account").select("id, label, iban, feed, currency, status").eq("status", "active").order("label"),
    supabase.from("bank_statement").select(STATEMENT_COLUMNS).order("created_at", { ascending: false }).limit(50),
  ]);
  const staff = (memberships ?? []).find((m) => m.organization?.kind === "servicer");
  const canImport = staff?.role === "admin" || staff?.role === "ops_manager";
  const options: BankAccountOption[] = (accounts ?? []).map((a) => ({
    id: a.id,
    label: a.label,
    feed: a.feed,
    currency: a.currency,
    ibanEnd: a.iban.slice(-4),
  }));
  const rows = (statements ?? []) as unknown as StatementRow[];

  return (
    <WidePage title="Relevés bancaires" back={{ href: "/backoffice", label: "Back-office" }}>
      {!canImport ? (
        <InfoNote>Les relevés bancaires sont réservés aux administrateurs et aux responsables des opérations.</InfoNote>
      ) : (
        <>
          <InfoNote>
            Chaque import comptabilise aussitôt, jour par jour, les virements reçus sur le compte de fonds de tiers (art. R124-2
            CPCE), en attente d&apos;affectation à un dossier. Un même fichier, ou les opérations déjà importées d&apos;un
            relevé qui chevauche, ne sont jamais comptés deux fois.
          </InfoNote>
          <Section title="Importer un relevé" testId="import-statement">
            <StatementUploadForm accounts={options} />
          </Section>
          {rows.length === 0 ? (
            <InfoNote>Aucun relevé importé pour l&apos;instant.</InfoNote>
          ) : (
            <ul className="flex flex-col gap-4" data-testid="statement-list">
              {rows.map((s) => (
                <li key={s.id} className="rounded-lg border border-zinc-200 p-4 dark:border-zinc-800">
                  <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
                    <Link
                      href={`/backoffice/encaissements/releves/${s.id}`}
                      className="font-medium break-all underline-offset-4 hover:underline"
                    >
                      {s.file_name}
                    </Link>
                    <span className="text-xs text-zinc-600 dark:text-zinc-400">
                      déposé le {new Date(s.created_at).toLocaleDateString("fr-FR", { timeZone: "Europe/Paris" })}
                    </span>
                  </div>
                  <StatementSummary s={s} />
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </WidePage>
  );
}
