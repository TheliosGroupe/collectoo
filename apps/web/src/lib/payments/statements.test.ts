import { describe, expect, it } from "vitest";
import {
  acceptFor,
  bankCheckText,
  importErrorText,
  lineState,
  maskedIban,
  money,
  signedMoney,
  statementStatus,
  uploadErrorText,
  warningText,
} from "./statements";

/** formatMoneyFr uses no-break spaces; compare with plain ones. */
const plain = (s: string) => s.replace(/[\u00a0\u202f]/g, " ");

describe("statement amounts", () => {
  it("formats integer minor units given as text, never through a JS number", () => {
    expect(plain(money("123450", "EUR"))).toBe("1 234,50 €");
    expect(plain(money("-265", "EUR"))).toBe("-2,65 €");
    // beyond Number.MAX_SAFE_INTEGER: still exact
    expect(plain(money("900719925474099312", "EUR"))).toBe("9 007 199 254 740 993,12 €");
    expect(plain(money(null, "EUR"))).toBe("–");
    expect(plain(money("12.5", "EUR"))).toBe("–");
  });

  it("signs a line by its direction", () => {
    expect(plain(signedMoney("credit", "1000", "EUR"))).toBe("+ 10,00 €");
    expect(plain(signedMoney("debit", "150", "EUR"))).toBe("− 1,50 €");
  });
});

describe("statement and line states", () => {
  it("words the statuses", () => {
    expect(statementStatus("imported")).toEqual({ label: "Importé", tone: "ok" });
    expect(statementStatus("uploaded").tone).toBe("busy");
    expect(statementStatus("rejected").tone).toBe("error");
  });

  it("tells booked payments from lines that wait", () => {
    expect(lineState({ kind: "debtor_credit", direction: "credit", has_payment: true })).toEqual({
      kind: "Encaissement",
      state: "Comptabilisé · à affecter",
      tone: "ok",
    });
    expect(lineState({ kind: "batch_unsplit", direction: "credit", has_payment: true }).state).toBe(
      "Comptabilisé · à affecter",
    );
    expect(lineState({ kind: "suspected_duplicate", direction: "credit", has_payment: false }).state).toBe(
      "Retenu : doublon possible",
    );
    expect(lineState({ kind: "other_debit", direction: "debit", has_payment: false })).toEqual({
      kind: "Débit (frais, autre)",
      state: "Non comptabilisé · à classer",
      tone: "action",
    });
  });
});

describe("bank balance check (I9)", () => {
  const base = { as_of: "2026-10-02", closing_minor: "16850", cash_minor: "19500" };
  it("reconciled, with or without lines to classify", () => {
    expect(
      plain(bankCheckText({ ...base, unposted_minor: "0", unposted_lines: 0, difference_minor: "0" }, "EUR").text),
    ).toBe("Solde de clôture rapproché ✓");
    expect(
      plain(bankCheckText({ ...base, unposted_minor: "-2650", unposted_lines: 2, difference_minor: "0" }, "EUR").text),
    ).toBe("Solde de clôture rapproché ✓ — écart de -26,50 € expliqué par 2 lignes du compte à classer");
  });
  it("an unexplained gap is an error; a CSV has no balance", () => {
    expect(
      bankCheckText({ ...base, unposted_minor: "0", unposted_lines: 0, difference_minor: "3850" }, "EUR").tone,
    ).toBe("error");
    expect(bankCheckText(null, "EUR").text).toContain("CSV");
  });
});

describe("messages", () => {
  it("words the warnings", () => {
    expect(warningText({ code: "overlap", statements: 2 }, "EUR")).toContain("2 relevés déjà importés");
    expect(plain(warningText({ code: "opening_differs", expected_minor: "21150", actual_minor: "25000" }, "EUR"))).toBe(
      "Relevé manquant ? Le solde d'ouverture (250,00 €) ne suit pas le solde de clôture précédent (211,50 €).",
    );
  });
  it("words refusals in French, with the line when known, never the raw detail", () => {
    expect(importErrorText("unbalanced", "statement STMT: opening 0 + lines 1 != closing 0")).toContain(
      "ne s'équilibre pas",
    );
    expect(importErrorText("csv_row", "line 12: '12,345' has more decimals")).toMatch(/\(ligne 12\)$/);
    expect(importErrorText("something_new", "boom")).toContain("Contactez le support");
    expect(uploadErrorText("the file format does not match the bank account feed")).toContain("autre format");
    expect(uploadErrorText("not allowed")).toBe("Action non autorisée pour votre rôle.");
  });
  it("offers the right files and masks third-party IBANs", () => {
    expect(acceptFor("camt053")).toBe(".xml");
    expect(acceptFor("csv")).toBe(".csv,.txt");
    expect(maskedIban("FR7630004000031234567890143")).toBe("IBAN …0143");
    expect(maskedIban(null)).toBe("");
  });
});
