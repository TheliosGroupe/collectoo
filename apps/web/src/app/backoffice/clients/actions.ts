"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import { type ActionResult, parseEurosToMinor } from "@/lib/boarding/forms";
import type { Json } from "@/lib/database.types";
import { cleanTypedCode } from "@/lib/payments/iban";
import { addressFromForm, cleanSiren, identityErrorCode } from "@/lib/remittance/terms";

/**
 * M2c-2 back-office commands: billing identities, billing settings, payout accounts, client events, mandate terms.
 * Authorization (admin or ops manager at aal2, a second person for an IBAN), validation and compare and set are in the
 * SQL commands; errors become codes, never raw database text.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

function version(formData: FormData, name = "expected_version"): number | null {
  const v = field(formData, name);
  return /^\d+$/.test(v) ? Number(v) : null;
}

function done(error: { message: string } | null, ...paths: string[]): ActionResult {
  if (error) {
    console.error("identities/terms command failed", { error: error.message });
    return { error: identityErrorCode(error.message) };
  }
  for (const p of paths) revalidatePath(p);
  return { ok: true };
}

function clientPath(formData: FormData): string {
  const client = field(formData, "client_organization_id");
  return UUID.test(client) ? `/backoffice/clients/${client}/reversement` : "/backoffice/clients";
}

/** « Identité de facturation » of the servicer or of a client (admin). */
export async function saveBillingIdentity(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const org = field(formData, "organization_id");
  if (!UUID.test(key) || !UUID.test(org)) return { error: "unknown" };
  const capitalText = field(formData, "share_capital");
  const capital = capitalText ? parseEurosToMinor(capitalText) : null;
  if (capitalText && (capital === null || capital <= BigInt(0))) return { error: "capital_invalid" };
  const office = addressFromForm(formData, "office");
  if (!office) return { error: "address_invalid" };
  const identity: Record<string, unknown> = {
    legal_name: field(formData, "legal_name"),
    siren: cleanSiren(field(formData, "siren")),
    legal_form: field(formData, "legal_form"),
    share_capital_minor: capital === null ? "" : capital.toString(),
    rcs_city: field(formData, "rcs_city"),
    registered_office: office,
    billing_address: addressFromForm(formData, "billing"),
    vat_number: field(formData, "vat_number"),
    is_professional: formData.get("is_professional") === "on",
    in_liquidation: formData.get("in_liquidation") === "on",
    invoice_acceptance_ref: field(formData, "invoice_acceptance_ref"),
  };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("set_billing_identity", {
    p_idempotency_key: key,
    p_organization_id: org,
    p_identity: identity as Json,
    p_expected_version: version(formData) as unknown as number,
  });
  return done(error, "/backoffice/parametres/facturation", `/backoffice/clients/${org}/reversement`, "/backoffice/clients");
}

/** « Paramètres de facturation » (admin): prefix, own account, VAT on debits, penalty text, bank cut-offs. */
export async function saveBillingSettings(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const org = field(formData, "organization_id");
  if (!UUID.test(key) || !UUID.test(org)) return { error: "unknown" };
  const cutoff: Record<string, string> = {};
  for (const [name, value] of formData.entries()) {
    const m = /^cutoff_([0-9a-f-]{36})$/.exec(name);
    if (m && String(value).trim()) cutoff[m[1]] = String(value).trim();
  }
  const own = field(formData, "own_bank_account_id");
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("set_servicer_billing_settings", {
    p_idempotency_key: key,
    p_organization_id: org,
    p_settings: {
      invoice_prefix: field(formData, "invoice_prefix"),
      own_bank_account_id: UUID.test(own) ? own : "",
      vat_on_debits: formData.get("vat_on_debits") === "on",
      penalty_text: field(formData, "penalty_text"),
      bank_cutoff: cutoff,
    },
    p_expected_version: version(formData) as unknown as number,
  });
  return done(error, "/backoffice/parametres/facturation");
}

/** « Proposer un IBAN de reversement » (admin or ops manager): the IBAN and holder as on the client's RIB. */
export async function proposePayoutAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const client = field(formData, "client_organization_id");
  const rib = field(formData, "evidence_document_id");
  if (!UUID.test(key) || !UUID.test(client)) return { error: "unknown" };
  if (!UUID.test(rib)) return { error: "rib_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("propose_payout_account", {
    p_idempotency_key: key,
    p_client_organization_id: client,
    p_currency: field(formData, "currency") || "EUR",
    p_iban: cleanTypedCode(field(formData, "iban")),
    p_holder_name: field(formData, "holder_name"),
    p_bic: cleanTypedCode(field(formData, "bic")),
    p_evidence_document_id: rib,
    p_kind: field(formData, "kind") === "court_appointed" ? "court_appointed" : "client",
  });
  return done(error, clientPath(formData));
}

/** « Confirmer l'IBAN » as a second admin of the servicer: the IBAN typed from the RIB must be the one proposed. */
export async function confirmPayoutAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const account = field(formData, "payout_account_id");
  if (!UUID.test(key) || !UUID.test(account)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("confirm_payout_account", {
    p_idempotency_key: key,
    p_payout_account_id: account,
    p_iban_typed: cleanTypedCode(field(formData, "iban_typed")),
  });
  return done(error, clientPath(formData));
}

export async function rejectPayoutAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const account = field(formData, "payout_account_id");
  if (!UUID.test(key) || !UUID.test(account)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("reject_payout_account", {
    p_idempotency_key: key,
    p_payout_account_id: account,
    p_reason: field(formData, "reason"),
  });
  return done(error, clientPath(formData));
}

export async function retirePayoutAccount(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const account = field(formData, "payout_account_id");
  if (!UUID.test(key) || !UUID.test(account)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("retire_payout_account", {
    p_idempotency_key: key,
    p_payout_account_id: account,
    p_reason: field(formData, "reason"),
  });
  return done(error, clientPath(formData));
}

/** « Enregistrer un événement » (admin): procedure, liquidation, death, guardianship, end of the mandate. */
export async function recordClientEvent(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const client = field(formData, "client_organization_id");
  const evidence = field(formData, "evidence_document_id");
  const date = field(formData, "effective_date");
  const payout = field(formData, "payout_account_id");
  if (!UUID.test(key) || !UUID.test(client) || !DATE.test(date)) return { error: "unknown" };
  if (!UUID.test(evidence)) return { error: "evidence_required" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("record_client_status_event", {
    p_idempotency_key: key,
    p_client_organization_id: client,
    p_kind: field(formData, "kind"),
    p_effective_date: date,
    p_evidence_document_id: evidence,
    p_note: field(formData, "note"),
    p_payout_account_id: (UUID.test(payout) ? payout : null) as unknown as string,
  });
  return done(error, clientPath(formData));
}

/** « Nouvelles conditions financières » (admin): a version from a day not passed, with its clauses and document. */
export async function setMandateTerms(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const mandate = field(formData, "mandate_id");
  const from = field(formData, "valid_from");
  const doc = field(formData, "document_id");
  const latest = field(formData, "expected_latest_id");
  if (!UUID.test(key) || !UUID.test(mandate) || !DATE.test(from)) return { error: "unknown" };
  if (!UUID.test(doc)) return { error: "terms_document_required" };
  let schedule: unknown;
  try {
    schedule = JSON.parse(field(formData, "commission_schedule"));
  } catch {
    return { error: "schedule_json" };
  }
  const netting = field(formData, "netting_clause");
  const clawback = field(formData, "clawback_clause");
  const weekly = field(formData, "frequency") === "weekly";
  const days = field(formData, "invoice_payment_days");
  const maxDays = field(formData, "remittance_max_days");
  const terms: Record<string, unknown> = {
    schema: "remittance-1",
    frequency: weekly ? "weekly" : "twice_monthly",
    netting: netting ? { clause_ref: netting } : null,
    clawback: clawback ? { clause_ref: clawback } : null,
    invoice_payment_days: /^\d{1,3}$/.test(days) ? Number(days) : -1,
  };
  if (weekly) terms.weekday = Number(field(formData, "weekday"));
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("set_mandate_terms", {
    p_idempotency_key: key,
    p_mandate_id: mandate,
    p_valid_from: from,
    p_commission_schedule: schedule as Json,
    p_commission_clause_ref: field(formData, "commission_clause_ref"),
    p_remittance_terms: terms as Json,
    p_remittance_clause_ref: field(formData, "remittance_clause_ref"),
    p_document_id: doc,
    p_remittance_max_days: /^\d{1,3}$/.test(maxDays) ? Number(maxDays) : 0,
    p_expected_latest_id: (UUID.test(latest) ? latest : null) as unknown as string,
  });
  return done(error, clientPath(formData), "/backoffice/clients");
}

/** « Clause de garantie » (R124-3 2°; admin): compare and set on the value shown. */
export async function setInsuranceClause(formData: FormData): Promise<ActionResult> {
  const key = field(formData, "idempotency_key");
  const mandate = field(formData, "mandate_id");
  if (!UUID.test(key) || !UUID.test(mandate)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { error } = await supabase.rpc("set_mandate_insurance_clause", {
    p_idempotency_key: key,
    p_mandate_id: mandate,
    p_clause_ref: field(formData, "clause_ref"),
    p_expected: (field(formData, "expected") || null) as unknown as string,
  });
  return done(error, clientPath(formData), "/backoffice/clients");
}
