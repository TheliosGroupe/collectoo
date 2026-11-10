import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { PURPOSE_LABEL, TOP_UP_STATUS, bankAccountErrorCode } from "./bank-accounts";
import {
  CHECK_LABEL,
  DEBIT_REVIEW,
  LINK_KIND,
  RELAY_LABEL,
  clientRelayable,
  clientRelayedPaymentEffect,
  debitErrorCode,
  decisionLabel,
  explainable,
  feeEffect,
  lineKindLabel,
  lossEffect,
  offersPaymentLinks,
  ownCreditEffect,
  relayable,
  relayedPaymentEffect,
} from "./debits";

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
    expect(ownCreditEffect("200,00 €")).toContain("approvisionnement du compte dédié par le cabinet");
    expect(ownCreditEffect("200,00 €")).toContain("« Paiement d'un débiteur relayé par le cabinet »");
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

/** Review M2c-1: « À classer » on our own transfers and credits, and a debtor's payment relayed by the servicer. */
describe("our own transfers and credits to classify", () => {
  it("offers a payment's return and our refunds only on the lines M2b reads as such", () => {
    for (const kind of ["return", "refund_out", "other_debit"]) expect(offersPaymentLinks({ direction: "debit", kind }), kind).toBe(true);
    expect(offersPaymentLinks({ direction: "credit", kind: "return" })).toBe(true);
    // the database refuses these links (« debit link refused: not_a_return »): never offered
    expect(offersPaymentLinks({ direction: "debit", kind: "transfer_out" })).toBe(false);
    expect(offersPaymentLinks({ direction: "credit", kind: "own_transfer_in" })).toBe(false);
    expect(offersPaymentLinks({ direction: "credit", kind: "client_transfer_in" })).toBe(false);
    // they may still be classified with an explanation
    for (const [direction, kind] of [
      ["debit", "transfer_out"],
      ["credit", "own_transfer_in"],
      ["credit", "client_transfer_in"],
    ])
      expect(explainable({ direction, kind, namesPayment: false }), kind).toBe(true);
  });
  it("offers to relay a debtor's payment only on a credit from the own account without our TOP reference", () => {
    expect(relayable({ direction: "credit", kind: "own_transfer_in", end_to_end_id: null })).toBe(true);
    expect(relayable({ direction: "credit", kind: "own_transfer_in", end_to_end_id: "NOTPROVIDED" })).toBe(true);
    // a debtor's own reference that only looks like ours stays relayable (TOPAZ-…, not 12 upper-case hex digits)
    expect(relayable({ direction: "credit", kind: "own_transfer_in", end_to_end_id: "TOPAZ-2026-11" })).toBe(true);
    // our top-up reference: a top-up, never a debtor's payment
    expect(relayable({ direction: "credit", kind: "own_transfer_in", end_to_end_id: "TOP0123456789AB" })).toBe(false);
    expect(relayable({ direction: "credit", kind: "client_transfer_in", end_to_end_id: null })).toBe(false);
    expect(relayable({ direction: "debit", kind: "transfer_out", end_to_end_id: null })).toBe(false);
  });
  it("says what relaying a debtor's payment does before it is sent", () => {
    const effect = relayedPaymentEffect({ amount: "300,00 €", dateFr: "05/11/2026" });
    expect(effect).toContain("Le crédit de 300,00 € deviendra un paiement reçu");
    expect(effect).toContain("au 05/11/2026 (date de la ligne)");
    expect(effect).toContain("« Versement relayé par le cabinet »");
    expect(effect).toContain("Il attendra dans « Paiements à traiter » d'être affecté au dossier du débiteur");
    expect(effect).toContain("Le motif est conservé");
    expect(effect).toContain("À ne pas utiliser pour un approvisionnement");
    expect(LINK_KIND.relayed_payment).toBe("Paiement d'un débiteur relayé par le cabinet");
  });
  it("no longer tells ops that an own credit is never a debtor's payment", () => {
    expect(DEBIT_REVIEW.top_up_not_found).toContain("paiement d'un débiteur reçu par le cabinet");
    expect(DEBIT_REVIEW.top_up_not_found).not.toContain("sinon classez-le");
    expect(ownCreditEffect("1,00 €")).not.toContain("aucun débiteur");
  });
  it("maps the release's refusals to French", () => {
    const cases: [string, string][] = [
      ["own credit release refused: not_own_credit", "not_own_credit"],
      ["own credit release refused: already_booked", "already_booked"],
      ["own credit release refused: already_linked", "already_linked"],
      ["own credit release refused: reason_required", "reason_required"],
      ["own credit release refused: something_new", "booking_refused"],
      ["not allowed", "not_allowed"],
    ];
    for (const [message, code] of cases) {
      expect(debitErrorCode(message), message).toBe(code);
      expect(errorText(debitErrorCode(message))).not.toBe(errorText("unknown"));
    }
    expect(errorText("not_own_credit")).toContain("compte propre du cabinet");
    expect(errorText("not_own_credit")).toContain("compte de reversement d'un client");
  });
});

describe("a debtor's payment relayed by a client (review M2c-2)", () => {
  it("is offered on a credit from a client's payout IBAN only", () => {
    expect(clientRelayable({ direction: "credit", kind: "client_transfer_in" })).toBe(true);
    expect(clientRelayable({ direction: "credit", kind: "own_transfer_in" })).toBe(false);
    expect(clientRelayable({ direction: "credit", kind: "debtor_credit" })).toBe(false);
    expect(clientRelayable({ direction: "debit", kind: "client_transfer_in" })).toBe(false);
    // the own-credit action stays the servicer's
    expect(relayable({ direction: "credit", kind: "client_transfer_in", end_to_end_id: null })).toBe(false);
  });
  it("says what it does, and when not to use it, before it is sent", () => {
    const effect = clientRelayedPaymentEffect({ amount: "120,00 €", dateFr: "06/11/2026" });
    expect(effect).toContain("Le crédit de 120,00 € venant du compte de reversement d'un client deviendra un paiement reçu");
    expect(effect).toContain("au 06/11/2026 (date de la ligne), payeur « Versement relayé par le client »");
    expect(effect).toContain("« Paiements à traiter »");
    expect(effect).toContain("indiquez quel débiteur a payé le client");
    expect(effect).toContain("À ne pas utiliser pour le règlement d'une facture du cabinet par le client");
    expect(effect).toContain("reçu directement par le client");
    expect(RELAY_LABEL.client).toBe("Paiement d'un débiteur relayé par le client");
    expect(RELAY_LABEL.servicer).toBe(LINK_KIND.relayed_payment);
  });
  it("names who relayed a decided line", () => {
    expect(decisionLabel("relayed_payment", "client_transfer_in")).toBe("Paiement d'un débiteur relayé par le client");
    expect(decisionLabel("relayed_payment", "own_transfer_in")).toBe("Paiement d'un débiteur relayé par le cabinet");
    expect(decisionLabel("fee", "other_debit")).toBe(LINK_KIND.fee);
    expect(decisionLabel("something_new", "x")).toBe("something_new");
  });
  it("tells ops a client's credit may be either an invoice paid or a relayed payment", () => {
    expect(DEBIT_REVIEW.client_credit).toContain("paiement d'un débiteur que le client relaie");
  });
});

describe("the law, and the servicer's own rules", () => {
  it("never presents the one-account-per-currency rule or the fee rule as the law", () => {
    expect(errorText("client_funds_exists")).toContain("le cabinet a choisi un seul compte dédié par devise");
    expect(errorText("client_funds_exists")).not.toContain("R124");
    expect(errorText("not_a_fee")).not.toContain("virement émis)");
    expect(errorText("iban_taken")).toContain("pour un autre usage");
  });
});

describe("the nightly checks of the two funds", () => {
  it("has French words for every new code", () => {
    for (const code of [
      "own_fund_identity",
      "fund_mirror",
      "client_payable_debit",
      "remittance_completeness",
      "servicer_shortfall",
    ]) {
      expect(CHECK_LABEL[code]?.label, code).toBeTruthy();
      expect(CHECK_LABEL[code]?.help, code).toBeTruthy();
    }
  });
});
