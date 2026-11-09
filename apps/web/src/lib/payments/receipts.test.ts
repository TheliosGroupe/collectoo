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

  it("waits only while a receipts job naming the payment is queued", () => {
    // review #18: v1 read at 10:00, reversed and allocated again at 11:00 with the same lines; the job issued nothing
    const reallocated = { hasFile: true, receipts: [version(1, "original")], lastChangeAt: "2026-11-09T11:00:00Z" };
    const base = { ...reallocated, waitingForAllocation: false };
    // the job ran and found the payload unchanged: no wait, although the latest entry is later than v1
    expect(receiptPending({ ...base, jobQueued: false })).toBe(false);
    // a reversal, an unassignment…: the job is queued, a version may come
    expect(receiptPending({ ...base, jobQueued: true })).toBe(true);
    // the allocation comes first, then its receipt
    expect(receiptPending({ waitingForAllocation: true, jobQueued: true })).toBe(false);
    // not told (not money staff, or the call failed): no wait
    expect(receiptPending({ ...base, jobQueued: null })).toBe(false);
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
    const row = (kind: string, reason: string | null, effective_date: string | null = null) => ({ kind, reason, effective_date });
    expect(feedReason(row("payment_held", "hold_blocks_allocation"))).toContain("conservé");
    expect(feedReason(row("payment_allocated", null))).toBeNull();
    expect(feedReason(row("payment_allocation_reversed", "mauvais dossier, voir avec Paul"))).toBeNull();
  });

  it("words a bank return by what each row records (review M2b-6)", () => {
    // an allocation the return reversed: its invoices regain their balance, at the reversal's date
    const reversed = feedReason({ kind: "payment_allocation_reversed", reason: "bank_return", effective_date: "2026-11-05" });
    expect(reversed).toContain("son imputation est annulée au 05/11/2026");
    expect(reversed).toContain("les factures retrouvent leur solde");
    // a forward the return reversed: imputed nothing, so no invoice is mentioned
    const forward = feedReason({ kind: "payment_forward_reversed", reason: "bank_return", effective_date: "2026-11-05" });
    expect(forward).toContain("son reversement est annulé au 05/11/2026");
    expect(forward).not.toContain("imputation");
    expect(forward).not.toContain("factures");
    // the return itself (a held or never-allocated payment gets only this row): nothing about imputations or invoices
    const returned = feedReason({ kind: "payment_returned", reason: "bank_return", effective_date: "2026-11-05" });
    expect(returned).toBe("La banque du payeur a repris ce montant (retour ou contestation).");
    // no date known: the words fall back to the return's date
    expect(feedReason({ kind: "payment_allocation_reversed", reason: "bank_return", effective_date: null })).toContain(
      "annulée à la date du retour",
    );
    // the reasons that are not a return keep their own words whatever the kind
    expect(feedReason({ kind: "payment_allocation_reversed", reason: "ops_correction", effective_date: "2026-11-05" })).toBe(
      "Imputation corrigée par nos services.",
    );
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
