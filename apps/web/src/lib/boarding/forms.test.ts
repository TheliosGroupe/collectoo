import { describe, expect, it } from "vitest";
import { commandErrorCode, errorText, formatPct, mappingField, mappingOverrides, parseEurosToMinor } from "./forms";
import { readProfile } from "./profile";
import { isProcessing, statusLabel, statusTone } from "./status";
import { TARGETS, targetLabel } from "./targets";

describe("parseEurosToMinor", () => {
  it.each([
    ["12 345,67", BigInt(1234567)],
    ["12345.6", BigInt(1234560)],
    ["1 000 €", BigInt(100000)],
    ["0,05", BigInt(5)],
    ["-10", BigInt(-1000)],
    ["92233720368547758,07", BigInt("9223372036854775807")],
  ])("%s -> %s", (text, minor) => {
    expect(parseEurosToMinor(text)).toBe(minor);
  });

  it.each(["", "abc", "1,234,56", "1.234", "92233720368547758,08"])("rejects %j", (text) => {
    expect(parseEurosToMinor(text)).toBeNull();
  });
});

describe("mappingOverrides", () => {
  const proposals = [
    { file_id: "f1", source_column: "Montant TTC", target: "claim_item.amount" },
    { file_id: "f1", source_column: "Commentaire", target: null },
    { file_id: "f2", source_column: "Réf", target: "account.external_ref" },
  ];

  it("keeps only the changed selects", () => {
    const form: Record<string, string> = {
      [mappingField("f1", "Montant TTC")]: "claim_item.amount",
      [mappingField("f1", "Commentaire")]: "party.first_name",
      [mappingField("f2", "Réf")]: "",
    };
    expect(mappingOverrides(proposals, (k) => form[k] ?? null)).toEqual({
      f1: { Commentaire: "party.first_name" },
      f2: { "Réf": "" },
    });
  });

  it("ignores proposals missing from the form", () => {
    expect(mappingOverrides(proposals, () => null)).toEqual({});
  });
});

describe("labels", () => {
  it("names every state in French and knows when the worker is busy", () => {
    expect(statusLabel("mapping_proposed")).toBe("Mapping à valider");
    expect(isProcessing("transformed")).toBe(true);
    expect(isProcessing("staged")).toBe(false);
    expect(statusTone("confirmed")).toBe("ok");
  });

  it("labels Layer-2 targets in French and EU-template fields by number", () => {
    expect(targetLabel("claim_item.amount")).toBe("Pièce : montant");
    expect(targetLabel(null)).toBe("Non repris");
    const eba = TARGETS.find((t) => t.id.startsWith("eba.f3_12"));
    expect(eba && targetLabel(eba.id)).toMatch(/^Modèle UE 3\.12 /);
  });

  it("turns command errors into fixed French messages (most specific first)", () => {
    expect(commandErrorCode("no active client mandate covers this portfolio (CPCE R124-3)")).toBe("mandate_missing");
    expect(commandErrorCode("totals do not reconcile with the seller's control totals: a reason is required")).toBe(
      "totals_mismatch",
    );
    expect(commandErrorCode("a reason is required")).toBe("reason_required");
    expect(commandErrorCode("another file with this name is already in the batch")).toBe("name_taken");
    expect(commandErrorCode("control totals can only change before the mapping is approved (batch is abandoned)")).toBe(
      "already_submitted",
    );
    expect(commandErrorCode('duplicate key value violates unique constraint "x"')).toBe("unknown");
    expect(errorText("not_allowed")).toMatch(/non autorisée/);
    expect(commandErrorCode("ledger: opening balances do not reconcile with the data-quality report (x vs y)")).toBe(
      "opening_mismatch",
    );
    expect(commandErrorCode("the cut-off date is required and cannot be in the future")).toBe("cut_off_required");
    expect(commandErrorCode("ledger: batch x has ledger entries; correct them with reversals")).toBe("ledger_rejected");
  });

  it("formats percentages the French way", () => {
    expect(formatPct(0.925).replace(/\s/g, " ")).toBe("92,5 %");
  });
});

describe("readProfile", () => {
  const table = { row_count: 3, duplicate_rows: 0, columns: [{ name: "a" }] };
  it("reads CSV tables, the first non-empty Excel sheet, zips and fixed-width files", () => {
    expect(readProfile(table).kind).toBe("table");
    const sheet = readProfile({ sheets: { Vide: { ...table, row_count: 0 }, Factures: table } });
    expect(sheet).toMatchObject({ kind: "table", sheet: "Factures" });
    expect(readProfile({ sheets: { Vide: { ...table, row_count: 0 } } }).kind).toBe("empty_workbook");
    // jsonb key order (by length) differs from the workbook order kept in sheet_order.
    const ordered = readProfile({ sheets: { Annexe: table, Factures: table }, sheet_order: ["Factures", "Annexe"] });
    expect(ordered).toMatchObject({ kind: "table", sheet: "Factures" });
    expect(readProfile({ not_profiled: "zip" }).kind).toBe("documents");
    expect(readProfile({ needs_layout: true }).kind).toBe("needs_layout");
    expect(readProfile(null).kind).toBe("pending");
  });
});
