import { staffSession } from "@/lib/auth/staff";
import {
  BOOK_LABEL,
  DOC_TYPE,
  EXPORT_DOCUMENT_HEADER,
  EXPORT_ENTRY_HEADER,
  csvAmount,
  csvFile,
  exportPeriod,
} from "@/lib/remittance/documents";

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
}

const s = (v: unknown) => (v === null || v === undefined ? "" : String(v));

/**
 * M2c-5 (design §14.2): the accountant's export of a period, as CSV (UTF-8 with a BOM, `;`, CRLF, French headers, amounts
 * both « 1 234,56 » and in cents, deterministic order) — the invoices and credit notes with their settlements, or the
 * postings of the servicer's books (7060, 44571, 44574, 6270, 6780, 4111, 4112, 5122). Not a FEC: the servicer's general
 * ledger is out of scope. Money staff at aal2 (the database decides).
 */
export async function GET(request: Request) {
  const url = new URL(request.url);
  const period = exportPeriod(url.searchParams.get("du"), url.searchParams.get("au"));
  const kind = url.searchParams.get("type");
  if (!period || (kind !== "factures" && kind !== "ecritures")) {
    return text(400, "Période invalide : deux dates, un an au plus.");
  }
  const { supabase } = await staffSession();
  const name = `${kind}-${period.from}-${period.to}.csv`;
  let body: string;
  if (kind === "factures") {
    const { data, error } = await supabase.rpc("accounting_export_documents", { p_from: period.from, p_to: period.to });
    if (error) return text(error.code === "42501" ? 403 : 400, "Export refusé.");
    body = csvFile(
      EXPORT_DOCUMENT_HEADER,
      (data ?? []).map((r) => [
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
    );
  } else {
    const { data, error } = await supabase.rpc("accounting_export_entries", { p_from: period.from, p_to: period.to });
    if (error) return text(error.code === "42501" ? 403 : 400, "Export refusé.");
    body = csvFile(
      EXPORT_ENTRY_HEADER,
      (data ?? []).map((r) => [
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
    );
  }
  return new Response(body, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${name}"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
