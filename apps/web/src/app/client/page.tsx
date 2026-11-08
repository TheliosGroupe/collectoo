import { redirect } from "next/navigation";
import { LogoutButton } from "@/components/logout";
import { Page } from "@/components/ui";
import { createClient } from "@/lib/supabase/server";

export default async function ClientPage() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims?.sub) redirect("/connexion");

  // RLS limits both queries to the user's own organization.
  const [{ data: orgs }, { data: portfolios }] = await Promise.all([
    supabase.from("organization").select("id, legal_name"),
    supabase.from("portfolio").select("id, name").order("name"),
  ]);

  return (
    <Page title="Espace client">
      <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="org-name">
        {(orgs ?? []).map((o) => o.legal_name).join(", ")}
      </p>
      <section className="rounded-lg border border-zinc-200 p-4 dark:border-zinc-800">
        <h2 className="font-medium">Vos portefeuilles</h2>
        <ul className="mt-2 list-disc pl-5 text-sm" data-testid="portfolio-list">
          {(portfolios ?? []).map((p) => (
            <li key={p.id}>{p.name}</li>
          ))}
        </ul>
      </section>
      <LogoutButton />
    </Page>
  );
}
