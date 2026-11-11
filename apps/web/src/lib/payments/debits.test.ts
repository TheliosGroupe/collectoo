import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { entryLabel, paymentActions } from "./allocation";
import {
  CHECK_LABEL,
  DEBIT_REVIEW,
  DIRECT_REFUSAL,
  checkLabel,
  checkSubjectLink,
  debitErrorCode,
  explainable,
  lineKindLabel,
  linkRefundEffect,
  minorToInput,
  normaliseIban,
  pendingRefundInstruction,
  refundCancellable,
  refundExecutionMode,
  refundInDownloadedFile,
  refundInDownloadedFileNote,
  refundModeEffect,
  refundReasons,
  refundTransfers,
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
        // M2c-1: our own transfers and credits
        "top_up_not_found",
        "top_up_differs",
        "client_credit",
        "own_transfer_out",
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
    expect(releaseEffect({ direction: "debit", heldKind: "other_debit", amount })).toContain("frais bancaires");
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

describe("the remittances' nightly checks (M2c-4 and its review)", () => {
  it("has French words for every code the remittance checks and the worker write", () => {
    for (const code of [
      "remittance_item_twice",
      "remittance_run_totals",
      "invoice_numbering",
      "invoice_ledger",
      "settlement_ledger",
      "vat_pending_ledger",
      "remittance_deadline_breached",
      "remittance_delay_unmeetable",
      "remittance_due_critical",
      "remittance_due_soon",
      "payout_blocked",
      "draft_waiting",
      "invoice_late",
      "unallocated_deadline",
      // review M2c-4 (nc#0, legal#3; tests-ui#3 is draft_waiting widened)
      "remittance_deadline_not_computable",
      "remittance_schedule_failed",
      "remittance_payout_overdue",
      "remittance_payout_not_executed",
      // review M2c-4, round 2 (legal#4): an invoice open after the date it is paid by
      "invoice_overdue",
      // review M2c-5 (perf#2 = tests-ui#2, K4): documents the job could not draw, or still not drawn after 24 h
      "remittance_document_failed",
      "remittance_document_missing",
      // M2c-5b (I22): a file's key state and its invoices' open charges and waivers disagree
      "commission_key_state",
      // review M2c-5b (legal#0, F2): a credit note's refund owed no run has settled after 30 days
      "credit_refund_owed",
    ]) {
      expect(CHECK_LABEL[code]?.label, code).toBeTruthy();
      expect(CHECK_LABEL[code]?.help, code).toBeTruthy();
    }
  });

  it("never says a payout was paid before the bank's debit", () => {
    for (const code of ["remittance_payout_overdue", "remittance_payout_not_executed"]) {
      expect(CHECK_LABEL[code]?.help, code).toContain("débit");
      expect(CHECK_LABEL[code]?.label.toLowerCase(), code).not.toContain("payé");
    }
  });

  it("says a key I22 flags keeps the next run's commission pending, the client's money remitted gross (M2c-5b review round 2)", () => {
    const help = checkLabel("commission_key_state").help;
    expect(help).toMatch(/commission en attente/);
    expect(help).toMatch(/reversement brut/);
    expect(help).not.toMatch(/bloqu/);
  });

  it("says a credit note's refund is still owed, never that it was refunded (review M2c-5b legal#0, F2)", () => {
    const l = checkLabel("credit_refund_owed");
    expect(l.label).toMatch(/à rembourser/i);
    expect(l.help).toMatch(/30 jours/);
    for (const text of [l.label, l.help]) expect(text.toLowerCase()).not.toMatch(/remboursé|payé/);
  });

  it("leads a result on an invoice or a credit note to its page (review M2c-5b F2)", () => {
    const base = { currency: "EUR", amount: "3600", count: null, oldest_days: 31, id: "r", severity: "alert" };
    expect(checkSubjectLink({ ...base, code: "credit_refund_owed", subject_type: "commission_invoice", subject_id: "c1" })).toBe(
      "/backoffice/reversements/factures/c1",
    );
    expect(checkSubjectLink({ ...base, code: "invoice_overdue", subject_type: "commission_invoice", subject_id: "i1" })).toBe(
      "/backoffice/reversements/factures/i1",
    );
    expect(checkSubjectLink({ ...base, code: "remittance_due_soon", subject_type: "organization", subject_id: "o1" })).toBe(
      "/backoffice/reversements",
    );
    expect(checkSubjectLink({ ...base, code: "payment_position", subject_type: "payment", subject_id: "p1" })).toBe(
      "/backoffice/encaissements/paiements/p1",
    );
    expect(checkSubjectLink({ ...base, code: "receivable_negative", subject_type: "account", subject_id: "a1" })).toBeNull();
  });
});

describe("the transfers' checks (M2c-6a and its review: T3, T6)", () => {
  const base = { currency: "EUR", amount: "583840", count: 2, oldest_days: 0, id: "r", severity: "alert" };

  it("has French words for every code the transfer checks write, the stuck file and the held transfers included", () => {
    for (const code of [
      "transfer_not_filed",
      "file_not_downloaded",
      "file_not_marked_sent",
      "transfer_not_debited",
      "transfer_file_failed",
      "payee_name_mismatch",
      // review T6 (tests-ui#10): a file the job has not finished writing after 15 minutes
      "transfer_file_pending",
      // review T3: held out of every file until the data changes
      "payee_name_not_epc",
      "iban_not_sepa",
      // review round 2 (D4): a cancelled file executed late after all
      "transfer_already_debited",
    ]) {
      expect(CHECK_LABEL[code]?.label, code).toBeTruthy();
      expect(CHECK_LABEL[code]?.help, code).toBeTruthy();
      expect(`${CHECK_LABEL[code]?.label} ${CHECK_LABEL[code]?.help}`.toLowerCase(), code).not.toMatch(/payé|débité le/);
    }
    expect(checkLabel("transfer_file_pending").label).toContain("15 minutes");
    expect(checkLabel("transfer_file_pending").help).toContain("En préparation");
    // review T6 (concurrency-perf#2): checked every hour at the account's cut-off, not only the night after
    expect(checkLabel("file_not_marked_sent").help).toContain("toutes les heures");
    // review round 5 (fail-closed): no cancellation after download yet — keep the file, check the statement, the bank
    expect(checkLabel("file_not_marked_sent").help).toContain("ne peut pas encore être annulé");
    expect(checkLabel("file_not_marked_sent").help).toContain("voyez avec la banque");
    expect(checkLabel("file_not_marked_sent").help).not.toContain("demandez son annulation");
    // review T3: a name without EPC characters no longer fails the file (it is held out)
    expect(checkLabel("transfer_file_failed").help).not.toContain("nom de bénéficiaire");
    expect(checkLabel("transfer_not_filed").help).toContain("IBAN hors de la zone SEPA");
    // review round 2 (D4): never re-done by hand, the sweep held meanwhile
    expect(checkLabel("transfer_already_debited").help).toContain("Ne refaites aucun virement");
    expect(checkLabel("transfer_already_debited").help).toContain("quote-part");
  });

  it("leads a file's alert to the file, the others to « Virements »", () => {
    expect(checkSubjectLink({ ...base, code: "file_not_marked_sent", subject_type: "transfer_file", subject_id: "f1" })).toBe(
      "/backoffice/reversements/virements/f1",
    );
    expect(checkSubjectLink({ ...base, code: "transfer_file_pending", subject_type: "transfer_file", subject_id: "f2" })).toBe(
      "/backoffice/reversements/virements/f2",
    );
    for (const [code, subject] of [
      ["transfer_not_filed", "bank_account"],
      ["transfer_not_debited", "bank_account"],
      ["payee_name_mismatch", "client_payout_account"],
      ["iban_not_sepa", "bank_transfer"],
      ["payee_name_not_epc", "bank_transfer"],
      ["transfer_already_debited", "bank_transfer"],
    ])
      expect(checkSubjectLink({ ...base, code, subject_type: subject, subject_id: "x" }), code).toBe("/backoffice/reversements/virements");
  });
});

describe("the refund's execution (M2c-6a review, tests-ui#8)", () => {
  it("sends only an explicit choice: without one the database defaults (file when the account and the IBAN allow it)", () => {
    expect(refundExecutionMode("file")).toBe("file");
    expect(refundExecutionMode("manual")).toBe("manual");
    expect(refundExecutionMode("auto")).toBeUndefined();
    expect(refundExecutionMode("")).toBeUndefined();
    expect(refundExecutionMode("FILE")).toBeUndefined();
  });

  it("says what the RFD reference becomes, the default naming both outcomes", () => {
    expect(refundModeEffect("file")).toContain("prochain fichier de virements");
    expect(refundModeEffect("file")).toContain("ne l'exécutez pas aussi à la main");
    expect(refundModeEffect("manual")).toContain("référence de bout en bout");
    const auto = refundModeEffect("auto");
    expect(auto).toContain("si le compte de fonds de tiers peut le payer");
    expect(auto).toContain("zone SEPA");
    expect(auto).toContain("sinon il est à exécuter dans la banque");
  });

  it("tells ops to execute a pending refund by hand only when it is not in the transfer file (risk R4)", () => {
    // integration: with the sheet's default the database chooses; the page must say which, never « exécutez » for a
    // refund the file pays (paid twice)
    const file = pendingRefundInstruction(true);
    expect(file).toContain("prochain fichier de virements");
    expect(file).toContain("ne l'exécutez pas dans la banque");
    expect(file).not.toContain("exécutez le virement");
    const manual = pendingRefundInstruction(false);
    expect(manual).toContain("exécutez le virement dans la banque");
    expect(manual).toContain("référence de bout en bout");
  });

  it("words the refusals a transfer file gives a refund", () => {
    const cases: [string, string][] = [
      ["refund: its transfer is in file TF-2026-000086, already downloaded: cancel the file first", "refund_in_downloaded_file"],
      ["refund refused: in_downloaded_file", "refund_in_downloaded_file"],
      ["refund refused: payee_name_not_epc", "refund_payee_name_not_epc"],
      ["refund refused: iban_not_sepa", "refund_iban_not_sepa"],
      ["refund: this account pays no transfer file", "transfer_not_paying_account"],
    ];
    for (const [message, code] of cases) {
      expect(debitErrorCode(message), message).toBe(code);
      expect(errorText(debitErrorCode(message))).not.toBe(errorText("unknown"));
    }
    expect(errorText("refund_in_downloaded_file")).toContain("pas encore disponible");
    expect(errorText("refund_in_downloaded_file")).toContain("voyez avec la banque");
    expect(errorText("refund_iban_not_sepa")).toContain("Je l'exécute moi-même");
  });
});

describe("M2c-6a review, round 3 (E2): a refund whose transfer was debited already is not cancelled", () => {
  it("maps the refusal and words it, and the alert names the replaced reference", () => {
    expect(debitErrorCode("refund refused: already_debited")).toBe("refund_already_debited");
    expect(debitErrorCode("refund refused: in_downloaded_file")).toBe("refund_in_downloaded_file");
    expect(errorText("refund_already_debited")).toContain("remboursé une seconde fois");
    expect(errorText("refund_already_debited")).not.toBe(errorText("unknown"));
    expect(checkLabel("transfer_already_debited").help).toContain("celle du virement qu'il remplace");
    expect(checkLabel("transfer_already_debited").help).toContain("demandez à la banque de ne pas l'exécuter");
  });
});

describe("M2c-6a review, round 4 (G1, G2): what left the account late is never paid twice", () => {
  it("refuses linking an old reference's debit while the refund's re-issue is in a downloaded file", () => {
    const message = "debit link refused: posting_failed (23514: refund refused: reissue_in_downloaded_file)";
    expect(debitErrorCode(message)).toBe("refund_reissue_in_downloaded_file");
    // review round 5 (fail-closed): the file cannot be cancelled first any more — the debit is not linked
    expect(errorText("refund_reissue_in_downloaded_file")).toContain("Ne le rattachez pas");
    expect(errorText("refund_reissue_in_downloaded_file")).toContain("voyez avec la banque");
    expect(errorText("refund_reissue_in_downloaded_file")).not.toContain("annuler ce fichier");
    expect(debitErrorCode("refund refused: in_downloaded_file")).toBe("refund_in_downloaded_file");
  });
  it("alerts a transfer cancelled alone and debited late after all", () => {
    expect(checkLabel("transfer_already_debited").help).toContain("annulé seul");
    // round 4's verifier (SW2): a sweep already in a downloaded file is not stopped by it — said so
    expect(checkLabel("transfer_already_debited").help).toContain("aucune nouvelle quote-part");
    expect(checkLabel("transfer_already_debited").help).toContain("n'est pas arrêtée");
  });
});

describe("M2c-6a review, round 6: a refund whose transfer is in a downloaded file", () => {
  const file = (status: string, download_count: number) => ({ id: "f1", number: "TF-2026-000142", status, download_count });
  it("reads each refund's transfer and file", () => {
    const map = refundTransfers(
      [
        { id: "r1", transfer_id: "t1" },
        { id: "r2", transfer_id: null },
        { id: "r3", transfer_id: "t9" },
      ],
      [{ id: "t1", status: "in_file", transfer_file: file("downloaded", 1) }],
    );
    expect(map.get("r1")).toEqual({ status: "in_file", file: file("downloaded", 1) });
    expect(map.has("r2")).toBe(false);
    expect(map.has("r3")).toBe(false);
  });

  it("offers « Annuler » only while its transfer is in no downloaded file (the database refuses: in_downloaded_file)", () => {
    expect(refundCancellable("requested", undefined)).toBe(true);
    expect(refundCancellable("requested", { status: "ordered", file: null })).toBe(true);
    expect(refundCancellable("requested", { status: "in_file", file: file("generated", 0) })).toBe(true);
    expect(refundCancellable("requested", { status: "in_file", file: file("downloaded", 1) })).toBe(false);
    expect(refundCancellable("requested", { status: "in_file", file: file("sent", 2) })).toBe(false);
    expect(refundCancellable("executed", { status: "booked", file: file("sent", 2) })).toBe(false);
    expect(refundCancellable("cancelled", undefined)).toBe(false);
    expect(refundInDownloadedFile({ status: "in_file", file: file("downloaded", 1) })).toBe(true);
    expect(refundInDownloadedFile({ status: "booked", file: file("downloaded", 1) })).toBe(false);
    expect(refundInDownloadedFile({ status: "in_file", file: file("generated", 0) })).toBe(false);
  });

  it("says why instead, as the run's page: « en cours » until its debit is read, no cancellation after download", () => {
    const note = refundInDownloadedFileNote("TF-2026-000142");
    expect(note).toContain("dans le fichier TF-2026-000142, déjà téléchargé");
    expect(note).toContain("« en cours »");
    expect(note).toContain("ne peut pas être annulé d'ici là");
    expect(note).toContain("pas encore disponible");
    expect(note).toContain("voyez avec la banque");
    expect(note).not.toMatch(/annulez-le|demandez (son |l')annulation|faites d'abord annuler/);
  });

  it("refuses a debit that carries neither the refund's reference nor its lot's in that file (G2's rule, now)", () => {
    expect(errorText("refund_reissue_in_downloaded_file")).toContain(
      "ni la référence du virement de ce remboursement ni celle de son lot",
    );
  });
});
