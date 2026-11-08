import Link from "next/link";
import { Badge, InfoNote, WidePage, inlineButtonClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { statusLabel, statusTone } from "@/lib/boarding/status";

/** M1-19: boarding batches of the servicer's clients, newest first (read through RLS). */
export default async function BoardingListPage() {
  const { supabase } = await staffSession();
  const { data: batches } = await supabase
    .from("boarding_batch")
    .select("id, version, status, created_at, cut_off_date, portfolio:portfolio_id(name), client:client_organization_id(legal_name)")
    .order("created_at", { ascending: false })
    .limit(100);

  return (
    <WidePage
      title="Reprises de portefeuilles"
      back={{ href: "/backoffice", label: "Back-office" }}
      actions={
        <Link href="/backoffice/reprises/nouveau" className={inlineButtonClass}>
          Nouveau lot
        </Link>
      }
    >
      {(batches ?? []).length === 0 ? (
        <InfoNote>Aucun lot pour l&apos;instant. Créez-en un pour déposer les fichiers d&apos;un cédant.</InfoNote>
      ) : (
        <ul className="divide-y divide-zinc-200 rounded-lg border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800" data-testid="batch-list">
          {(batches ?? []).map((b) => (
            <li key={b.id}>
              <Link
                href={`/backoffice/reprises/${b.id}`}
                className="flex flex-col gap-1 p-4 hover:bg-zinc-50 sm:flex-row sm:items-center sm:justify-between dark:hover:bg-zinc-900"
              >
                <span>
                  <span className="font-medium">{b.client?.legal_name}</span>
                  <span className="text-zinc-600 dark:text-zinc-400">
                    {" "}
                    · {b.portfolio?.name} · lot n° {b.version}
                  </span>
                </span>
                <span className="flex items-center gap-3 text-sm text-zinc-600 dark:text-zinc-400">
                  {new Date(b.created_at).toLocaleDateString("fr-FR", { timeZone: "Europe/Paris" })}
                  <Badge tone={statusTone(b.status)}>{statusLabel(b.status)}</Badge>
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </WidePage>
  );
}
