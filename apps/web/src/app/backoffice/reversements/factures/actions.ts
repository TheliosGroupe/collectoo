"use server";

import { revalidatePath } from "next/cache";
import { staffSession } from "@/lib/auth/staff";
import type { ErrorCode } from "@/lib/boarding/forms";
import {
  type CreditNotePreview,
  type FileChoice,
  REASON_CATEGORIES,
  creditNoteErrorCode,
  invoiceFilesPage,
  invoiceFilesRpc,
} from "@/lib/remittance/credit-notes";

/**
 * M2c-5b « Émettre un avoir » (design §14.1, risk R2). The effect sheet comes from `public.credit_note_preview` (the
 * command's own plan: the spread, the VAT, what it takes off the invoice); the credit note from
 * `public.issue_credit_note`, which checks the role (an admin at aal2), the compare and set on the invoice's remaining HT
 * the page showed, and the idempotency key. Errors become codes, never the database's text.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const AMOUNT = /^[\d\s  ]{1,20}([.,]\d{1,2})?$/;

function field(formData: FormData, name: string): string {
  return String(formData.get(name) ?? "").trim();
}

type Fields = { invoice: string; amount: string; account: string | null; category: string; reason: string };

function fields(formData: FormData): Fields | { error: ErrorCode } {
  const invoice = field(formData, "invoice_id");
  const amount = field(formData, "amount");
  const account = field(formData, "account_id");
  const category = field(formData, "reason_code");
  const reason = field(formData, "reason");
  if (!UUID.test(invoice) || (account && !UUID.test(account))) return { error: "unknown" };
  if (!AMOUNT.test(amount)) return { error: "credit_note_amount" };
  if (!REASON_CATEGORIES.some((c) => c.code === category)) return { error: "credit_note_category" };
  if (!reason) return { error: "reason_required" };
  return { invoice, amount, account: account || null, category, reason };
}

export type FilesResult = { ok: true; files: FileChoice[]; next: string | null } | { error: ErrorCode };

/**
 * « Charger les dossiers suivants » (review M2c-5b tests-ui#2, F4): the next page of the files the invoice still charges,
 * after the opaque key the previous page ended on (`public.commission_invoice_files`, money staff at aal2).
 */
export async function loadInvoiceFiles(invoiceId: string, after: string): Promise<FilesResult> {
  if (!UUID.test(invoiceId) || !after || after.length > 512) return { error: "unknown" };
  const { supabase } = await staffSession();
  const page = await invoiceFilesPage(invoiceFilesRpc(supabase), invoiceId, after);
  if ("error" in page) {
    console.error("invoice files failed", { error: page.error });
    return { error: creditNoteErrorCode(page.error) };
  }
  return { ok: true, ...page };
}

export type PreviewResult = { ok: true; preview: CreditNotePreview } | { error: ErrorCode };

/** « Voir l'effet »: what the credit note would be, nothing issued. */
export async function previewCreditNote(formData: FormData): Promise<PreviewResult> {
  const f = fields(formData);
  if ("error" in f) return f;
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("credit_note_preview", {
    p_invoice_id: f.invoice,
    p_amount_ht_text: f.amount,
    p_account_id: f.account ?? undefined,
  });
  if (error) {
    console.error("credit note preview failed", { error: error.message });
    return { error: creditNoteErrorCode(error.message) };
  }
  const preview = data as unknown as CreditNotePreview;
  if (preview.refusal) return { error: creditNoteErrorCode(`credit note refused: ${preview.refusal}`) };
  return { ok: true, preview };
}

export type IssueResult = { ok: true; number: string } | { error: ErrorCode };

/** « Émettre l'avoir »: numbered in the servicer's series, posted, its PDF queued. */
export async function issueCreditNote(formData: FormData): Promise<IssueResult> {
  const f = fields(formData);
  if ("error" in f) return f;
  const key = field(formData, "idempotency_key");
  const remaining = field(formData, "expected_remaining");
  if (!UUID.test(key) || !/^\d+$/.test(remaining)) return { error: "unknown" };
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("issue_credit_note", {
    p_idempotency_key: key,
    p_invoice_id: f.invoice,
    p_amount_ht_text: f.amount,
    p_reason_code: f.category,
    p_reason: f.reason,
    p_expected_remaining_text: remaining,
    p_account_id: f.account ?? undefined,
  });
  if (error) {
    console.error("credit note failed", { error: error.message });
    return { error: creditNoteErrorCode(error.message) };
  }
  revalidatePath(`/backoffice/reversements/factures/${f.invoice}`);
  return { ok: true, number: String((data as { number?: string } | null)?.number ?? "") };
}
