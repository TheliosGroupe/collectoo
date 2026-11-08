import { describe, expect, it } from "vitest";
import { groupsOfFour, ibanValid, mod97, normaliseCode, rfValid } from "./iban";

describe("IBAN and RF helpers (same rules as private.iban_valid / rf_valid)", () => {
  it("validates IBANs mod 97 once normalised", () => {
    expect(ibanValid(normaliseCode("fr76 3000 4000 0312 3456 7890 143"))).toBe(true);
    expect(ibanValid("FR1420041010050500013M02606")).toBe(true);
    expect(ibanValid("FR7630004000031234567890144")).toBe(false); // one digit changed
    expect(ibanValid("FR7630004000031234567890134")).toBe(false); // two digits swapped
    expect(ibanValid("FR76 3000 4000 0312 3456 7890 143")).toBe(false); // not normalised
    expect(ibanValid("FR01300040000312345678901")).toBe(false);
  });

  it("validates RF references (ISO 11649 vector)", () => {
    expect(rfValid("RF18539007547034")).toBe(true);
    expect(rfValid("RF18539007547035")).toBe(false);
    expect(rfValid(normaliseCode("rf18 5390 0754\n7034"))).toBe(true);
  });

  it("prints codes in groups of four", () => {
    expect(groupsOfFour("FR7630004000031234567890143")).toBe("FR76 3000 4000 0312 3456 7890 143");
    expect(groupsOfFour("RF18539007547034")).toBe("RF18 5390 0754 7034");
  });

  it("computes mod 97 without floats, alphanumerics only", () => {
    expect(mod97("RF")).toBe(2715 % 97);
    expect(() => mod97("rf")).toThrow();
    expect(() => mod97("1 2")).toThrow();
  });

  it("keeps non-ASCII characters (they then fail validation, as in SQL)", () => {
    expect(normaliseCode("fr76 é")).toBe("FR76é");
    expect(ibanValid(normaliseCode("FR76 3000 4000 0312 3456 7890 143"))).toBe(false);
  });
});
