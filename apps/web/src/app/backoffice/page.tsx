import { redirect } from "next/navigation";
import { LogoutButton } from "@/components/logout";
import { Page } from "@/components/ui";
import type { SessionClaims } from "@/lib/auth/access";
import { createClient } from "@/lib/supabase/server";

export default async function BackofficePage() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const claims = (data?.claims ?? null) as (SessionClaims & { email?: string }) | null;
  if (!claims?.sub) redirect("/connexion");
  if (claims.aal !== "aal2") redirect("/mfa");

  // Read through RLS: staff see their tenant's organizations and portfolios only.
  const [{ data: orgs }, { count }] = await Promise.all([
    supabase.from("organization").select("id, legal_name, kind").order("legal_name"),
    supabase.from("portfolio").select("id", { count: "exact", head: true }),
  ]);
  const clients = (orgs ?? []).filter((o) => o.kind !== "servicer");

  return (
    <Page title="Back-office">
      <p className="text-sm text-zinc-600 dark:text-zinc-400">Connecté : {claims.email}</p>
      <section className="rounded-lg border border-zinc-200 p-4 dark:border-zinc-800">
        <h2 className="font-medium">Clients</h2>
        <ul className="mt-2 list-disc pl-5 text-sm" data-testid="client-list">
          {clients.map((o) => (
            <li key={o.id}>{o.legal_name}</li>
          ))}
        </ul>
        <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">Portefeuilles : {count ?? 0}</p>
      </section>
      <LogoutButton />
    </Page>
  );
}
