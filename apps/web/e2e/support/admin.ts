import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";

/**
 * Test-only admin client (service role) for fixtures against the LOCAL stack.
 * The local secret key is the Supabase CLI default, never a real credential.
 */
export function adminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "http://127.0.0.1:54321";
  const key = process.env.SUPABASE_SECRET_KEY;
  if (!key) throw new Error("SUPABASE_SECRET_KEY must be set for E2E fixtures (see `supabase status`)");
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

export type Tenant = { servicerId: string; clientId: string; clientName: string; portfolioName: string };

export async function createTenant(): Promise<Tenant> {
  const admin = adminClient();
  const run = randomUUID().slice(0, 8);
  const { data: servicer, error: e1 } = await admin
    .from("organization")
    .insert({ kind: "servicer", legal_name: `Collectoo E2E ${run}` })
    .select("id")
    .single();
  if (e1) throw e1;
  const clientName = `Boulangerie Durand ${run}`;
  const { data: client, error: e2 } = await admin
    .from("organization")
    .insert({ kind: "creditor_client", legal_name: clientName, servicer_organization_id: servicer.id })
    .select("id")
    .single();
  if (e2) throw e2;
  const portfolioName = "Factures impayées 2026";
  const { error: e3 } = await admin
    .from("portfolio")
    .insert({ organization_id: servicer.id, client_organization_id: client.id, name: portfolioName });
  if (e3) throw e3;
  return { servicerId: servicer.id, clientId: client.id, clientName, portfolioName };
}

export async function createMember(
  organizationId: string,
  role: "admin" | "ops_manager" | "collector" | "client_admin" | "client_viewer",
): Promise<string> {
  const admin = adminClient();
  const email = `${role}-${randomUUID().slice(0, 8)}@e2e.test`;
  const { data, error } = await admin.auth.admin.createUser({ email, email_confirm: true });
  if (error) throw error;
  const { error: e2 } = await admin
    .from("membership")
    .insert({ user_id: data.user.id, organization_id: organizationId, role });
  if (e2) throw e2;
  return email;
}
