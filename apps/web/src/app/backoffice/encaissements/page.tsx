import Link from "next/link";
import { InfoNote, Section, WidePage, buttonClass, inputClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import {
  STATEMENT_PAGE_SIZE,
  STATEMENT_STATUS_FILTERS,
  statementListHref,
  statementListQuery,
} from "@/lib/payments/statements";
import { type MatchCounts, type StatementRow, STATEMENT_COLUMNS, StatementSummary } from "./statement-summary";
import { type BankAccountOption, StatementUploadForm } from "./upload-form";

/**
 * M2b-2 « Relevés »: statements of the client-funds accounts (CPCE R124-2). Each import books the
 * debtors' payments of every statement day at once (founder decision #1); debits and held lines wait
 * for later slices. Admins and ops managers only (third-party payer data, decision #18). The list is
 * paged and can be narrowed to one bank account or status, so no statement goes out of reach.
 */
export default async function StatementsPage({ searchParams }: PageProps<"/backoffice/encaissements">) {
  const q = statementListQuery(await searchParams);
  const { supabase, claims } = await staffSession();
  let list = supabase.from("bank_statement").select(STATEMENT_COLUMNS, { count: "exact" });
  if (q.compte) list = list.eq("bank_account_id", q.compte);
  const statuses = STATEMENT_STATUS_FILTERS[q.statut].statuses;
  if (statuses) list = list.in("status", statuses);
  const from = (q.page - 1) * STATEMENT_PAGE_SIZE;
  const [{ data: memberships }, { data: accounts }, { data: statements, count }] = await Promise.all([
    supabase
      .from("membership")
      .select("role, organization:organization_id(kind)")
      .eq("user_id", claims.sub ?? ""),
    supabase.from("bank_account").select("id, label, iban, feed, currency, status").order("label"),
    list.order("created_at", { ascending: false }).range(from, from + STATEMENT_PAGE_SIZE - 1),
  ]);
  const staff = (memberships ?? []).find((m) => m.organization?.kind === "servicer");
  const canImport = staff?.role === "admin" || staff?.role === "ops_manager";
  const options: BankAccountOption[] = (accounts ?? [])
    .filter((a) => a.status === "active")
    .map((a) => ({ id: a.id, label: a.label, feed: a.feed, currency: a.currency, ibanEnd: a.iban.slice(-4) }));
  const rows = (statements ?? []) as unknown as StatementRow[];
  const total = count ?? 0;
  const { data: matchRows } = rows.length
    ? await supabase.rpc("statement_match_counts", { p_statement_ids: rows.map((r) => r.id) })
    : { data: [] };
  const matches = new Map<string, MatchCounts>((matchRows ?? []).map((m) => [m.statement_id, m]));
  // M2b-6: debits to classify, and the last nightly check (anomalies, alerts)
  const [{ data: debitRows }, { data: lastRun }] = canImport
    ? await Promise.all([
        supabase.rpc("debit_queue", { p_tab: "a-classer", p_offset: 0, p_limit: 1 }),
        supabase.from("payment_check_run").select("violations, alerts").order("started_at", { ascending: false }).limit(1),
      ])
    : [{ data: [] }, { data: [] }];
  const toClassify = Number(((debitRows ?? []) as { total: number }[])[0]?.total ?? 0);
  const run = ((lastRun ?? []) as { violations: number | null; alerts: number | null }[])[0];
  const filtered = q.compte !== null || q.statut !== "tous";

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
          <Link href="/backoffice/encaissements/a-traiter" className={`${buttonClass} text-center`} data-testid="queue-link">
            Paiements à traiter
          </Link>
          <div className="grid gap-2 sm:grid-cols-2">
            <Link
              href="/backoffice/encaissements/debits"
              className="rounded-md border border-zinc-300 px-3 py-2 text-center text-sm dark:border-zinc-700"
              data-testid="debits-link"
            >
              Débits et retours{toClassify > 0 ? ` · ${toClassify} à classer` : ""}
            </Link>
            <Link
              href="/backoffice/encaissements/controles"
              className="rounded-md border border-zinc-300 px-3 py-2 text-center text-sm dark:border-zinc-700"
              data-testid="checks-link"
            >
              Contrôles
              {run ? ` · ${run.violations ?? 0} anomalie(s), ${run.alerts ?? 0} alerte(s)` : ""}
            </Link>
          </div>
          <Section title="Importer un relevé" testId="import-statement">
            <StatementUploadForm accounts={options} />
          </Section>
          {total > 0 || filtered ? (
            <form
              method="get"
              action="/backoffice/encaissements"
              className="flex flex-wrap items-end gap-3"
              aria-label="Filtrer les relevés"
              data-testid="statement-filters"
            >
              <label className="flex min-w-0 flex-1 basis-48 flex-col gap-1 text-sm">
                Compte bancaire
                <select name="compte" defaultValue={q.compte ?? ""} className={inputClass}>
                  <option value="">Tous les comptes</option>
                  {(accounts ?? []).map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.label} · …{a.iban.slice(-4)}
                      {a.status === "closed" ? " (clôturé)" : ""}
                    </option>
                  ))}
                </select>
              </label>
              <label className="flex min-w-0 flex-1 basis-40 flex-col gap-1 text-sm">
                Statut
                <select name="statut" defaultValue={q.statut} className={inputClass}>
                  {Object.entries(STATEMENT_STATUS_FILTERS).map(([key, f]) => (
                    <option key={key} value={key}>
                      {f.label}
                    </option>
                  ))}
                </select>
              </label>
              <button type="submit" className={buttonClass}>
                Filtrer
              </button>
            </form>
          ) : null}
          {rows.length === 0 ? (
            <InfoNote>
              {filtered ? "Aucun relevé ne correspond à ces filtres." : "Aucun relevé importé pour l'instant."}
            </InfoNote>
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
                  <StatementSummary s={s} match={matches.get(s.id)} />
                </li>
              ))}
            </ul>
          )}
          {total > STATEMENT_PAGE_SIZE ? (
            <nav className="flex items-center justify-between gap-3 text-sm" aria-label="Pages" data-testid="statement-pages">
              {q.page > 1 ? <Link href={statementListHref(q, q.page - 1)}>← Plus récents</Link> : <span />}
              <span className="text-zinc-600 dark:text-zinc-400">
                {from + 1}–{Math.min(from + STATEMENT_PAGE_SIZE, total)} sur {total}
              </span>
              {from + STATEMENT_PAGE_SIZE < total ? (
                <Link href={statementListHref(q, q.page + 1)}>Plus anciens →</Link>
              ) : (
                <span />
              )}
            </nav>
          ) : null}
        </>
      )}
    </WidePage>
  );
}
