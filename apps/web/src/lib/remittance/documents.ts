/**
 * M2c-5 (design §10, §14, §17): words of the client space « Reversements » and « Factures », and of the accountant's
 * export. Amounts stay text in minor units (never JS numbers); the database computes them.
 */

export type StatementRow = {
  run_id: string;
  number: string;
  issue_date: string;
  currency: string;
  line_count: number;
  file_count: number;
  pdf_document_id: string;
  pdf_sha256: string;
  csv_document_id: string;
  csv_sha256: string;
};

export type InvoiceRow = {
  id: string;
  kind: string;
  number: string;
  issue_date: string;
  ttc_minor: number | string;
  settlement: string;
  due_date: string | null;
  run_id: string | null;
  payload: { buyer?: { invoice_acceptance_ref?: string | null } } | null;
};

/** How an invoice reaches the client (CGI 289 VI): in the client space once the buyer accepted electronic invoices
 * (recorded at issue in its payload), otherwise by post — the PDF is not served then. */
export function invoiceDelivery(
  inv: Pick<InvoiceRow, "payload">,
  pdf: { document_id: string } | null,
): { mode: "pdf"; documentId: string } | { mode: "post" } | { mode: "pending" } {
  const accepted = Boolean(inv.payload?.buyer?.invoice_acceptance_ref?.trim());
  if (!accepted) return { mode: "post" };
  return pdf ? { mode: "pdf", documentId: pdf.document_id } : { mode: "pending" };
}

/** « Facture » / « Avoir ». */
export function invoiceKind(kind: string): string {
  return kind === "credit_note" ? "Avoir" : "Facture";
}

/** How a document is settled, in the client's words — never « payée » or « réglée » before the bank's debit (M2c-6). */
export function settlementText(inv: Pick<InvoiceRow, "kind" | "settlement" | "due_date">): string {
  if (inv.kind === "credit_note") return "déduit des factures qu'il rectifie";
  if (inv.settlement === "due") return inv.due_date ? `à régler au plus tard le ${frenchDay(inv.due_date)}` : "à régler";
  return "à régler par compensation sur un reversement";
}

/** The status of a run in the client space: « ordonné » until the bank's debit is booked. */
export function runStatusText(status: string, net: string | null): string {
  if (status === "booked") return net === "0" ? "Réglé par compensation, sans virement" : "Virement débité de notre compte";
  if (status === "cancelled") return "Annulé avant son exécution";
  return "Virement ordonné";
}

export function frenchDay(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-");
  return `${d}/${m}/${y}`;
}

/** A period for the accountant's export: two ISO dates, at most 366 days apart (the database checks it too). */
export function exportPeriod(from: string | null, to: string | null): { from: string; to: string } | null {
  const iso = /^\d{4}-\d{2}-\d{2}$/;
  if (!from || !to || !iso.test(from) || !iso.test(to)) return null;
  const days = (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000;
  if (!Number.isFinite(days) || days < 0 || days > 366) return null;
  return { from, to };
}

const NBSP = " ";

/** « 1 234,56 »: integer minor units as the CSV writes them (no-break space between thousands, decimal comma). */
export function csvAmount(minor: string | number | bigint, exponent = 2): string {
  const value = BigInt(minor);
  const negative = value < BigInt(0);
  const abs = negative ? -value : value;
  const base = BigInt(10) ** BigInt(exponent);
  const units = (abs / base).toString().replace(/\B(?=(\d{3})+(?!\d))/g, NBSP);
  const fraction = exponent > 0 ? `,${(abs % base).toString().padStart(exponent, "0")}` : "";
  return `${negative ? "-" : ""}${units}${fraction}`;
}

/** A CSV in French conventions: UTF-8 with a BOM, `;`, CRLF, fields quoted when needed (RFC 4180). */
export function csvFile(header: readonly string[], rows: readonly (readonly (string | null | undefined)[])[]): string {
  const cell = (v: string | null | undefined) => {
    const s = v ?? "";
    return /[;"\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return `﻿${[header, ...rows].map((r) => r.map(cell).join(";")).join("\r\n")}\r\n`;
}

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
