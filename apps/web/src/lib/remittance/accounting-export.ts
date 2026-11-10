import type { Database } from "@/lib/database.types";
import { csvAmount, csvFile } from "./documents";

/**
 * M2c-5 (design §14.2): the accountant's export — the invoices and credit notes of a period with their settlements, or
 * the postings of the servicer's books — as CSV. Pure, so the paging and the CSV are unit-tested; the route only opens
 * the staff session and serves the text.
 *
 * Review M2c-5 (perf#0 = tests-ui#0, contract K1): PostgREST cuts every answer at `max_rows` (1,000), an RPC's too, and
 * answers 206 as a success: one call silently dropped the rest of the period. Both SQL functions take `p_after` (the
 * last row's opaque `page_key`) and `p_limit` (≤ 1,000) and return keyset-ordered pages; the export asks page after
 * page until one comes back shorter than the limit, and refuses the whole file when any page fails, so a CSV is never
 * cut short.
 */

/** One page per call, never more than PostgREST's `max_rows` (supabase/config.toml). */
export const EXPORT_PAGE_SIZE = 1000;

type Functions = Database["public"]["Functions"];
/** A row of `accounting_export_documents`, with its keyset position (K1). */
export type ExportDocumentRow = Functions["accounting_export_documents"]["Returns"][number] & { page_key: string };
/** A row of `accounting_export_entries`, with its keyset position (K1). */
export type ExportEntryRow = Functions["accounting_export_entries"]["Returns"][number] & { page_key: string };

export type ExportKind = "factures" | "ecritures";
export type ExportError = { code?: string; message?: string };
type Page<T> = { data: T[] | null; error: ExportError | null };

/** The two export functions, called with the user's session (money staff at aal2: the database decides). */
export type ExportRpc = (
  fn: "accounting_export_documents" | "accounting_export_entries",
  args: { p_from: string; p_to: string; p_after: string | null; p_limit: number },
) => PromiseLike<Page<unknown>>;

/**
 * Every row of a keyset-paged RPC: pages of `limit` rows, each asked after the previous page's last `page_key`, until
 * a page is shorter than `limit`. A failing page fails the whole read (no partial file); a page whose last key does
 * not move on would loop forever and fails it too.
 */
export async function fetchAllPages<T extends { page_key: string }>(
  fetchPage: (after: string | null, limit: number) => PromiseLike<Page<T>>,
  limit = EXPORT_PAGE_SIZE,
): Promise<{ rows: T[]; error: null } | { rows: null; error: ExportError }> {
  const rows: T[] = [];
  let after: string | null = null;
  for (;;) {
    const { data, error } = await fetchPage(after, limit);
    if (error) return { rows: null, error };
    const page = data ?? [];
    rows.push(...page);
    if (page.length < limit) return { rows, error: null };
    const last = page[page.length - 1].page_key;
    if (!last || last === after) return { rows: null, error: { message: "export page key did not advance" } };
    after = last;
  }
}

const s = (v: unknown) => (v === null || v === undefined ? "" : String(v));

export const EXPORT_DOCUMENT_HEADER = [
  "numero",
  "type",
  "date_emission",
  "client",
  "siren_client",
  "mandat",
  "releve",
  "periode_du",
  "periode_au",
  "montant_ht",
  "montant_ht_centimes",
  "taux_tva",
  "tva",
  "tva_centimes",
  "montant_ttc",
  "montant_ttc_centimes",
  "tva_compte",
  "reglement",
  "echeance",
  "rectifie",
  "regle_centimes",
  "reglements",
  "reste_du_centimes",
] as const;

/**
 * Review M2c-5 (security#0 = tests-ui#6, contract K3): the text columns, named one by one — a cell of these that
 * starts with = + - @ TAB or CR is written behind an apostrophe so a spreadsheet never runs it as a formula. The
 * other columns (dates, amounts, cents, the VAT rate) are never altered: a negative amount stays « -12,34 ».
 */
export const EXPORT_DOCUMENT_TEXT_COLUMNS: ReadonlySet<string> = new Set([
  "numero",
  "type",
  "client",
  "siren_client",
  "mandat",
  "releve",
  "tva_compte",
  "reglement",
  "rectifie",
  "reglements",
]);

export const EXPORT_ENTRY_HEADER = [
  "date",
  "ecriture",
  "type",
  "piece_type",
  "piece",
  "client",
  "compte",
  "libelle_compte",
  "debit",
  "debit_centimes",
  "credit",
  "credit_centimes",
  "devise",
  "enregistree_le",
] as const;

/** K3: the text columns of the entries' CSV (the dates, the posting time and the amounts are not among them). */
export const EXPORT_ENTRY_TEXT_COLUMNS: ReadonlySet<string> = new Set([
  "ecriture",
  "type",
  "piece_type",
  "piece",
  "client",
  "compte",
  "libelle_compte",
  "devise",
]);

export const BOOK_LABEL: Record<string, string> = {
  servicer_revenue: "Commissions de recouvrement",
  vat_collected: "TVA collectée",
  vat_pending: "TVA en attente d'exigibilité",
  bank_fees: "Frais bancaires",
  servicer_losses: "Pertes du cabinet",
  commission_receivable: "Mandants — factures et avoirs",
  client_advance_receivable: "Mandants — avances",
  own_cash: "Compte propre (mouvements constatés)",
};

export const DOC_TYPE: Record<string, string> = { invoice: "facture", credit_note: "avoir" };

/** The invoices and credit notes of the period, one row each, in the series' order. */
export function exportDocumentsCsv(rows: readonly ExportDocumentRow[]): string {
  return csvFile(
    EXPORT_DOCUMENT_HEADER,
    rows.map((r) => [
      r.number,
      DOC_TYPE[r.kind] ?? r.kind,
      r.issue_date,
      r.client_name,
      r.client_siren,
      r.mandate,
      r.run_number,
      r.service_from,
      r.service_to,
      csvAmount(r.ht_minor),
      s(r.ht_minor),
      r.vat_rate === null ? "" : s(r.vat_rate).replace(".", ","),
      csvAmount(r.vat_minor),
      s(r.vat_minor),
      csvAmount(r.ttc_minor),
      s(r.ttc_minor),
      r.vat_book === "vat_collected" ? "44571" : r.vat_book === "vat_pending" ? "44574" : "",
      r.settlement === "netted" ? "compensation" : "a_regler",
      r.due_date,
      r.corrects,
      s(r.settled_minor),
      r.settlements,
      r.open_minor === null ? "" : s(r.open_minor),
    ]),
    EXPORT_DOCUMENT_TEXT_COLUMNS,
  );
}

/** The postings of the servicer's books in the period, one row each, in the books' order. */
export function exportEntriesCsv(rows: readonly ExportEntryRow[]): string {
  return csvFile(
    EXPORT_ENTRY_HEADER,
    rows.map((r) => [
      r.effective_date,
      r.entry_id,
      r.entry_type,
      r.source_type,
      r.source_ref,
      r.client_name,
      r.account_number,
      BOOK_LABEL[r.book] ?? r.book,
      csvAmount(r.debit_minor),
      s(r.debit_minor),
      csvAmount(r.credit_minor),
      s(r.credit_minor),
      r.currency,
      r.posted_at,
    ]),
    EXPORT_ENTRY_TEXT_COLUMNS,
  );
}

/**
 * The CSV of one export over a period, every page read (K1): `{ body }`, or the error of the page that failed (the
 * route answers 403 for `42501`, else 400) — never a file cut short.
 */
export async function accountingExportCsv(
  rpc: ExportRpc,
  kind: ExportKind,
  period: { from: string; to: string },
): Promise<{ body: string; error: null } | { body: null; error: ExportError }> {
  const fn = kind === "factures" ? "accounting_export_documents" : "accounting_export_entries";
  const read = await fetchAllPages(
    (after, limit) =>
      rpc(fn, { p_from: period.from, p_to: period.to, p_after: after, p_limit: limit }) as PromiseLike<
        Page<{ page_key: string }>
      >,
  );
  if (read.error) return { body: null, error: read.error };
  return {
    body:
      kind === "factures"
        ? exportDocumentsCsv(read.rows as unknown as ExportDocumentRow[])
        : exportEntriesCsv(read.rows as unknown as ExportEntryRow[]),
    error: null,
  };
}
