import { describe, expect, it } from "vitest";
import { commandError, mappingField, mappingOverrides, parseEurosToMinor } from "./forms";
import { isProcessing, statusLabel, statusTone } from "./status";
import { TARGETS, targetLabel } from "./targets";

describe("parseEurosToMinor", () => {
  it.each([
    ["12 345,67", BigInt(1234567)],
    ["12345.6", BigInt(1234560)],
    ["1 000 €", BigInt(100000)],
    ["0,05", BigInt(5)],
    ["-10", BigInt(-1000)],
    ["99999999999999999,99", BigInt("9999999999999999999")],
  ])("%s -> %s", (text, minor) => {
    expect(parseEurosToMinor(text)).toBe(minor);
  });

  it.each(["", "abc", "1,234,56", "1.234"])("rejects %j", (text) => {
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

  it("translates command errors", () => {
    expect(commandError("no active client mandate covers this portfolio (CPCE R124-3)")).toMatch(/R124-3/);
    expect(commandError("not allowed")).toMatch(/non autorisée/);
  });
});
