import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { entryLabel, paymentActions } from "./allocation";
import {
  CHECK_LABEL,
  DEBIT_REVIEW,
  checkLabel,
  debitErrorCode,
  lineKindLabel,
  minorToInput,
  normaliseIban,
  refundReasons,
  refundable,
  returnEffect,
} from "./debits";

describe("refunds (founder #8, #9, #11, #12)", () => {
  it("offers a refund of what is left, never for a payment waiting for its allocation", () => {
    expect(refundable({ status: "partially_allocated", review_reason: "overpayment" }, "8000")).toBe(true);
    expect(refundable({ status: "unmatched", review_reason: "no_match" }, "7500")).toBe(true);
    expect(refundable({ status: "matched", review_reason: "currency_mismatch" }, "100")).toBe(true);
    expect(refundable({ status: "matched", review_reason: null }, "100")).toBe(false); // ready: the job allocates it
    expect(refundable({ status: "partially_allocated", review_reason: "overpayment" }, "0")).toBe(false);
    expect(refundable({ status: "refund_pending", review_reason: null }, "100")).toBe(false); // one at a time
    expect(refundable({ status: "returned", review_reason: null }, "0")).toBe(false);
  });

  it("proposes only the reason codes that fit the payment (the SQL checks them again), « other » last", () => {
    expect(refundReasons("partially_allocated", "overpayment")).toEqual(["overpayment", "other"]);
    expect(refundReasons("matched", "currency_mismatch")).toEqual(["currency_mismatch", "other"]);
    expect(refundReasons("unmatched", "no_mandate")).toEqual(["no_mandate", "other"]);
    expect(refundReasons("unmatched", "no_match")).toEqual(["unidentified", "other"]);
    expect(refundReasons("matched", "hold_blocks_allocation")).toEqual(["held_file", "other"]);
    expect(refundReasons("matched", "partial_return")).toEqual(["partial_return", "other"]);
  });

  it("shows amounts and IBANs as the forms take them (no JS number)", () => {
    expect(minorToInput("800000")).toBe("8000,00");
    expect(minorToInput("5")).toBe("0,05");
    expect(minorToInput("123456789012345678")).toBe("1234567890123456,78");
    expect(minorToInput("abc")).toBe("");
    expect(normaliseIban(" fr76 3000 6000 0112 3456 7890 189 ")).toBe("FR7630006000011234567890189");
    expect(normaliseIban("  ")).toBeNull();
  });
});

describe("returns (founder #13; design §2 #3)", () => {
  it("says what a return does before ops confirm it", () => {
    const full = returnEffect({ amount: "200,00 €", left: "0,00 €", full: true, dateFr: "03/11/2026" });
    expect(full).toContain("annulées au 03/11/2026 (date du retour)");
    expect(full).toContain("client en sera informé");
    expect(full).toContain("quittance annulée");
    const partial = returnEffect({ amount: "40,00 €", left: "60,00 €", full: false, dateFr: "02/11/2026" });
    expect(partial).toContain("Il restera 60,00 € du paiement");
    expect(partial).not.toContain("quittance annulée");
  });

  it("names lines and the job's reasons in French", () => {
    expect(lineKindLabel("return", "debit")).toBe("Retour d'un paiement reçu");
    expect(lineKindLabel("return", "credit")).toBe("Crédit annulant un débit");
    expect(lineKindLabel("refund_out", "debit")).toContain("RFD");
    expect(Object.keys(DEBIT_REVIEW).sort()).toEqual(
      ["already_returned", "ambiguous", "amount_differs", "changed", "no_candidate", "partial_return", "refund_not_pending"].sort(),
    );
  });

  it("labels the entries a return or a bounce leaves on a payment", () => {
    expect(entryLabel({ entry_type: "reversal", reverses_type: "allocation" })).toBe("Imputation annulée");
    expect(entryLabel({ entry_type: "reversal", reverses_type: "forward" })).toBe("Reversement annulé");
    expect(entryLabel({ entry_type: "reversal", reverses_type: "cash_out" })).toBe("Remboursement revenu impayé");
    expect(entryLabel({ entry_type: "cash_out", reverses_type: null })).toContain("remboursement ou retour");
  });

  it("never offers « Désaffecter » once money went back out (partial return)", () => {
    const base = {
      payment: { status: "matched", review_reason: "partial_return", account_id: "a" },
      position: { allocated_minor: "0", unallocated_minor: "6000", returned_minor: "4000", forwarded_minor: "0" },
      file: null,
      entries: [],
      other_files: [],
    } as unknown as Parameters<typeof paymentActions>[0];
    const a = paymentActions(base);
    expect(a.unassign).toBe(false);
    expect(a.allocate).toBe(true); // « Imputer » from partial_return (from the return date)
  });

  it("never offers « Désimputer » while a refund is pending (cancel it first)", () => {
    const entry = { entry_id: "e", entry_type: "allocation", account_id: "a", reversed_by: null, lines: [] };
    const d = {
      payment: { status: "refund_pending", review_reason: null, account_id: "a" },
      position: { allocated_minor: "1000", unallocated_minor: "200", returned_minor: "0", forwarded_minor: "0" },
      file: null,
      entries: [entry],
      other_files: [],
    } as unknown as Parameters<typeof paymentActions>[0];
    expect(paymentActions(d).reverse).toBe(false);
    expect(paymentActions({ ...d, payment: { ...d.payment, status: "partially_allocated" } }).reverse).toBe(true);
  });
});

describe("nightly checks", () => {
  it("words every check code the SQL writes", () => {
    for (const code of [
      "client_money_identity",
      "bank_cash_identity",
      "cash_in_statement",
      "payment_position",
      "payment_negative_allocation",
      "receivable_negative",
      "item_negative",
      "owner_claim_mirror",
      "receipt_missing",
      "receipt_numbers",
      "receipt_not_void",
      "receipt_stale",
      "notification_missing",
      "statement_gap",
      "bank_balance_gap",
      "unmatched_ageing",
      "unallocated_ageing",
      "refund_pending_ageing",
      "debit_unclassified",
      "duplicate_unresolved",
      "direct_payment_waiting",
    ])
      expect(CHECK_LABEL[code], code).toBeDefined();
    expect(checkLabel("unknown_code")).toEqual({ label: "unknown_code", help: "" });
  });
});

describe("errors of the M2b-6 commands", () => {
  it("maps database messages to codes with French text", () => {
    const cases: [string, string][] = [
      ["refund: the reason does not match the payment's state", "refund_reason_mismatch"],
      ["refund: more than what is left of the payment", "refund_too_much"],
      ["refund: the payee's IBAN is required (the bank gave none)", "refund_iban_required"],
      ["refund: invalid IBAN", "iban_invalid"],
      ["the payment changed: reload the page", "payment_changed"],
      ["debit link refused: payment_changed", "payment_changed"],
      ["debit link refused: already_linked", "already_linked"],
      ["debit link refused: amount_exceeds", "link_amount"],
      ["debit link refused: not_a_return", "link_refused"],
      ["duplicate: already decided: reload the page", "already_decided"],
      ["direct payment: the client's statement is required, filed on this file", "direct_evidence"],
      ["payment x: a refund is pending: cancel it first (or none is: it cannot wait for one)", "refund_pending"],
      ["not allowed", "not_allowed"],
      ["canceling statement due to lock timeout", "allocation_busy"],
    ];
    for (const [message, code] of cases) {
      expect(debitErrorCode(message), message).toBe(code);
      expect(errorText(debitErrorCode(message))).not.toBe(errorText("unknown"));
    }
    expect(debitErrorCode("something else")).toBe("unknown");
  });
});
