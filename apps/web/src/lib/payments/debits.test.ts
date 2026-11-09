import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { entryLabel, paymentActions } from "./allocation";
import {
  CHECK_LABEL,
  DEBIT_REVIEW,
  DIRECT_REFUSAL,
  checkLabel,
  debitErrorCode,
  explainable,
  lineKindLabel,
  linkRefundEffect,
  minorToInput,
  normaliseIban,
  refundReasons,
  refundable,
  releaseEffect,
  returnEffect,
  returnedNote,
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
    const full = returnEffect({ amount: "200,00 €", left: "0,00 €", full: true, dateFr: "03/11/2026", hasFile: true });
    expect(full).toContain("annulés au 03/11/2026 (date du retour)");
    expect(full).toContain("Notification enregistrée pour le client (envoi : à venir)");
    expect(full).not.toContain("informé");
    expect(full).toContain("quittance annulée");
    const partial = returnEffect({ amount: "40,00 €", left: "60,00 €", full: false, dateFr: "02/11/2026", hasFile: true });
    expect(partial).toContain("Il restera 60,00 € du paiement");
    expect(partial).not.toContain("quittance annulée");
  });

  it("promises no receipt, imputation or client for a payment on no file (review M2b-6)", () => {
    const full = returnEffect({ amount: "50,00 €", left: "0,00 €", full: true, dateFr: "05/11/2026", hasFile: false });
    expect(full).toContain("rattaché à aucun dossier");
    expect(full).toContain("comptabilisé au 05/11/2026");
    expect(full).not.toContain("quittance annulée");
    expect(full).not.toContain("factures");
    expect(full).not.toContain("Notification");
    expect(full).toContain("« retourné »");
  });

  it("words a returned payment's note from what happened (review M2b-6)", () => {
    const when = (iso: string) => iso.slice(0, 10);
    const n = (kind: string, reason: string | null, delivered_at: string | null = null) => ({
      kind,
      reason,
      created_at: "2026-11-05T09:00:00Z",
      client_name: "Martin SAS",
      delivered_at,
    });
    // allocated, receipt void, the client's notification recorded but not read yet
    const allocated = returnedNote(
      {
        hasFile: true,
        notifications: [n("payment_allocated", null), n("payment_allocation_reversed", "bank_return"), n("payment_returned", "bank_return")],
        latestReceiptKind: "void",
      },
      when,
    );
    expect(allocated).toContain("Ses imputations sont annulées à la date du retour");
    expect(allocated).toContain("Sa quittance est annulée.");
    expect(allocated).toContain("notification enregistrée pour Martin SAS le 2026-11-05 (envoi : à venir)");
    expect(allocated).not.toContain("informé");
    // read in the client space: delivered
    const read = returnedNote(
      { hasFile: true, notifications: [n("payment_returned", "bank_return", "2026-11-06T08:00:00Z")], latestReceiptKind: "void" },
      when,
    );
    expect(read).toContain("notification remise à Martin SAS dans son espace client le 2026-11-06");
    // held on its file (never imputed), receipt still in force: nothing about imputations, the void version to come
    const held = returnedNote(
      { hasFile: true, notifications: [n("payment_held", "hold_blocks_allocation"), n("payment_returned", "bank_return")], latestReceiptKind: "original" },
      when,
    );
    expect(held).not.toContain("imputations");
    expect(held).toContain("L'annulation de sa quittance est en cours.");
    // forwarded: its remittance cancelled, no invoice
    const forwarded = returnedNote(
      { hasFile: true, notifications: [n("payment_forward_reversed", "bank_return"), n("payment_returned", "bank_return")], latestReceiptKind: null },
      when,
    );
    expect(forwarded).toContain("Son reversement au client est annulé");
    expect(forwarded).not.toContain("factures");
    expect(forwarded).not.toContain("quittance");
    // on no file: no receipt, no client
    const unmatched = returnedNote({ hasFile: false, notifications: [], latestReceiptKind: null }, when);
    expect(unmatched).toBe("La banque a repris ce paiement. Il n'est rattaché à aucun dossier : ni quittance, ni information d'un client.");
  });

  it("asks ops to check a refund's debit that does not carry its RFD reference (review M2b-6)", () => {
    const named = linkRefundEffect({ direction: "debit", lineRef: "RFD0123456789AB", refundRef: "RFD0123456789AB", payee: "DIALLO" });
    expect(named).toBe("Le débit est le virement RFD0123456789AB à DIALLO : le remboursement sera comptabilisé à la date du débit.");
    // read as a plain debit (other_debit): no reference, or another one
    for (const lineRef of [null, "NOTPROVIDED"]) {
      const plain = linkRefundEffect({ direction: "debit", lineRef, refundRef: "RFD0123456789AB", payee: "DIALLO" });
      expect(plain).toContain("ne porte pas la référence RFD0123456789AB");
      expect(plain).toContain("vérifiez dans la banque");
    }
    expect(linkRefundEffect({ direction: "credit", lineRef: null, refundRef: "RFD0123456789AB", payee: "DIALLO" })).toContain(
      "revenu impayé",
    );
  });

  it("names lines and the job's reasons in French", () => {
    expect(lineKindLabel("return", "debit")).toBe("Retour d'un paiement reçu");
    expect(lineKindLabel("return", "credit")).toBe("Crédit annulant un débit");
    expect(lineKindLabel("refund_out", "debit")).toContain("RFD");
    expect(Object.keys(DEBIT_REVIEW).sort()).toEqual(
      [
        "already_returned",
        "ambiguous",
        "amount_differs",
        "before_previous_return",
        "changed",
        "no_candidate",
        "partial_return",
        "payment_changed",
        "payment_returned",
        "posting_failed",
        "refund_not_pending",
        // not stored: the queue's reason for an other debit of a requested refund's amount
        "refund_amount_match",
      ].sort(),
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

describe("suspected duplicates (review M2b-6)", () => {
  it("says what « Libérer » does by what the import read the line as", () => {
    const amount = "120,00 €";
    expect(releaseEffect({ direction: "credit", heldKind: "debtor_credit", amount })).toContain("deviendra un paiement reçu de 120,00 €");
    expect(releaseEffect({ direction: "credit", heldKind: "batch_unsplit", amount })).toContain("paiement reçu");
    // a credit read as a return (« RETOUR VIR SEPA … »): no payment, no cash booked by the release
    const returned = releaseEffect({ direction: "credit", heldKind: "return", amount });
    expect(returned).not.toContain("deviendra un paiement");
    expect(returned).toContain("« À classer »");
    expect(returned).toContain("Aucun paiement n'est créé");
    expect(releaseEffect({ direction: "debit", heldKind: "refund_out", amount })).toContain("retour ou un remboursement");
    expect(releaseEffect({ direction: "debit", heldKind: "other_debit", amount })).toContain("non comptabilisée");
    // reading not told: a credit's sheet gives both outcomes, never a bare promise of a payment
    const unknown = releaseEffect({ direction: "credit", heldKind: null, amount });
    expect(unknown).toContain("lecture faite à l'import");
    expect(unknown).toContain("sans paiement");
    expect(releaseEffect({ direction: "debit", heldKind: null, amount })).toContain("débit à traiter");
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

  it("words every refusal of a direct payment, a dead-lettered job included", () => {
    for (const code of ["more_than_due", "nothing_due", "before_servicing_start", "file_closed", "failed"])
      expect(DIRECT_REFUSAL[code], code).toBeDefined();
  });
});

describe("errors of the M2b-6 commands", () => {
  it("maps database messages to codes with French text", () => {
    const cases: [string, string][] = [
      ["refund: the reason does not match the payment's state", "refund_reason_mismatch"],
      ["refund: more than what is left of the payment", "refund_too_much"],
      ["refund: the payee's IBAN is required (the bank gave none)", "refund_iban_required"],
      // the payer's IBAN without a name from the bank (review M2b-6): a clear error, not « L'action a échoué »
      ["refund: the payee's name is required", "refund_name_required"],
      ["refund: invalid IBAN", "iban_invalid"],
      ["the payment changed: reload the page", "payment_changed"],
      ["debit link refused: payment_changed", "payment_changed"],
      ["debit link refused: already_linked", "already_linked"],
      ["debit link refused: amount_exceeds", "link_amount"],
      ["debit link refused: refund_pending", "refund_pending"],
      ["debit link refused: not_a_return", "link_refused"],
      // review M2b-6: the database's new refusals have their own text
      ["debit link refused: not_explainable", "not_explainable"],
      ["debit link refused: before_previous_return", "link_before_return"],
      ["debit link refused: payment_returned", "link_payment_returned"],
      ["debit link refused: posting_failed (LG007: ledger: payment p would be overdrawn)", "link_posting_failed"],
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

describe("classifying without booking", () => {
  it("is never offered for our refund or a return naming one of our payments (review M2b-6)", () => {
    expect(explainable({ direction: "debit", kind: "return", namesPayment: true })).toBe(false);
    expect(explainable({ direction: "debit", kind: "refund_out", namesPayment: false })).toBe(false);
    // a return naming nothing of ours (a fee's direct debit the bank rejected) is explained with a motif
    expect(explainable({ direction: "debit", kind: "return", namesPayment: false })).toBe(true);
    expect(explainable({ direction: "debit", kind: "other_debit", namesPayment: false })).toBe(true);
    // a credit undoing a fee stays explainable (ADR choice #7)
    expect(explainable({ direction: "credit", kind: "return", namesPayment: true })).toBe(true);
  });
  it("has a label for every review code the debit job writes", () => {
    for (const code of ["posting_failed", "refund_amount_match", "payment_returned", "before_previous_return", "payment_changed"])
      expect(DEBIT_REVIEW[code], code).toBeDefined();
  });
});
