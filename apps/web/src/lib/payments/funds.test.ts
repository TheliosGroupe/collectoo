import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { PURPOSE_LABEL, TOP_UP_STATUS, bankAccountErrorCode } from "./bank-accounts";
import { CHECK_LABEL, DEBIT_REVIEW, LINK_KIND, debitErrorCode, feeEffect, lineKindLabel, lossEffect, ownCreditEffect } from "./debits";

/** M2c-1 (M2-12): the own account, top-ups, bank lines booked in the funds, the new checks — in French, from codes. */
describe("bank accounts and top-ups", () => {
  it("names both purposes and every top-up status", () => {
    expect(PURPOSE_LABEL.client_funds).toBe("Fonds de tiers");
    expect(PURPOSE_LABEL.own).toBe("Compte propre du cabinet");
    for (const s of ["ordered", "in_file", "booked", "returned", "cancelled"]) expect(TOP_UP_STATUS[s]).toBeTruthy();
  });
  it("maps the commands' refusals to French", () => {
    const cases: [string, string][] = [
      ["a client_funds account is already active in this currency (one per currency)", "client_funds_exists"],
      ["transfers from or to this bank account are in flight", "transfers_in_flight"],
      ["top-up: from an active own account to an active client_funds account in the same currency", "top_up_accounts"],
      ["the top-up is no longer pending", "top_up_not_pending"],
      ["the requested execution date is in the past", "date_past"],
      ["invalid amount", "amount_invalid"],
      ["this IBAN is already registered", "iban_taken"],
    ];
    for (const [message, code] of cases) {
      expect(bankAccountErrorCode(message), message).toBe(code);
      expect(errorText(bankAccountErrorCode(message))).not.toBe(errorText("unknown"));
    }
  });
});

describe("bank lines booked in the funds", () => {
  it("words the new kinds, decisions and reviews", () => {
    expect(lineKindLabel("transfer_out", "debit")).toBe("Virement émis par le cabinet");
    expect(lineKindLabel("own_transfer_in", "credit")).toBe("Virement reçu du compte propre");
    expect(lineKindLabel("client_transfer_in", "credit")).toBe("Virement reçu d'un client");
    for (const k of ["fee", "top_up", "loss"]) expect(LINK_KIND[k]).toBeTruthy();
    for (const r of ["top_up_not_found", "top_up_differs", "client_credit", "own_transfer_out"]) expect(DEBIT_REVIEW[r]).toBeTruthy();
  });
  it("says what each booking does before it is sent, never charging a client", () => {
    expect(feeEffect("12,00 €")).toContain("à la charge du cabinet");
    expect(feeEffect("12,00 €")).toContain("Aucun client");
    expect(ownCreditEffect("200,00 €")).toContain("ce n'est le paiement d'aucun débiteur");
    const loss = lossEffect({ amount: "15,00 €", left: "10,00 €", excess: "5,00 €", dateFr: "07/11/2026", noneLeft: false });
    expect(loss).toContain("Le retour de 10,00 €");
    expect(loss).toContain("l'excédent de 5,00 € sera une perte à la charge du cabinet");
    expect(loss).toContain("jamais du client ni d'un autre client");
    expect(lossEffect({ amount: "15,00 €", left: "0,00 €", excess: "15,00 €", dateFr: "07/11/2026", noneLeft: true })).toContain(
      "rien ne reste du paiement",
    );
  });
  it("maps the bookings' refusals to French (most specific first)", () => {
    const cases: [string, string][] = [
      ["bank booking refused: already_booked", "already_booked"],
      ["debit link refused: already_booked", "already_booked"],
      ["bank booking refused: not_a_fee", "not_a_fee"],
      ["bank booking refused: not_an_own_credit", "not_an_own_credit"],
      ["bank booking refused: own_account_unknown", "own_account_unknown"],
      ["bank booking refused: amount_differs", "top_up_differs"],
      ["bank booking refused: transfer_not_pending", "top_up_differs"],
      ["debit link refused: not_a_loss", "not_a_loss"],
      ["bank booking refused: posting_failed (LG001: …)", "link_posting_failed"],
      ["bank booking refused: line_unknown", "booking_refused"],
      ["debit link refused: amount_differs", "link_amount"],
    ];
    for (const [message, code] of cases) {
      expect(debitErrorCode(message), message).toBe(code);
      expect(errorText(debitErrorCode(message))).not.toBe(errorText("unknown"));
    }
  });
});

describe("the nightly checks of the two funds", () => {
  it("has French words for every new code", () => {
    for (const code of ["own_fund_identity", "fund_mirror", "client_payable_debit", "remittance_completeness"]) {
      expect(CHECK_LABEL[code]?.label, code).toBeTruthy();
      expect(CHECK_LABEL[code]?.help, code).toBeTruthy();
    }
  });
});
