import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { CHECK_LABEL, DEBIT_REVIEW } from "@/lib/payments/debits";
import {
  DEDICATED_LINE_EFFECT,
  type PaymentPreview,
  clientPaymentRefusal,
  clientRefundRefusal,
  clientSpaceCreditLines,
  clientSpaceCreditSections,
  creditLabel,
  creditOwedText,
  currentPreview,
  dedicatedLineEffect,
  designationSentence,
  parseClientSpaceCredits,
  parseOpenDocuments,
  parsePaymentPreview,
  parsePaymentResult,
  paymentEffect,
  previewInputs,
  refundHeader,
  refusalCode,
  resultEffect,
  staffCreditGroups,
  writtenOffChoice,
  writtenOffLine,
} from "./settlements";

// M2c-7c-1 (plan docs/design/m2c-7-plan.md §5.5): « Ce que le client doit au cabinet », the « Enregistrer un
// règlement » sheet, « Règlement d'une facture ou d'une avance du cabinet », « Enregistrer le remboursement » and the
// client space's credits. Every amount and date is SQL's (text); these only word them.

const INVOICE = {
  id: "11111111-1111-1111-1111-111111111111",
  number: "FC-2026-000004",
  issue_date: "2026-11-02",
  due_date: "2026-12-02",
  settlement: "netted",
  ttc_minor: "3600",
  open_minor: "3600",
  pending_vat_minor: "600",
  before_opening: false,
  payable: true,
  in_flight_run: null,
};
const ADVANCE = {
  id: "22222222-2222-2222-2222-222222222222",
  cause: "remitted_reversal",
  created_on: "2026-11-14",
  born_on: "2026-11-12",
  amount_minor: "20000",
  open_minor: "20000",
  mandate_reference: "MAND-MARTIN-2026",
  recovery: "request",
  clause_ref: null,
  before_opening: false,
  payable: true,
  in_flight_run: null,
};
const DOCS = {
  client_id: "33333333-3333-3333-3333-333333333333",
  currency: "EUR",
  today: "2026-11-20",
  procedure: false,
  own_account: true,
  invoices: [INVOICE],
  advances: [ADVANCE],
  written_off: [
    {
      id: "44444444-4444-4444-4444-444444444444",
      cause: "double_payout",
      born_on: "2026-10-01",
      written_off_on: "2026-10-30",
      written_off_minor: "5000",
      recovered_minor: "0",
      available_minor: "5000",
      before_opening: false,
      payable: true,
    },
  ],
  refunds_owed: [
    { id: "55555555-5555-5555-5555-555555555555", number: "FC-2026-000006", issue_date: "2026-11-10", owed_minor: "1200", in_flight_run: null },
  ],
  credits: [
    { id: "66666666-6666-6666-6666-666666666666", cause: "overpayment", created_on: "2026-11-18", received_on: "2026-11-18", amount_minor: "500", open_minor: "500" },
  ],
  default_order: [
    { document_kind: "advance", document_id: ADVANCE.id },
    { document_kind: "invoice", document_id: INVOICE.id },
  ],
  default_open_minor: "23600",
};

describe("« Ce que le client doit au cabinet » (public.client_open_documents)", () => {
  it("parses SQL's read, amounts as text", () => {
    const d = parseOpenDocuments(DOCS);
    expect(d?.invoices[0].open_minor).toBe("3600");
    expect(d?.advances[0].born_on).toBe("2026-11-12");
    expect(d?.credits[0].cause).toBe("overpayment");
    expect(d?.default_order.map((x) => x.document_kind)).toEqual(["advance", "invoice"]);
  });
  it("refuses anything not its shape: an amount as a number, an unknown cause, a missing date", () => {
    expect(parseOpenDocuments({ ...DOCS, invoices: [{ ...INVOICE, open_minor: 3600 }] })).toBeNull();
    expect(parseOpenDocuments({ ...DOCS, credits: [{ ...DOCS.credits[0], cause: "gift" }] })).toBeNull();
    expect(parseOpenDocuments({ ...DOCS, advances: [{ ...ADVANCE, born_on: null }] })).toBeNull();
    expect(parseOpenDocuments({ ...DOCS, default_open_minor: "1.5" })).toBeNull();
    // (review round 1, MONEY-1) a written-off advance carries whether the client may still repay it
    expect(parseOpenDocuments({ ...DOCS, written_off: [{ ...DOCS.written_off[0], payable: undefined }] })).toBeNull();
  });
});

describe("the sheet's live effect (public.client_payment_preview)", () => {
  const docs = parseOpenDocuments(DOCS)!;
  it("words each part SQL planned: an invoice with the VAT it makes due, an advance by its date, a surplus", () => {
    const p = parsePaymentPreview({
      amount_minor: "24100",
      open_minor: "23600",
      credit_minor: "500",
      refusal: null,
      rows: [
        { ord: 1, document_kind: "invoice", document_id: INVOICE.id, number: INVOICE.number, amount_minor: "3600", vat_moved_minor: "600", cause: null },
        { ord: 2, document_kind: "advance", document_id: ADVANCE.id, number: null, amount_minor: "20000", vat_moved_minor: "0", cause: null },
        { ord: 3, document_kind: "client_credit", document_id: null, number: null, amount_minor: "500", vat_moved_minor: "0", cause: "overpayment" },
      ],
    })!;
    expect(paymentEffect(p, docs)).toBe(
      "FC-2026-000004 : 36,00 € réglés (dont TVA 6,00 € devenue exigible) ; avance du 12/11/2026 : 200,00 € remboursés ; " +
        "trop-perçu de 5,00 € à rembourser au client",
    );
  });
  it("a pre-opening document the client designates is never said to be settled: held for the procedure", () => {
    const p = parsePaymentPreview({
      amount_minor: "3600",
      open_minor: "3600",
      credit_minor: "3600",
      refusal: null,
      rows: [
        { ord: 1, document_kind: "client_credit", document_id: INVOICE.id, number: INVOICE.number, amount_minor: "3600", vat_moved_minor: "0", cause: "procedure" },
      ],
    })!;
    const effect = paymentEffect(p, docs);
    expect(effect).toContain(
      "Créance antérieure à l'ouverture de la procédure du client : la somme n'est pas imputée ; elle est inscrite comme à rendre à la procédure (avis de l'avocat, OQ-98)",
    );
    expect(effect).not.toContain("réglés");
  });
  it("a written-off advance repaid is a recovery, worded with its loss's date and the proposed account", () => {
    const p = parsePaymentPreview({
      amount_minor: "5000",
      open_minor: "5000",
      credit_minor: "0",
      refusal: null,
      rows: [
        { ord: 1, document_kind: "written_off", document_id: DOCS.written_off[0].id, number: null, amount_minor: "5000", vat_moved_minor: "0", cause: null },
      ],
    })!;
    expect(paymentEffect(p, docs)).toBe(
      "Avance passée en perte le 30/10/2026 : remboursement de 50,00 € enregistré en recette (compte proposé 7714, OQ-88)",
    );
  });
  it("a surplus while the client's proceeding stands is held for the procedure, never « à rembourser au client »", () => {
    const p = parsePaymentPreview({
      amount_minor: "800",
      open_minor: "0",
      credit_minor: "800",
      refusal: null,
      rows: [{ ord: 1, document_kind: "client_credit", document_id: null, number: null, amount_minor: "800", vat_moved_minor: "0", cause: "procedure" }],
    })!;
    expect(paymentEffect(p, docs)).toBe(
      "8,00 € inscrits comme à rendre à la procédure collective du client (avis de l'avocat, OQ-98)",
    );
  });
  it("(review round 1, MONEY-1) a written-off advance born before the opening is held for the procedure, never income", () => {
    const before = { ...DOCS.written_off[0], before_opening: true, payable: false };
    const d = parseOpenDocuments({ ...DOCS, procedure: true, written_off: [before] })!;
    const p = parsePaymentPreview({
      amount_minor: "5000",
      open_minor: "5000",
      credit_minor: "5000",
      refusal: null,
      rows: [
        { ord: 1, document_kind: "client_credit", document_id: before.id, number: null, amount_minor: "5000", vat_moved_minor: "0", cause: "procedure" },
      ],
    })!;
    const effect = paymentEffect(p, d);
    expect(effect).toBe(
      "Avance passée en perte le 30/10/2026 : 50,00 € — Créance antérieure à l'ouverture de la procédure du client : la somme n'est pas encaissée en recette ; elle est inscrite comme à rendre à la procédure (avis de l'avocat, OQ-98)",
    );
    expect(effect).not.toContain("7714");
    // the page's row and the sheet's choice say so too
    expect(writtenOffLine(d.written_off[0], "EUR")).toBe(
      "Avance du 01/10/2026 passée en perte le 30/10/2026 (reste 50,00 €) : créance antérieure à l'ouverture de la procédure du client ; une somme reçue pour elle n'est pas encaissée en recette, elle est mise de côté pour la procédure (avis de l'avocat, OQ-98)",
    );
    expect(writtenOffChoice(d.written_off[0], "EUR")).toBe(
      "Avance passée en perte le 30/10/2026 (50,00 € ; créance antérieure à l'ouverture de la procédure : mise de côté pour la procédure)",
    );
    const ok = docs.written_off[0];
    expect(writtenOffLine(ok, "EUR")).toBe(
      "Avance du 01/10/2026 passée en perte le 30/10/2026 : 50,00 € que le client peut encore rembourser (enregistré en recette, compte proposé 7714, OQ-88)",
    );
    expect(writtenOffChoice(ok, "EUR")).toBe("Avance passée en perte le 30/10/2026 (50,00 € à recouvrer)");
  });
  it("refuses a preview not of its shape (an amount as a number)", () => {
    expect(parsePaymentPreview({ amount_minor: 1, open_minor: "0", credit_minor: "0", refusal: null, rows: [] })).toBeNull();
  });
});

describe("the refusals, in French, per code", () => {
  it("reads the code from the database's message", () => {
    expect(refusalCode("client payment refused: not_open")).toBe("not_open");
    expect(refusalCode("client refund refused: owed_changed")).toBe("owed_changed");
    expect(refusalCode("something else")).toBeNull();
    // another command's refusal is never taken for one of these (« Classer sans comptabiliser » on the same line)
    expect(refusalCode("debit link refused: already_booked")).toBeNull();
  });
  it("words each of « Enregistrer un règlement »'s and the line's", () => {
    expect(clientPaymentRefusal("client payment refused: designation_evidence_required")).toBe(
      "Joignez la pièce où le client désigne ce qu'il règle ; sinon l'ordre par défaut s'applique.",
    );
    expect(clientPaymentRefusal("client payment refused: in_flight", "RV-2026-000003")).toBe(
      "Ce document est déjà réglé par le reversement RV-2026-000003 en cours : attendez son débit, ou enregistrez le règlement sans désigner de document.",
    );
    // (review round 1, TUI-7) the dedicated line cannot record without its label's designation: never offered there
    expect(clientPaymentRefusal("client payment refused: in_flight", "RV-2026-000003", "line")).toBe(
      "Le libellé désigne un document que le reversement RV-2026-000003 en cours règle déjà : attendez son débit.",
    );
    expect(clientPaymentRefusal("client payment refused: not_open", null, "line")).toBe(
      "Un document que désigne le libellé n'a plus rien à régler : rechargez la page.",
    );
    expect(clientPaymentRefusal("client payment refused: in_flight", "RV-2026-000003", "line")).not.toContain("sans désigner");
    expect(clientPaymentRefusal("client payment refused: not_open")).toBe(
      "Ce document (ou cette avance) n'a plus rien à régler : enregistrez le règlement sans le désigner ; la somme sera inscrite en trop-perçu à rembourser.",
    );
    expect(clientPaymentRefusal("client payment refused: open_changed")).toBe(
      "Les montants ont changé depuis l'affichage : rechargez la page.",
    );
    expect(clientPaymentRefusal("client payment refused: no_own_account")).toBe(
      "Aucun compte propre n'est enregistré (Paramètres › Facturation).",
    );
    expect(clientPaymentRefusal("client payment refused: not_a_client_credit")).toBe(
      "Ce crédit ne vient pas du compte de reversement d'un client : utilisez une autre action.",
    );
    expect(clientPaymentRefusal("client payment refused: line_booked")).toBe("Cette ligne est déjà comptabilisée.");
    expect(clientPaymentRefusal("client payment refused: our_reference")).toBe(
      "Cette ligne porte la référence de l'un de nos virements : c'est ce virement qui revient.",
    );
    expect(clientPaymentRefusal("client payment refused: ambiguous_client")).toBe(
      "Cet IBAN est le compte de reversement de plusieurs clients : prévenez le support.",
    );
    expect(clientPaymentRefusal("client payment refused: bad_date")).toBe("La date ne peut pas être dans le futur.");
    expect(clientPaymentRefusal("not allowed")).toBe(
      "Action réservée aux administrateurs et responsables des opérations (double authentification).",
    );
  });
  it("words each of « Enregistrer le remboursement »'s, with what is still owed", () => {
    expect(clientRefundRefusal("client refund refused: amount_exceeds_owed", { owed_minor: "1200", currency: "EUR", kind: "credit_note" })).toBe(
      "Le montant dépasse ce que l'avoir doit encore au client (12,00 €).",
    );
    expect(clientRefundRefusal("client refund refused: nothing_owed", { owed_minor: "0", currency: "EUR", kind: "credit_note" })).toBe(
      "Cet avoir ne doit plus rien au client.",
    );
    expect(clientRefundRefusal("client refund refused: nothing_owed", { owed_minor: "0", currency: "EUR", kind: "client_credit" })).toBe(
      "Ce trop-perçu est déjà remboursé.",
    );
    expect(clientRefundRefusal("client refund refused: in_flight", { owed_minor: "1200", currency: "EUR", kind: "credit_note" }, "RV-2026-000009")).toBe(
      "Déjà réglé par le reversement RV-2026-000009 en cours : attendez son débit.",
    );
    expect(clientRefundRefusal("client refund refused: owed_changed", { owed_minor: "1", currency: "EUR", kind: "credit_note" })).toBe(
      "Les montants ont changé depuis l'affichage : rechargez la page.",
    );
    // (review round 1, TUI-4) a sum held for the procedure is never « trop-perçu » nor owed to the client
    const procedure = { owed_minor: "5000", currency: "EUR", kind: "client_credit" as const, cause: "procedure" as const };
    expect(clientRefundRefusal("client refund refused: nothing_owed", procedure)).toBe(
      "Cette somme mise de côté pour la procédure est déjà rendue.",
    );
    expect(clientRefundRefusal("client refund refused: amount_exceeds_owed", procedure)).toBe(
      "Le montant dépasse ce qui reste à rendre à la procédure (50,00 €).",
    );
    expect(clientRefundRefusal("client refund refused: amount_exceeds_owed", { ...procedure, cause: "overpayment" })).toBe(
      "Le montant dépasse ce qui reste à rembourser au client (50,00 €).",
    );
  });
});

describe("the dedicated account's line and the texts made true", () => {
  it("states where the money goes", () => {
    expect(DEDICATED_LINE_EFFECT).toBe(
      "La somme revient au cabinet : elle sera virée sur son compte propre avec la prochaine quote-part.",
    );
  });
  it("the review of a client's credit names the new action", () => {
    expect(DEBIT_REVIEW.client_credit).toBe(
      "Virement reçu du compte de reversement d'un client : règlement d'une facture ou d'une avance du cabinet (« Règlement du client »), ou paiement d'un débiteur que le client relaie (il devient alors un paiement à affecter).",
    );
  });
  it("credit_refund_owed's help says how to pay it back, never « pas encore disponible »", () => {
    expect(CHECK_LABEL.credit_refund_owed.help).toContain(
      "sinon, remboursez-le par virement depuis le compte propre et enregistrez-le (« Enregistrer le remboursement » sur l'avoir).",
    );
    expect(CHECK_LABEL.credit_refund_owed.help).not.toContain("pas encore disponible");
  });
  it("the nightly's three new checks are worded", () => {
    // (review round 1, TUI-4) the check covers a sum held for a procedure too: its payee is the procedure's
    expect(CHECK_LABEL.client_credit_owed.label).toBe("Somme à rembourser au client ou à rendre à sa procédure");
    expect(CHECK_LABEL.client_credit_owed.help).toContain(
      "Une somme mise de côté pour la procédure est signalée tout de suite : elle est à rendre à la procédure (administrateur, mandataire ou liquidateur), pas au client ; à qui et quand se décide avec l'avocat (OQ-98).",
    );
    expect(CHECK_LABEL.client_credit_owed.help).not.toContain("comme due au client");
    expect(CHECK_LABEL.client_credit_ledger.label).toBe("Sommes dues aux clients ≠ compte 419");
    expect(CHECK_LABEL.written_off_recovery_ledger.label).toBe("Recouvrements d'avances passées en perte ≠ compte 7714");
  });
});

describe("the client space's credits (public.client_space_credits)", () => {
  it("states what the servicer owes it back, by its date; a sum held for its proceeding is never « vous doit »", () => {
    const c = parseClientSpaceCredits({
      rows: [
        { credit_id: "a", currency: "EUR", cause: "overpayment", created_on: "2026-11-18", received_on: "2026-11-18", open_minor: "500" },
        { credit_id: "b", currency: "EUR", cause: "procedure", created_on: "2026-11-19", received_on: "2026-11-19", open_minor: "1200" },
      ],
      total: [{ currency: "EUR", open_minor: "1700" }],
    })!;
    expect(clientSpaceCreditLines(c)).toEqual([
      "Trop-perçu du 18/11/2026 : 5,00 € que le cabinet vous doit",
      "Somme reçue le 19/11/2026, mise de côté pour votre procédure collective : 12,00 €",
    ]);
    expect(parseClientSpaceCredits({ rows: [{ credit_id: "a" }], total: [] })).toBeNull();
  });
  it("(review round 1, TUI-1) titles each section by what it holds: « vous doit » only over what is owed to it", () => {
    const only = parseClientSpaceCredits({
      rows: [{ credit_id: "b", currency: "EUR", cause: "procedure", created_on: "2026-11-24", received_on: "2026-11-24", open_minor: "5000" }],
      total: [{ currency: "EUR", open_minor: "5000" }],
    })!;
    const s = clientSpaceCreditSections(only);
    expect(s.map((x) => x.title)).toEqual(["Sommes reçues pendant votre procédure collective"]);
    expect(JSON.stringify(s)).not.toContain("vous doit");
    expect(s[0].lines).toEqual([
      { id: "b", text: "Somme reçue le 24/11/2026, mise de côté pour votre procédure collective : 50,00 €" },
    ]);
    expect(s[0].note).toBeNull();
    const both = parseClientSpaceCredits({
      rows: [
        { credit_id: "a", currency: "EUR", cause: "overpayment", created_on: "2026-11-18", received_on: "2026-11-18", open_minor: "500" },
        { credit_id: "b", currency: "EUR", cause: "procedure", created_on: "2026-11-19", received_on: "2026-11-19", open_minor: "1200" },
      ],
      total: [{ currency: "EUR", open_minor: "1700" }],
    })!;
    expect(clientSpaceCreditSections(both)).toEqual([
      {
        title: "Sommes que le cabinet vous doit",
        testId: "client-space-credits",
        lines: [{ id: "a", text: "Trop-perçu du 18/11/2026 : 5,00 € que le cabinet vous doit" }],
        note: "Le cabinet rembourse un trop-perçu par virement depuis son compte propre.",
      },
      {
        title: "Sommes reçues pendant votre procédure collective",
        testId: "client-space-procedure-credits",
        lines: [{ id: "b", text: "Somme reçue le 19/11/2026, mise de côté pour votre procédure collective : 12,00 €" }],
        note: null,
      },
    ]);
    expect(clientSpaceCreditSections({ rows: [], total: [] })).toEqual([]);
  });
});

describe("(review round 3) a credit is dated by the money's receipt (received_on), never its recording", () => {
  // 045 sl10: Lilas, in redressement, paid 50,00 € value-dated 22/11 (own account) and 70,00 € booked 23/11 (dedicated
  // account), both recorded 24/11; Moreau paid 5,00 € value-dated 20/11, recorded 24/11
  it("words the client space's lines with received_on", () => {
    const c = parseClientSpaceCredits({
      rows: [
        { credit_id: "a", currency: "EUR", cause: "procedure", created_on: "2026-11-24", received_on: "2026-11-22", open_minor: "5000" },
        { credit_id: "b", currency: "EUR", cause: "procedure", created_on: "2026-11-24", received_on: "2026-11-23", open_minor: "7000" },
        { credit_id: "c", currency: "EUR", cause: "overpayment", created_on: "2026-11-24", received_on: "2026-11-20", open_minor: "500" },
      ],
      total: [{ currency: "EUR", open_minor: "12500" }],
    })!;
    expect(clientSpaceCreditLines(c)).toEqual([
      "Somme reçue le 22/11/2026, mise de côté pour votre procédure collective : 50,00 €",
      "Somme reçue le 23/11/2026, mise de côté pour votre procédure collective : 70,00 €",
      "Trop-perçu du 20/11/2026 : 5,00 € que le cabinet vous doit",
    ]);
    expect(JSON.stringify(clientSpaceCreditSections(c))).not.toContain("24/11/2026");
    // a row without its receipt date is not the shape
    expect(
      parseClientSpaceCredits({
        rows: [{ credit_id: "a", currency: "EUR", cause: "procedure", created_on: "2026-11-24", open_minor: "5000" }],
        total: [],
      }),
    ).toBeNull();
  });
  it("words the staff page's credits with received_on", () => {
    const docs = parseOpenDocuments({
      ...DOCS,
      procedure: true,
      credits: [
        { id: "a", cause: "procedure", created_on: "2026-11-24", received_on: "2026-11-22", amount_minor: "5000", open_minor: "5000" },
        { id: "c", cause: "overpayment", created_on: "2026-11-24", received_on: "2026-11-20", amount_minor: "500", open_minor: "500" },
      ],
    })!;
    expect(docs.credits.map(creditLabel)).toEqual([
      "Somme reçue le 22/11/2026, mise de côté pour la procédure collective du client (avis de l'avocat, OQ-98)",
      "Trop-perçu du 20/11/2026",
    ]);
    expect(
      parseOpenDocuments({
        ...DOCS,
        credits: [{ id: "c", cause: "overpayment", created_on: "2026-11-24", amount_minor: "500", open_minor: "500" }],
      }),
    ).toBeNull();
  });
});

describe("(review round 1, TUI-4) a credit held for the procedure on staff pages: its payee is the procedure", () => {
  const docs = parseOpenDocuments({
    ...DOCS,
    procedure: true,
    credits: [
      ...DOCS.credits,
      { id: "77777777-7777-7777-7777-777777777777", cause: "procedure", created_on: "2026-11-24", received_on: "2026-11-24", amount_minor: "5000", open_minor: "5000" },
    ],
  })!;
  it("groups what is owed to the client apart from what is held for its procedure", () => {
    const g = staffCreditGroups(docs);
    expect(g.client.map((c) => c.cause)).toEqual(["overpayment"]);
    expect(g.procedure.map((c) => c.cause)).toEqual(["procedure"]);
    expect(g.clientTitle).toBe("Ce que le cabinet doit rembourser au client");
    expect(g.procedureTitle).toBe("Sommes mises de côté pour la procédure collective du client");
  });
  it("words each row's amount and the refund sheet's header by its payee", () => {
    expect(creditOwedText(docs.credits[0], "EUR")).toBe("5,00 € à rembourser");
    expect(creditOwedText(docs.credits[1], "EUR")).toBe("50,00 € à rendre à la procédure");
    expect(creditLabel(docs.credits[1])).toBe(
      "Somme reçue le 24/11/2026, mise de côté pour la procédure collective du client (avis de l'avocat, OQ-98)",
    );
    expect(refundHeader({ title: "Trop-perçu du 18/11/2026", owed_minor: "500", currency: "EUR", cause: "overpayment" })).toBe(
      "Trop-perçu du 18/11/2026 · 5,00 € à rembourser au client, par virement depuis le compte propre du cabinet",
    );
    expect(refundHeader({ title: "Avoir FC-2026-000006", owed_minor: "1200", currency: "EUR", cause: null })).toBe(
      "Avoir FC-2026-000006 · 12,00 € à rembourser au client, par virement depuis le compte propre du cabinet",
    );
    const held = refundHeader({ title: "Somme reçue le 24/11/2026", owed_minor: "5000", currency: "EUR", cause: "procedure" });
    expect(held).toBe(
      "Somme reçue le 24/11/2026 · 50,00 € à rendre à la procédure (administrateur, mandataire ou liquidateur nommé dans la preuve), par virement depuis le compte propre du cabinet",
    );
    expect(held).not.toContain("au client");
  });
});

describe("(review round 1, TUI-3) the dedicated line's label sentence and where its money goes, from SQL's plan", () => {
  const lilas = { ...INVOICE, id: "88888888-8888-8888-8888-888888888888", number: "FC-2026-000003", before_opening: true, payable: false };
  const docs = parseOpenDocuments({ ...DOCS, procedure: true, invoices: [INVOICE, lilas] })!;
  const preview = (rows: unknown[]): PaymentPreview =>
    parsePaymentPreview({ amount_minor: "3600", open_minor: "3600", credit_minor: "0", refusal: null, rows })!;
  it("a named pre-opening invoice is never said to be imputed", () => {
    const p = preview([
      { ord: 1, document_kind: "client_credit", document_id: lilas.id, number: lilas.number, amount_minor: "3600", vat_moved_minor: "0", cause: "procedure" },
    ]);
    const s = designationSentence([lilas.id], p, docs);
    expect(s).toBe(
      "Le libellé désigne FC-2026-000003 : créance antérieure à l'ouverture de la procédure du client, la somme n'est pas imputée.",
    );
    expect(s).not.toContain("lui est imputé");
    const e = dedicatedLineEffect(p, "EUR");
    expect(e).toBe(
      "La somme sera virée sur le compte propre du cabinet avec la prochaine quote-part ; 36,00 € y restent à rendre à la procédure collective du client.",
    );
    expect(e).not.toContain("revient au cabinet");
  });
  it("a named invoice settled is imputed; one the amount does not reach is said so", () => {
    const p = preview([
      { ord: 1, document_kind: "invoice", document_id: INVOICE.id, number: INVOICE.number, amount_minor: "3600", vat_moved_minor: "600", cause: null },
    ]);
    expect(designationSentence([INVOICE.id], p, docs)).toBe("Le libellé désigne FC-2026-000004 : le règlement lui est imputé.");
    expect(designationSentence([INVOICE.id, lilas.id], p, docs)).toBe(
      "Le libellé désigne FC-2026-000004 : le règlement lui est imputé ; FC-2026-000003 : rien ne lui est imputé.",
    );
    expect(designationSentence([], p, docs)).toBeNull();
    expect(dedicatedLineEffect(p, "EUR")).toBe(DEDICATED_LINE_EFFECT);
    expect(dedicatedLineEffect(null, "EUR")).toBe(DEDICATED_LINE_EFFECT);
  });
  it("a surplus owed back is never said to be the servicer's", () => {
    const p = preview([
      { ord: 1, document_kind: "invoice", document_id: INVOICE.id, number: INVOICE.number, amount_minor: "3600", vat_moved_minor: "600", cause: null },
      { ord: 2, document_kind: "client_credit", document_id: null, number: null, amount_minor: "500", vat_moved_minor: "0", cause: "overpayment" },
    ]);
    expect(dedicatedLineEffect(p, "EUR")).toBe(
      "La somme sera virée sur le compte propre du cabinet avec la prochaine quote-part ; 5,00 € y restent à rembourser au client.",
    );
  });
});

describe("(review round 1, TUI-2, CC-1) « Enregistrer le règlement » only on the preview of what is typed", () => {
  const p = parsePaymentPreview({
    amount_minor: "6000",
    open_minor: "74000",
    credit_minor: "0",
    refusal: null,
    rows: [{ ord: 1, document_kind: "invoice", document_id: INVOICE.id, number: INVOICE.number, amount_minor: "3600", vat_moved_minor: "600", cause: null }],
  })!;
  const inputs = { amount: "60,00", valueDate: "2026-11-24", designated: false, named: [] as string[], recover: [] as string[] };
  it("a preview counts only for the inputs it was computed for", () => {
    const stamp = { inputs: previewInputs(inputs), preview: p };
    expect(currentPreview(stamp, previewInputs(inputs))).toBe(p);
    // the amount typed on (« 600,00 »), another value date, a designation: none of these is the preview's
    expect(currentPreview(stamp, previewInputs({ ...inputs, amount: "600,00" }))).toBeNull();
    expect(currentPreview(stamp, previewInputs({ ...inputs, valueDate: "2026-11-23" }))).toBeNull();
    expect(currentPreview(stamp, previewInputs({ ...inputs, designated: true, named: [INVOICE.id] }))).toBeNull();
    expect(currentPreview(stamp, previewInputs({ ...inputs, designated: true, recover: ["x"] }))).toBeNull();
    expect(currentPreview(null, previewInputs(inputs))).toBeNull();
    // a designation's order is part of it
    const two = { ...inputs, designated: true, named: ["a", "b"] };
    expect(currentPreview({ inputs: previewInputs(two), preview: p }, previewInputs({ ...two, named: ["b", "a"] }))).toBeNull();
    // without a designation, the documents ticked before do not count (the command sends none)
    expect(previewInputs({ ...inputs, named: ["a"] })).toBe(previewInputs(inputs));
  });
  it("the note after recording states what the command posted, never the preview", () => {
    const r = parsePaymentResult({
      entry_id: "99999999-9999-9999-9999-999999999999",
      settled: [
        { document_kind: "invoice", document_id: INVOICE.id, number: INVOICE.number, amount_minor: "3600", vat_moved_minor: "600" },
        { document_kind: "advance", document_id: ADVANCE.id, number: null, amount_minor: "20000", vat_moved_minor: "0" },
      ],
      credit_minor: "500",
      credits: [{ cause: "overpayment", amount_minor: "500" }],
    })!;
    expect(resultEffect(r, parseOpenDocuments(DOCS)!)).toBe(
      "FC-2026-000004 : 36,00 € réglés (dont TVA 6,00 € devenue exigible) ; avance du 12/11/2026 : 200,00 € remboursés ; " +
        "trop-perçu de 5,00 € à rembourser au client",
    );
    const held = parsePaymentResult({ entry_id: "e", settled: [], credit_minor: "5000", credits: [{ cause: "procedure", amount_minor: "5000" }] })!;
    expect(resultEffect(held, parseOpenDocuments(DOCS)!)).toBe(
      "50,00 € inscrits comme à rendre à la procédure collective du client (avis de l'avocat, OQ-98)",
    );
    expect(parsePaymentResult({ entry_id: "e", settled: [], credit_minor: 5 })).toBeNull();
    expect(parsePaymentResult({ entry_id: "e", settled: [], credit_minor: "0", credits: [{ cause: "gift", amount_minor: "1" }] })).toBeNull();
  });
});

// a source guard (the project has no component renderer): the sheets use the helpers pinned above
describe("(review round 1, TUI-2, CC-1, TUI-3) the sheets record on the current preview and state what was posted", () => {
  const src = (p: string) => readFileSync(join(__dirname, "../..", p), "utf8");
  it("« Enregistrer un règlement »: the preview of the current inputs only, the note from the command's result", () => {
    const sheet = src("components/settlements/client-payment-sheet.tsx");
    expect(sheet).toContain("const preview = currentPreview(stamped, inputs);");
    expect(sheet).not.toMatch(/useState<PaymentPreview \| null>/);
    expect(sheet).toMatch(/if \(n !== asked\.current\) return;/);
    expect(sheet).toContain("resultEffect(result, docs)");
    expect(sheet).not.toMatch(/setDone\([^)]*paymentEffect/);
  });
  it("the dedicated line: its sentences from SQL's plan, the note from the command's result", () => {
    const line = src("app/backoffice/encaissements/debits/client-payment-line.tsx");
    // (M2c-7c-2 review round 1, MONEY-2) with the repayment requests the label names, from SQL too
    expect(line).toContain("designationSentence(facts.named_documents, preview, docs, facts.named_requests ?? [])");
    expect(line).toContain("dedicatedLineEffect(preview, facts.currency)");
    expect(line).not.toContain("{DEDICATED_LINE_EFFECT}");
    expect(line).toContain("resultEffect(result, docs)");
    expect(line).not.toMatch(/setDone\([^)]*paymentEffect/);
  });
  it("the client space and the client's page title each credit by what it holds", () => {
    expect(src("app/client/reversements/page.tsx")).toContain("clientSpaceCreditSections(creditRows)");
    expect(src("app/client/reversements/page.tsx")).not.toContain('title="Sommes que le cabinet vous doit"');
    const owes = src("app/backoffice/clients/[id]/reversement/client-owes.tsx");
    expect(owes).toContain("staffCreditGroups(docs)");
    expect(owes).toMatch(/<ClientRefundSheet[^>]*cause=\{c\.cause\}/);
  });
});

describe("(review round 4) a refund or a payment is never dated before what it settles existed", () => {
  const src = (p: string) => readFileSync(join(__dirname, "../..", p), "utf8");
  const credit = { owed_minor: "500", currency: "EUR", kind: "client_credit" as const, cause: "overpayment" as const };
  it("words the refund's earliest day SQL names: a credit's receipt, a credit note's issue", () => {
    expect(clientRefundRefusal("client refund refused: bad_date", credit, "2026-11-20")).toBe(
      "Le virement ne peut pas être daté avant le 20/11/2026, jour où la somme a été reçue.",
    );
    expect(clientRefundRefusal("client refund refused: bad_date", { ...credit, cause: "procedure" }, "2026-11-20")).toBe(
      "Le virement ne peut pas être daté avant le 20/11/2026, jour où la somme a été reçue.",
    );
    expect(clientRefundRefusal("client refund refused: bad_date", { owed_minor: "12000", currency: "EUR", kind: "credit_note" }, "2026-11-24")).toBe(
      "Le virement ne peut pas être daté avant le 24/11/2026, jour où l'avoir a été émis.",
    );
    // with no day named, the date is in the future (the only other bad_date)
    expect(clientRefundRefusal("client refund refused: bad_date", credit)).toBe("La date ne peut pas être dans le futur.");
    expect(clientRefundRefusal("client refund refused: bad_date", credit, "")).toBe("La date ne peut pas être dans le futur.");
  });
  it("words the payment's: a document or a loss designated that came later, on the sheet and on the line", () => {
    expect(clientPaymentRefusal("client payment refused: bad_date", "2026-11-24")).toBe(
      "Un document ou une perte désignés n'existaient pas encore à cette date de valeur : désigné ainsi, le règlement ne peut pas être daté avant le 24/11/2026.",
    );
    expect(clientPaymentRefusal("client payment refused: bad_date", "2026-11-24", "line")).toBe(
      "Ce crédit a été reçu avant le 24/11/2026, jour où naît un document désigné : il ne peut pas le régler.",
    );
    expect(clientPaymentRefusal("client payment refused: bad_date", null)).toBe("La date ne peut pas être dans le futur.");
  });
  it("the refund sheet's date cannot go before that day: a credit's receipt, a credit note's issue", () => {
    const sheet = src("components/settlements/client-refund-sheet.tsx");
    expect(sheet).toMatch(/earliest: string;/);
    expect(sheet).toMatch(/<input type="date" name="paid_on"[^>]*min=\{earliest\}[^>]*max=\{today\}/);
    const owes = src("app/backoffice/clients/[id]/reversement/client-owes.tsx");
    expect(owes).toMatch(/<ClientRefundSheet[^>]*kind="client_credit"[^>]*earliest=\{c\.received_on\}/);
    expect(owes).toMatch(/<ClientRefundSheet[^>]*kind="credit_note"[^>]*earliest=\{f\.issue_date\}/);
    expect(src("app/backoffice/reversements/factures/[id]/page.tsx")).toMatch(
      /<ClientRefundSheet[^>]*kind="credit_note"[^>]*earliest=\{d\.issue_date\}/,
    );
  });
});

describe("(review round 1, TUI-8) every open question a page cites is in COMPLIANCE.md", () => {
  it("never sends ops to an open question that does not exist", () => {
    const compliance = readFileSync(join(__dirname, "../../../../../docs/COMPLIANCE.md"), "utf8");
    const files: string[] = [];
    const walk = (dir: string) => {
      for (const f of readdirSync(dir)) {
        const path = join(dir, f);
        if (statSync(path).isDirectory()) walk(path);
        else if (/\.(ts|tsx)$/.test(f) && !/\.test\.ts$/.test(f)) files.push(path);
      }
    };
    walk(join(__dirname, "../.."));
    const cited = new Set(files.flatMap((f) => readFileSync(f, "utf8").match(/OQ-\d+/g) ?? []));
    expect(cited.size).toBeGreaterThan(10);
    expect([...cited].filter((q) => !compliance.includes(`| ${q} |`))).toEqual([]);
  });
});

