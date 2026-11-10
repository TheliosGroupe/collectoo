import type { SessionClaims } from "@/lib/auth/access";
import type { createClient } from "@/lib/supabase/server";

type Supabase = Awaited<ReturnType<typeof createClient>>;

/**
 * The client a client-space page shows (M2c-5, OQ-48): the user's client organization, and whether the user is
 * restricted to some portfolios — such a user reads no statement, invoice or client-level amount (the database refuses
 * them too; this only words the page).
 */
export async function clientOfUser(
  supabase: Supabase,
  claims: SessionClaims,
): Promise<{ client: { id: string; name: string } | null; restricted: boolean }> {
  const user = claims.sub ?? "";
  const [{ data: memberships }, { data: access }] = await Promise.all([
    supabase.from("membership").select("organization_id, organization:organization_id(kind, legal_name)").eq("user_id", user),
    supabase.from("portfolio_access").select("portfolio_id").eq("user_id", user).limit(1),
  ]);
  const member = (memberships ?? []).find((m) => m.organization && m.organization.kind !== "servicer");
  return {
    client: member?.organization ? { id: member.organization_id, name: member.organization.legal_name } : null,
    restricted: (access ?? []).length > 0,
  };
}
