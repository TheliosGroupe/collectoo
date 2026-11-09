import { describe, expect, it } from "vitest";
import {
  FEED_KIND,
  FEED_REASON,
  feedKind,
  feedReason,
  feedReceiptLabel,
  receiptFileName,
  receiptPending,
  receiptVersions,
  shortHash,
  type ReceiptVersion,
} from "./receipts";

function version(n: number, kind: string, knownAt = "2026-11-09T10:00:00Z"): ReceiptVersion {
  return {
    id: `r${n}`,
    number: "Q-2026-000001",
    version: n,
    kind,
    known_at: knownAt,
    issued_at: knownAt,
    pdf_sha256: "a".repeat(64),
    account_id: "f1",
  };
}

describe("receipt versions (M2-10)", () => {
  it("lists the latest first, in force; older ones replaced, a void one cancels", () => {
    const rows = receiptVersions([version(1, "original"), version(3, "void"), version(2, "update")]);
    expect(rows.map((r) => [r.version, r.current, r.label])).toEqual([
      [3, true, "Version 3 – annule la version 2"],
      [2, false, "Version 2 – remplace la version 1"],
      [1, false, "Version 1"],
    ]);
  });

  it("names the file as stored and shortens the hash for a phone", () => {
    expect(receiptFileName({ number: "Q-2026-000042", version: 2 })).toBe("Q-2026-000042-v2.pdf");
    const sha = "3919feee6e5885d40fe7ab38abda49ac96202e24c9a6f01fcf881fd8e11590a9";
    expect(shortHash(sha)).toBe("3919feee…e11590a9");
    expect(shortHash("abc")).toBe("abc");
  });

  it("waits for a version the worker has not issued yet", () => {
    const base = { hasFile: true, waitingForAllocation: false, lastChangeAt: "2026-11-09T09:00:00Z" };
    expect(receiptPending({ ...base, receipts: [] })).toBe(true);
    expect(receiptPending({ ...base, receipts: [version(1, "original")] })).toBe(false);
    // a reversal posted after the version was read: a new one is coming
    expect(receiptPending({ ...base, lastChangeAt: "2026-11-09T11:00:00Z", receipts: [version(1, "original")] })).toBe(true);
    // the allocation comes first, then its receipt
    expect(receiptPending({ ...base, waitingForAllocation: true, receipts: [] })).toBe(false);
    // off its file: a void version is coming, unless it is there
    expect(receiptPending({ ...base, hasFile: false, receipts: [version(1, "original")] })).toBe(true);
    expect(receiptPending({ ...base, hasFile: false, receipts: [version(1, "original"), version(2, "void")] })).toBe(false);
    expect(receiptPending({ ...base, hasFile: false, receipts: [] })).toBe(false);
  });
});

describe("client payment feed (M2-11)", () => {
  it("says what happened in French, for every kind the client is told of", () => {
    for (const kind of ["payment_allocated", "payment_allocation_reversed", "payment_forwarded", "payment_held"]) {
      expect(FEED_KIND[kind].label).toMatch(/^[A-ZÉ]/);
    }
    expect(feedKind("payment_held").label).toBe("Paiement mis en attente");
    expect(feedKind("other")).toEqual({ label: "other", tone: "neutral", amount: "" });
  });

  it("explains a reason code, never ops' own words", () => {
    for (const code of ["hold_blocks_allocation", "ops_correction", "file_recalled", "before_servicing_start", "client_ratification"]) {
      expect(FEED_REASON[code]).toBeTruthy();
    }
    expect(feedReason("hold_blocks_allocation")).toContain("conservé");
    expect(feedReason(null)).toBeNull();
    expect(feedReason("mauvais dossier, voir avec Paul")).toBeNull();
  });

  it("links the receipt the client last had, saying when it is void", () => {
    expect(feedReceiptLabel({ receipt_number: "Q-2026-000001", receipt_version: 2, receipt_kind: "update" })).toBe(
      "Quittance Q-2026-000001 · version 2",
    );
    expect(feedReceiptLabel({ receipt_number: "Q-2026-000001", receipt_version: 3, receipt_kind: "void" })).toBe(
      "Quittance Q-2026-000001 · version 3 (annulée)",
    );
    expect(feedReceiptLabel({ receipt_number: null, receipt_version: null, receipt_kind: null })).toBeNull();
  });
});
