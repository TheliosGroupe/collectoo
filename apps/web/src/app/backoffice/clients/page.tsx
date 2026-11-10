import Link from "next/link";
import { Badge, InfoNote, Section, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";

/**
 * M2c-2: the servicer's clients, each with what still keeps one of its portfolios from being confirmed (design §9.1:
 * identities and the mandate's money terms) and a link to its page (identity, payout IBAN, terms, events).
 */
export default async function ClientsPage() {
  const { supabase } = await staffSession();
  const { data: orgs } = await supabase
    .from("organization")
    .select("id, legal_name, kind")
    .neq("kind", "servicer")
    .order("legal_name");
  const clients = orgs ?? [];
  const readiness = await Promise.all(
    clients.map(async (c) => {
      const { data } = await supabase.rpc("client_readiness", { p_client_organization_id: c.id });
      const rows = (data ?? []) as { portfolio_id: string; blockers: string[] }[];
      return { id: c.id, portfolios: rows.length, blocked: rows.filter((r) => r.blockers.length > 0).length };
    }),
  );
  const byId = new Map(readiness.map((r) => [r.id, r]));
  return (
    <WidePage title="Clients" back={{ href: "/backoffice", label: "Back-office" }}>
      {clients.length === 0 ? (
        <InfoNote>Aucun client pour l&apos;instant.</InfoNote>
      ) : (
        <Section title="Clients du cabinet" testId="clients">
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {clients.map((c) => {
              const r = byId.get(c.id);
              return (
                <li key={c.id} className="flex flex-wrap items-center justify-between gap-2 py-3" data-testid="client-row">
                  <Link href={`/backoffice/clients/${c.id}/reversement`} className="font-medium underline underline-offset-4">
                    {c.legal_name}
                  </Link>
                  {r && r.portfolios > 0 && r.blocked === 0 ? (
                    <Badge tone="ok">Prêt</Badge>
                  ) : r && r.blocked > 0 ? (
                    <Badge tone="action">
                      {r.blocked} portefeuille{r.blocked > 1 ? "s" : ""} à compléter
                    </Badge>
                  ) : (
                    <Badge tone="neutral">Aucun portefeuille</Badge>
                  )}
                </li>
              );
            })}
          </ul>
        </Section>
      )}
    </WidePage>
  );
}
