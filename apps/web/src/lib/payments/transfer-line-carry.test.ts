// M2c-6b-2d, what 6b-2c left (ADR-0014 « M2c-6b-2c review fixes », « Left open after round 3 »; « M2c-6b-2c carry-overs
// (in 6b-2d) »): « À classer »'s text on a debit of an ended payout's amount says « Retour du paiement … » only when the
// row offers that button (ended-twin-return-sentence-without-payment) — the payments the page offers are the ones
// linkOffers returns from the job's named payments and those public.debit_link_options lists (linkPayments); and the
// command's new refusal (suppression-e0-names-our-other-lot) has its French label.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  debitReviewText,
  linkOffers,
  linkPayments,
  PAYOUT_AMOUNT_MATCH_ENDED,
  PAYOUT_AMOUNT_MATCH_RETURN,
} from "./debits";
import { TRANSFER_LINE_REFUSAL, transferLineErrorText } from "./transfer-lines";

const T = "00000000-0000-0000-0000-0000000000t1";
const ended = (status: string, run_status = "booked") => ({ transfer_id: T, kind: "payout", status, run_status });
const row = (o: Record<string, unknown> = {}) => ({
  direction: "debit",
  kind: "other_debit",
  amount_minor: "419840",
  end_to_end_id: null,
  original_end_to_end_id: null,
  payment_info_id: null,
  unsplit_ours: null,
  names_our_lot: false,
  counterparty_iban_end: null as string | null,
  review_reason: "payout_amount_match" as string | null,
  bookable_as: "n" as string | null,
  candidates: [ended("returned")] as Record<string, unknown>[],
  ...o,
});
const listed = (payment_id: string, left_minor: string) => ({
  payment_id,
  amount_minor: left_minor,
  booking_date: "2026-11-10",
  payer_name: "PAYEUR",
  left_minor,
  file_reference: "D-01",
});

describe("the ended payout's text names « Retour du paiement … » only when the row offers it (6b-2d)", () => {
  it("no payment listed: the return sentence is not said, though « Lier » would take a return", () => {
    const text = debitReviewText(row(), { return_guard: null, payments: [] });
    expect(text).toBe(PAYOUT_AMOUNT_MATCH_ENDED);
    expect(text).not.toContain("Retour du paiement");
    // the page offers no such button either
    expect(linkOffers(row(), linkPayments(row().candidates, []), [], null).returns).toEqual([]);
  });
  it("a payment listed of which less than the line is left: no button, no sentence", () => {
    const short = [listed("p1", "419839")];
    expect(linkOffers(row(), linkPayments(row().candidates, short), [], null).returns).toEqual([]);
    expect(debitReviewText(row(), { return_guard: null, payments: short })).toBe(PAYOUT_AMOUNT_MATCH_ENDED);
  });
  it("a payment listed that the line can take back: the button and the sentence", () => {
    const ok = [listed("p2", "512000")];
    expect(linkOffers(row(), linkPayments(row().candidates, ok), [], null).returns.map((p) => p.payment_id)).toEqual([
      "p2",
    ]);
    expect(debitReviewText(row(), { return_guard: null, payments: ok })).toBe(
      `${PAYOUT_AMOUNT_MATCH_ENDED} ${PAYOUT_AMOUNT_MATCH_RETURN}`,
    );
  });
  it("the options not read, or the database refusing the return: never the sentence, whatever is listed", () => {
    const ok = [listed("p2", "512000")];
    expect(debitReviewText(row(), undefined)).toBe(PAYOUT_AMOUNT_MATCH_ENDED);
    expect(debitReviewText(row(), { return_guard: "client_payout_line", payments: ok })).toBe(PAYOUT_AMOUNT_MATCH_ENDED);
  });
});

describe("linkPayments: the payments « À classer » may offer, as LineActions builds them", () => {
  it("the job's named payments first (named), then those listed that it did not name; never a refund", () => {
    const candidates = [
      { payment_id: "p1", left_minor: "1000", amount_minor: "1000", booking_date: "2026-11-01", payer_name: "A" },
      { payment_id: "p9", refund_request_id: "q1", left_minor: "1000" },
      { transfer_id: T, status: "returned" },
    ];
    const out = linkPayments(candidates, [listed("p1", "1000"), listed("p2", "2000")]);
    expect(out.map((p) => [p.payment_id, p.named === true])).toEqual([
      ["p1", true],
      ["p2", false],
    ]);
  });
});

describe("names_other_lot (6b-2d, suppression-e0-names-our-other-lot)", () => {
  it("the migration refuses with it, and the page has its French label", () => {
    const migration = readFileSync(
      join(__dirname, "../../../../../supabase/migrations/20261117113000_transfer_line_pages_fixes.sql"),
      "utf8",
    );
    expect(migration).toContain("return 'names_other_lot';");
    expect(TRANSFER_LINE_REFUSAL).toHaveProperty("names_other_lot");
    const text = transferLineErrorText("names_other_lot");
    expect(text).toContain("autre lot");
    expect(text).toContain("Demandez le détail à la banque");
    expect(text).toMatch(/\.$/);
  });
});
