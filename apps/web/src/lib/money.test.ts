import { describe, expect, it } from "vitest";
import { formatMoneyFr } from "./money";

describe("formatMoneyFr", () => {
  it("formats integer minor units with French separators", () => {
    expect(formatMoneyFr({ minor: BigInt(123456), currency: "EUR" })).toBe("1 234,56 €");
  });
  it("keeps cents and sign", () => {
    expect(formatMoneyFr({ minor: -BigInt(5), currency: "EUR" })).toBe("-0,05 €");
  });
});
