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

/** Synthetic identifiers (Luhn-valid SIRENs, their VAT key) for E2E tenants; no real company. */
export const SERVICER_SIREN = "849678297";
export const SERVICER_VAT = "FR33849678297";
export const CLIENT_SIREN = "825944093";
const OFFICE = { line1: "10 rue de la Bourse", postcode: "75002", city: "Paris", country: "FR" };

/** The servicer's billing identity, complete (what receipts, statements and invoices print; M2c-2). */
export async function createServicerIdentity(tenant: Tenant): Promise<void> {
  const admin = adminClient();
  const { error } = await admin.from("organization").update({ siren: SERVICER_SIREN }).eq("id", tenant.servicerId);
  if (error) throw error;
  const { error: e2 } = await admin.from("billing_identity").upsert({
    organization_id: tenant.servicerId,
    legal_form: "SAS",
    share_capital_minor: "1000000", // bigint minor units as text, never a JS number
    rcs_city: "Paris",
    registered_office: OFFICE,
    vat_number: SERVICER_VAT,
    is_professional: true,
  });
  if (e2) throw e2;
}

/** A client document row (a RIB, the signed mandate, an evidence) without a stored file. */
export async function createClientDocument(tenant: Tenant, kind: string, fileName: string): Promise<string> {
  const admin = adminClient();
  const id = randomUUID();
  const { error } = await admin.from("document").insert({
    id,
    organization_id: tenant.servicerId,
    client_organization_id: tenant.clientId,
    kind,
    storage_bucket: "documents",
    storage_path: `client/${tenant.servicerId}/${tenant.clientId}/${id}.pdf`,
    sha256: "a".repeat(64),
    mime_type: "application/pdf",
    file_name: fileName,
  });
  if (error) throw error;
  return id;
}

/**
 * A signed amicable-collection mandate covering the tenant's portfolio (CPCE R124-3), ready for confirmation (M2c-2,
 * design §9.1): its money terms (commission-1, remittance-1) with their clause references and the signed document, the
 * insurance clause, and both billing identities (the client a professional established in mainland France).
 * `complete: false` writes a version as before M2c-2 (a rate only): the portfolio is then not ready. `netting: false`
 * writes no netting clause (M2c-5b's spec: an invoice no payout sets off, so a manual credit note can rectify it).
 */
export async function createMandate(
  tenant: Tenant,
  { complete = true, netting = true }: { complete?: boolean; netting?: boolean } = {},
): Promise<string> {
  const admin = adminClient();
  const { data: mandate, error } = await admin
    .from("mandate")
    .insert({
      organization_id: tenant.servicerId,
      client_organization_id: tenant.clientId,
      reference: `MAND-${randomUUID().slice(0, 8)}`,
      mandate_type: "mandate_amicable",
      signed_on: "2026-01-15",
      insurance_clause_ref: complete ? "art. 9 — Garantie" : null,
    })
    .select("id")
    .single();
  if (error) throw error;
  const terms = complete
    ? {
        commission_schedule: {
          schema: "commission-1",
          basis: {
            families: "all",
            forwards: { file_recalled: false, before_servicing_start: false, client_ratification: false },
            on_reversal: "credit",
          },
          rules: [{ id: "tout", tier_key: "tout", label_fr: "Toutes créances", match: {}, rate: { kind: "flat", rate: "0.15" } }],
        },
        commission_clause_ref: "art. 6 — Rémunération",
        remittance_terms: {
          schema: "remittance-1",
          frequency: "twice_monthly",
          // without a netting clause the invoices are due to the own account (none is set off on a payout)
          netting: netting ? { clause_ref: "art. 7.2" } : null,
          clawback: null,
          invoice_payment_days: 30,
        },
        remittance_clause_ref: "art. 7 — Reversements",
        document_id: await createClientDocument(tenant, "mandate_document", "Mandat signé.pdf"),
      }
    : { commission_rate: 0.15 };
  const { error: e2 } = await admin.from("mandate_terms").insert({ mandate_id: mandate.id, valid_from: "2026-01-15", ...terms });
  if (e2) throw e2;
  const { error: e3 } = await admin.from("portfolio").update({ mandate_id: mandate.id }).eq("id", tenant.portfolioId);
  if (e3) throw e3;
  await createServicerIdentity(tenant);
  if (complete) {
    const { error: e4 } = await admin.from("organization").update({ siren: CLIENT_SIREN }).eq("id", tenant.clientId);
    if (e4) throw e4;
    const { error: e5 } = await admin.from("billing_identity").upsert({
      organization_id: tenant.clientId,
      registered_office: { line1: "12 rue des Artisans", postcode: "69003", city: "Lyon", country: "FR" },
      is_professional: true,
    });
    if (e5) throw e5;
  }
  return mandate.id as string;
}

/** The app user id of a member created by createMember (its email). */
export async function userId(email: string): Promise<string> {
  const { data, error } = await adminClient().from("app_user").select("id").eq("email", email).single();
  if (error) throw error;
  return data.id as string;
}

/**
 * An event recorded for the tenant's client (review M2c-2: a mandate end, a death or a liquidation keeps its portfolios
 * from being confirmed), with its evidence, as « Enregistrer un événement » records it.
 */
export async function recordClientEvent(
  tenant: Tenant,
  kind: "proceeding_opened" | "liquidation" | "death" | "guardianship" | "mandate_ended",
  effectiveDate: string,
  recordedBy: string,
): Promise<void> {
  const evidence = await createClientDocument(tenant, "client_status_evidence", `Justificatif ${kind}.pdf`);
  const { error } = await adminClient().from("client_status_event").insert({
    organization_id: tenant.servicerId,
    client_organization_id: tenant.clientId,
    kind,
    effective_date: effectiveDate,
    evidence_document_id: evidence,
    recorded_by: await userId(recordedBy),
  });
  if (error) throw error;
}

/**
 * The client's payout IBAN, proposed by one admin of the servicer with the client's RIB and confirmed by another
 * (founder #10), as the pages do it: a credit from it is then read as the client's at import (`client_transfer_in`).
 */
export async function createConfirmedPayoutAccount(tenant: Tenant, iban: string, holder: string): Promise<void> {
  const admin = adminClient();
  const proposer = await userId(await createMember(tenant.servicerId, "admin"));
  const confirmer = await userId(await createMember(tenant.servicerId, "admin"));
  const { data, error } = await admin
    .from("client_payout_account")
    .insert({
      organization_id: tenant.servicerId,
      client_organization_id: tenant.clientId,
      currency: "EUR",
      iban,
      holder_name: holder,
      evidence_document_id: await createClientDocument(tenant, "payout_rib", "RIB client.pdf"),
      proposed_by: proposer,
    })
    .select("id")
    .single();
  if (error) throw error;
  const { error: e2 } = await admin
    .from("client_payout_account")
    .update({ status: "active", confirmed_by: confirmer, confirmed_at: new Date().toISOString(), confirmed_via: "second_admin" })
    .eq("id", data.id);
  if (e2) throw e2;
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
