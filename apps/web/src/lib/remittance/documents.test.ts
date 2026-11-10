import { describe, expect, it } from "vitest";
import {
  EXPORT_DOCUMENT_HEADER,
  csvAmount,
  csvFile,
  exportPeriod,
  frenchDay,
  invoiceDelivery,
  invoiceKind,
  runStatusText,
  settlementText,
} from "./documents";

describe("M2c-5 documents", () => {
  it("serves an invoice's PDF only once the buyer accepted electronic invoices (CGI 289 VI)", () => {
    expect(invoiceDelivery({ payload: { buyer: { invoice_acceptance_ref: "art. 11" } } }, { document_id: "d1" })).toEqual({
      mode: "pdf",
      documentId: "d1",
    });
    expect(invoiceDelivery({ payload: { buyer: { invoice_acceptance_ref: "art. 11" } } }, null)).toEqual({ mode: "pending" });
    expect(invoiceDelivery({ payload: { buyer: { invoice_acceptance_ref: null } } }, { document_id: "d1" })).toEqual({
      mode: "post",
    });
    expect(invoiceDelivery({ payload: { buyer: { invoice_acceptance_ref: "  " } } }, null)).toEqual({ mode: "post" });
    expect(invoiceDelivery({ payload: null }, null)).toEqual({ mode: "post" });
  });

  it("never says paid before the bank's debit", () => {
    const words = [
      runStatusText("approved", "164000"),
      runStatusText("sent", "164000"),
      runStatusText("booked", "0"),
      runStatusText("cancelled", "164000"),
      settlementText({ kind: "invoice", settlement: "netted", due_date: null }),
      settlementText({ kind: "invoice", settlement: "due", due_date: "2026-12-02" }),
      settlementText({ kind: "credit_note", settlement: "netted", due_date: null }),
    ];
    expect(words).toEqual([
      "Virement ordonné",
      "Virement ordonné",
      "Réglé par compensation, sans virement",
      "Annulé avant son exécution",
      "à régler par compensation sur un reversement",
      "à régler au plus tard le 02/12/2026",
      "déduit des factures qu'il rectifie",
    ]);
    expect(words.filter((w) => /payé/i.test(w))).toEqual([]);
    expect(invoiceKind("credit_note")).toBe("Avoir");
    expect(invoiceKind("invoice")).toBe("Facture");
    expect(frenchDay("2026-11-02")).toBe("02/11/2026");
  });

  it("formats CSV amounts in French, from text minor units (no float)", () => {
    expect(csvAmount("123456789")).toBe("1 234 567,89");
    expect(csvAmount("-1")).toBe("-0,01");
    expect(csvAmount("0")).toBe("0,00");
    expect(csvAmount("9007199254740993")).toBe("90 071 992 547 409,93");
  });

  it("writes a CSV with a BOM, ';' and CRLF, quoting what needs it", () => {
    const out = csvFile(["a", "b"], [["x;y", 'he said "hi"'], [null, "z"]]);
    expect(out).toBe('﻿a;b\r\n"x;y";"he said ""hi"""\r\n;z\r\n');
    expect(EXPORT_DOCUMENT_HEADER[0]).toBe("numero");
  });

  it("accepts a period of at most a year", () => {
    expect(exportPeriod("2026-01-01", "2026-12-31")).toEqual({ from: "2026-01-01", to: "2026-12-31" });
    expect(exportPeriod("2026-12-31", "2026-01-01")).toBeNull();
    expect(exportPeriod("2025-01-01", "2026-12-31")).toBeNull();
    expect(exportPeriod("2026-1-1", "2026-12-31")).toBeNull();
    expect(exportPeriod(null, "2026-12-31")).toBeNull();
  });
});
