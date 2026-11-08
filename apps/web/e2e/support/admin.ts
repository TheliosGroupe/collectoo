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

export type Tenant = {
  servicerId: string;
  clientId: string;
  clientName: string;
  portfolioId: string;
  portfolioName: string;
};

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
  const { data: portfolio, error: e3 } = await admin
    .from("portfolio")
    .insert({ organization_id: servicer.id, client_organization_id: client.id, name: portfolioName })
    .select("id")
    .single();
  if (e3) throw e3;
  return { servicerId: servicer.id, clientId: client.id, clientName, portfolioId: portfolio.id, portfolioName };
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

/** A signed amicable-collection mandate covering the tenant's portfolio (CPCE R124-3). */
export async function createMandate(tenant: Tenant): Promise<void> {
  const admin = adminClient();
  const { data: mandate, error } = await admin
    .from("mandate")
    .insert({
      organization_id: tenant.servicerId,
      client_organization_id: tenant.clientId,
      reference: `MAND-${randomUUID().slice(0, 8)}`,
      mandate_type: "mandate_amicable",
      signed_on: "2026-01-15",
    })
    .select("id")
    .single();
  if (error) throw error;
  const { error: e2 } = await admin
    .from("mandate_terms")
    .insert({ mandate_id: mandate.id, valid_from: "2026-01-15", commission_rate: 0.15 });
  if (e2) throw e2;
  const { error: e3 } = await admin.from("portfolio").update({ mandate_id: mandate.id }).eq("id", tenant.portfolioId);
  if (e3) throw e3;
}

/**
 * Makes a staged batch's report disagree with its rows, so the commit job refuses it (LG005):
 * the way to show the commit-failure note without a broken tape.
 */
export async function tamperStagedOpening(batchId: string): Promise<void> {
  const admin = adminClient();
  const { data, error } = await admin.from("boarding_batch").select("dq_report").eq("id", batchId).single();
  if (error) throw error;
  const report = data.dq_report as { staging: { opening: { currencies: Record<string, { outstanding_minor: string }> } } };
  for (const c of Object.values(report.staging.opening.currencies)) c.outstanding_minor = "1";
  const { error: e2 } = await admin.from("boarding_batch").update({ dq_report: report }).eq("id", batchId);
  if (e2) throw e2;
}
