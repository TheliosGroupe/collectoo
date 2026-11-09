import Link from "next/link";
import { redirect } from "next/navigation";
import { LogoutButton } from "@/components/logout";
import { Page, buttonClass } from "@/components/ui";
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
      <Link href="/backoffice/reprises" className={buttonClass + " text-center"} data-testid="boarding-link">
        Reprises de portefeuilles
      </Link>
      <Link
        href="/backoffice/encaissements"
        className="w-full rounded-md border border-zinc-300 px-4 py-2 text-center font-medium hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
        data-testid="statements-link"
      >
        Relevés bancaires
      </Link>
      <Link
        href="/backoffice/encaissements/a-traiter"
        className="w-full rounded-md border border-zinc-300 px-4 py-2 text-center font-medium hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
        data-testid="payments-queue-link"
      >
        Paiements à traiter
      </Link>
      <Link
        href="/backoffice/parametres/comptes-bancaires"
        className="w-full rounded-md border border-zinc-300 px-4 py-2 text-center font-medium hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
        data-testid="bank-accounts-link"
      >
        Comptes bancaires
      </Link>
      <LogoutButton />
    </Page>
  );
}
