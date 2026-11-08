import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { bankAccountErrorCode, frenchDate } from "./bank-accounts";

describe("bank-account command errors", () => {
  it("maps each database message to a French message", () => {
    const cases: [string, string][] = [
      ["not allowed", "Action non autorisée"],
      ["invalid IBAN", "IBAN invalide"],
      ["invalid BIC", "BIC invalide"],
      ["this IBAN is already registered", "déjà enregistré"],
      ["a label is required (100 characters at most)", "libellé"],
      ["the opening date cannot be in the future", "date d'ouverture"],
      ["the bank account still holds client money", "fonds de tiers"],
      ["the bank account is already closed", "déjà clôturé"],
      ["a reason is required", "motif"],
      ["idempotency key x was used for a different request", "L'action a échoué"],
    ];
    for (const [message, french] of cases) {
      expect(errorText(bankAccountErrorCode(message))).toContain(french);
    }
  });

  it("prints business dates as dd/mm/yyyy", () => {
    expect(frenchDate("2026-11-08")).toBe("08/11/2026");
    expect(frenchDate(null)).toBe("");
  });
});
