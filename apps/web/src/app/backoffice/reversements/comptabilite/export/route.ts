import { staffSession } from "@/lib/auth/staff";
import { type ExportRpc, accountingExportCsv } from "@/lib/remittance/accounting-export";
import { exportPeriod } from "@/lib/remittance/documents";

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
}

/**
 * M2c-5 (design §14.2): the accountant's export of a period, as CSV (UTF-8 with a BOM, `;`, CRLF, French headers, amounts
 * both « 1 234,56 » and in cents, deterministic order) — the invoices and credit notes with their settlements, or the
 * postings of the servicer's books (7060, 44571, 44574, 6270, 6780, 4111, 4112, 5122). Not a FEC: the servicer's general
 * ledger is out of scope. Money staff at aal2 (the database decides).
 *
 * Review M2c-5: every page of the period is read (perf#0 = tests-ui#0, K1: PostgREST cuts any answer at 1,000 rows) and
 * a failing page refuses the whole file; free-text cells are written behind an apostrophe when a spreadsheet would
 * run them (security#0 = tests-ui#6, K3). `accountingExportCsv` is unit-tested with a fake RPC.
 */
export async function GET(request: Request) {
  const url = new URL(request.url);
  const period = exportPeriod(url.searchParams.get("du"), url.searchParams.get("au"));
  const kind = url.searchParams.get("type");
  if (!period || (kind !== "factures" && kind !== "ecritures")) {
    return text(400, "Période invalide : deux dates, un an au plus.");
  }
  const { supabase } = await staffSession();
  // `p_after` omitted on the first page: the SQL default (null) starts the period
  const rpc: ExportRpc = (fn, args) => supabase.rpc(fn, { ...args, p_after: args.p_after ?? undefined });
  const out = await accountingExportCsv(rpc, kind, period);
  if (out.error) {
    if (out.error.code !== "42501") console.error("accounting export failed", kind, out.error.code, out.error.message);
    return text(out.error.code === "42501" ? 403 : 400, "Export refusé.");
  }
  return new Response(out.body, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${kind}-${period.from}-${period.to}.csv"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
