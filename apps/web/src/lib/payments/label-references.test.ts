import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import {
  CHECK_LABEL,
  DEBIT_REVIEW,
  checkSubjectLink,
  clientRelayable,
  debitErrorCode,
  debitReviewText,
  explainable,
  holdsLabelReference,
  LABEL_REFERENCE_TOP_UP_SUPPORT,
  LABEL_REFERENCE_WAITING_NOTE,
  LABEL_REFERENCE_WAITING_TAIL,
  LABEL_REFERENCE_WAITING_TOP_UP_TAIL,
  checkLabel,
  guardRefusalCode,
  linkDebitErrorCode,
  labelReferenceText,
  lineKindLabel,
  linkGuarded,
  offersPaymentLinks,
  offersTopUp,
  readsLinkOptions,
  relayable,
  releaseEffect,
} from "./debits";
import { LINE_FILTERS, lineInFilter, lineState } from "./statements";

/**
 * M2c-7e-2 (plan docs/design/m2c-7-plan.md §7.3, §7.4; ADR-0014 « M2c-7e-2 »): a credit whose CSV label cites one of
 * our transfers is held (`label_reference`): « À classer » says what the label cites and that the line waits — no
 * action in 7e-2 (7e-3 brings the three exits) —, every link is refused (`label_reference_line`), and the nightly
 * alerts it after two business days (`label_reference_waiting`).
 */
const row = (o: Partial<Record<string, unknown>> = {}) => ({
  bank_transaction_id: "l1",
  direction: "credit",
  kind: "label_reference",
  amount_minor: "100000",
  currency: "EUR",
  end_to_end_id: null,
  original_end_to_end_id: null,
  payment_info_id: null,
  names_our_lot: false,
  unsplit_ours: null,
  review_reason: "label_reference",
  candidates: [],
  bookable_as: null,
  reference_from_label: "RMT0123456789AB",
  label_transfer: {
    kind: "payout",
    status: "booked",
    amount_minor: "100000",
    currency: "EUR",
    end_to_end_id: "RMT0123456789AB",
    run_number: "RV-2026-000012",
    run_status: "booked",
  },
  ...o,
});
const n = (text: string) => text.replace(/ | /g, " ");

describe("a credit citing our reference in its CSV label (label_reference)", () => {
  it("names the line and the job's review in French", () => {
    expect(lineKindLabel("label_reference", "credit")).toBe("Crédit citant notre référence");
    expect(DEBIT_REVIEW.label_reference).toBe(
      "Le libellé cite l'un de nos virements : est-ce ce virement qui revient ? La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée.",
    );
  });
  it("says what the label cites: the transfer, its run and its amount (plan §7.4)", () => {
    expect(n(labelReferenceText(row()))).toBe(
      "Le libellé cite notre virement RMT0123456789AB (reversement RV-2026-000012, 1 000,00 €) : est-ce ce virement qui revient ? La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée.",
    );
    expect(
      n(
        labelReferenceText(
          row({
            reference_from_label: "SWP0123456789AC",
            label_transfer: { kind: "sweep", status: "ordered", amount_minor: "5000", currency: "EUR", run_number: null },
          }),
        ),
      ),
    ).toBe(
      "Le libellé cite notre virement SWP0123456789AC (quote-part du cabinet, 50,00 €) : est-ce ce virement qui revient ? La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée.",
    );
    expect(
      n(
        labelReferenceText(
          row({
            reference_from_label: "TOP0123456789AD",
            counterparty_iban_end: "0143",
            label_transfer: { kind: "top_up", status: "ordered", amount_minor: "4700", currency: "EUR", run_number: null },
          }),
        ),
      ),
    ).toBe(
      // a top-up arrives from the own account (own_transfer_in): cited from another IBAN it is not its credit
      "Le libellé cite notre approvisionnement TOP0123456789AD (47,00 €), mais le crédit ne vient pas du compte propre : sans doute un règlement du client ou le paiement d'un débiteur qui cite notre référence. La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée.",
    );
    // review round 1 (MB-3, TUI-1): with no counterparty IBAN on the line (a CSV export without the column) the page
    // never says the credit is not the own account's — of the top-up's amount, it may be that top-up (its motif
    // « APPROVISIONNEMENT COMPTE DEDIE TOP… » printed in the label), and support is to be told; of another amount, not it
    const top = (amount: string) =>
      row({
        amount_minor: amount,
        counterparty_iban_end: null,
        reference_from_label: "TOP0123456789AD",
        label_transfer: { kind: "top_up", status: "ordered", amount_minor: "4700", currency: "EUR", run_number: null },
      });
    expect(n(labelReferenceText(top("4700")))).toBe(
      "Le libellé cite notre approvisionnement TOP0123456789AD (47,00 €), du même montant, et le relevé ne donne pas le compte qui l'a envoyé : ce peut être cet approvisionnement, venu du compte propre, ou bien un règlement du client ou le paiement d'un débiteur qui cite notre référence. La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée. S'il s'agit de cet approvisionnement, prévenez le support : Collectoo l'attend encore et ne le comptabilise pas sur cette ligne.",
    );
    expect(labelReferenceText(top("4700"))).not.toContain("ne vient pas du compte propre");
    expect(labelReferenceText(top("4700"))).toContain(LABEL_REFERENCE_TOP_UP_SUPPORT);
    expect(n(labelReferenceText(top("5000")))).toBe(
      "Le libellé cite notre approvisionnement TOP0123456789AD (47,00 €), et le relevé ne donne pas le compte qui l'a envoyé ; son montant n'est pas celui de cet approvisionnement : sans doute un règlement du client ou le paiement d'un débiteur qui cite notre référence. La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée.",
    );
    expect(debitReviewText(top("4700"))).toBe(labelReferenceText(top("4700")));
    // review round 2 (top-text-ignores-status): the top-up's status words it — in a file, still awaited as ordered;
    // cancelled (public.cancel_top_up, whatever the switch), no longer awaited (top_up_needed counts only ordered and
    // in_file ones): if executed all the same it is the servicer's money; booked, already credited: not this credit
    const topIn = (status: string | null, amount = "4700", iban: string | null = null) =>
      row({
        amount_minor: amount,
        counterparty_iban_end: iban,
        reference_from_label: "TOP0123456789AD",
        label_transfer: { kind: "top_up", status, amount_minor: "4700", currency: "EUR", run_number: null },
      });
    expect(labelReferenceText(topIn("in_file"))).toBe(labelReferenceText(top("4700")));
    expect(n(labelReferenceText(topIn("cancelled")))).toBe(
      "Le libellé cite notre approvisionnement TOP0123456789AD (47,00 €), du même montant, et le relevé ne donne pas le compte qui l'a envoyé : cet approvisionnement a été annulé ; s'il a quand même été exécuté, c'est l'argent du cabinet. Ce peut aussi être un règlement du client ou le paiement d'un débiteur qui cite notre référence. La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée. S'il s'agit de cet approvisionnement exécuté malgré son annulation, prévenez le support : Collectoo ne l'attend plus et ne le comptabilise pas sur cette ligne.",
    );
    expect(n(labelReferenceText(topIn("booked")))).toBe(
      "Le libellé cite notre approvisionnement TOP0123456789AD (47,00 €), du même montant, mais cet approvisionnement est déjà comptabilisé : sauf si la banque l'a exécuté deux fois, ce crédit n'est pas cet approvisionnement, sans doute un règlement du client ou le paiement d'un débiteur qui cite notre référence. La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée.",
    );
    // another status, or none read: never « l'attend encore »
    for (const status of ["cancelled", "booked", "returned", null]) {
      expect(labelReferenceText(topIn(status))).not.toContain("l'attend encore");
      expect(debitReviewText(topIn(status))).toBe(labelReferenceText(topIn(status)));
    }
    expect(n(labelReferenceText(topIn(null)))).toBe(
      "Le libellé cite notre approvisionnement TOP0123456789AD (47,00 €), du même montant, et le relevé ne donne pas le compte qui l'a envoyé : ce peut être cet approvisionnement, venu du compte propre, ou bien un règlement du client ou le paiement d'un débiteur qui cite notre référence. La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée. S'il s'agit de cet approvisionnement, prévenez le support : Collectoo ne le comptabilise pas sur cette ligne.",
    );
    expect(labelReferenceText(topIn("returned"))).toBe(labelReferenceText(topIn(null)));
    // with an IBAN, or of another amount, the text is true whatever the status (never « l'attend encore »)
    for (const status of ["ordered", "in_file", "cancelled", "booked"]) {
      expect(labelReferenceText(topIn(status, "4700", "0143"))).toBe(labelReferenceText(topIn("ordered", "4700", "0143")));
      expect(labelReferenceText(topIn(status, "5000"))).toBe(labelReferenceText(top("5000")));
    }
    // a payout or a sweep is worded alike with or without an IBAN (« est-ce ce virement qui revient ? »)
    expect(labelReferenceText(row({ counterparty_iban_end: null }))).toBe(labelReferenceText(row({ counterparty_iban_end: "0143" })));
    // a payout of no run (a transfer of ours out of any run) is still named, its amount too
    expect(n(labelReferenceText(row({ label_transfer: { kind: "payout", amount_minor: "2500", currency: "EUR" } })))).toBe(
      "Le libellé cite notre virement RMT0123456789AB (reversement, 25,00 €) : est-ce ce virement qui revient ? La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée.",
    );
    // the database's word is the queue's: no candidate read, the job's review alone
    expect(labelReferenceText(row({ reference_from_label: null, label_transfer: null }))).toBe(DEBIT_REVIEW.label_reference);
    expect(debitReviewText(row())).toBe(labelReferenceText(row()));
    // read so before the job's pass (no review yet), or released from « Doublons possibles »: the same text
    expect(debitReviewText(row({ review_reason: null }))).toBe(labelReferenceText(row()));
  });
  it("offers no action in 7e-2: no link, no relay, no top-up, no booking, no explanation", () => {
    expect(holdsLabelReference(row())).toBe(true);
    expect(holdsLabelReference(row({ kind: "debtor_credit" }))).toBe(false);
    expect(offersPaymentLinks(row())).toBe(false);
    expect(readsLinkOptions(row())).toBe(false);
    expect(offersTopUp(row())).toBe(false);
    expect(relayable({ ...row(), end_to_end_id: null })).toBe(false);
    expect(clientRelayable(row())).toBe(false);
    expect(linkGuarded(row())).toBe(true);
    expect(
      explainable({ direction: "credit", kind: "label_reference", namesPayment: false, endToEndId: null }),
    ).toBe(false);
    // a debtor's credit keeps its explanation (unchanged)
    expect(explainable({ direction: "credit", kind: "debtor_credit", namesPayment: false, endToEndId: null })).toBe(true);
    expect(LABEL_REFERENCE_WAITING_NOTE).toBe(
      "La ligne reste en attente : ni paiement ni retour tant qu'elle n'est pas classée.",
    );
  });
  it("words link_debit's refusal (label_reference_line), true of 7e-2", () => {
    expect(debitErrorCode("debit link refused: label_reference_line")).toBe("label_reference_line");
    expect(errorText("label_reference_line")).toBe(
      "Le libellé cite l'un de nos virements : cette ligne ne se lie à aucun paiement et ne se classe pas sans comptabiliser. Elle attend d'être classée (retour de ce virement, règlement du client ou paiement d'un débiteur), ce que cet écran ne permet pas encore : prévenez le support.",
    );
  });
  it("words the refusal from the candidate's kind: a return of an RMT or a SWP, never of a TOP (review round 3)", () => {
    // private.link_debit_guard gives the kind in its code (a candidate's prefix is its transfer's kind:
    // bank_transfer_prefix) — an RMT or a SWP may come back, a TOP has no return exit (plan §7.3): its classes are that
    // top-up (founder Q15), the client's payment or a debtor's
    for (const [kind, message, code] of [
      ["RMT", "debit link refused: label_reference_line", "label_reference_line"],
      ["SWP", "debit link refused: label_reference_line", "label_reference_line"],
      ["TOP", "debit link refused: label_reference_top_up_line", "label_reference_top_up_line"],
    ] as const) {
      expect(debitErrorCode(message), kind).toBe(code);
      // every link kind ops may send, « Comptabiliser comme approvisionnement » included, keeps the code
      for (const link of ["explained", "fee", "own_credit", "return", "loss", "refund", "refund_returned"])
        expect(guardRefusalCode(linkDebitErrorCode(message, link), true), `${kind} ${link}`).toBe(code);
    }
    expect(errorText("label_reference_top_up_line")).toBe(
      "Le libellé cite l'un de nos approvisionnements : cette ligne ne se lie à aucun paiement et ne se classe pas sans comptabiliser. Elle attend d'être classée — règlement du client ou paiement d'un débiteur (ou, sans compte émetteur et du même montant, cet approvisionnement : question Q15) —, ce que cet écran ne permet pas encore : prévenez le support.",
    );
    expect(errorText("label_reference_top_up_line")).not.toContain("retour");
    expect(errorText("label_reference_line")).not.toContain("approvisionnement");
  });
  it("says what « Libérer » does of a held line read so", () => {
    expect(releaseEffect({ direction: "credit", heldKind: "label_reference", amount: "1 000,00 €" })).toBe(
      "La ligne sera listée dans « À classer » : son libellé cite l'un de nos virements. Aucun paiement n'est créé ; elle attend d'être classée.",
    );
  });
  it("lists it on the statement's page with the other operations, to classify", () => {
    expect(lineState({ kind: "label_reference", direction: "credit", has_payment: false }).kind).toBe("Crédit citant notre référence");
    expect(lineState({ kind: "label_reference", direction: "credit", has_payment: false }).state).toBe("Non comptabilisé · à classer");
    expect(lineInFilter("autres", { kind: "label_reference", direction: "credit" })).toBe(true);
    expect(lineInFilter("encaissements", { kind: "label_reference", direction: "credit" })).toBe(false);
    expect(LINE_FILTERS.autres.groups?.some((g) => g.kinds.includes("label_reference"))).toBe(true);
  });
});

describe("the nightly's label_reference_waiting ([check 3])", () => {
  it("has its French label and help, and leads to the line on « Débits et retours »", () => {
    // review round 1 (TUI-6): true of 7e-2 — no screen classifies the line yet
    // review round 3 (top-cited-line-lists-a-return-exit): with no row read, true of every kind — a TOP has no return
    expect(CHECK_LABEL.label_reference_waiting).toEqual({
      label: "Libellé citant notre virement, à classer",
      help: "Une ligne du relevé cite notre référence RMT, SWP ou TOP dans son libellé. Rien n'est comptabilisé tant que la ligne n'est pas classée : retour de ce virement (RMT ou SWP), règlement du client ou paiement d'un débiteur (ou, pour un TOP sans compte émetteur et du même montant, cet approvisionnement : question Q15). Aucun écran ne permet encore de la classer : prévenez le support.",
    });
    expect(
      checkSubjectLink({ code: "label_reference_waiting", subject_type: "bank_transaction", subject_id: "l1" }),
    ).toBe("/backoffice/encaissements/debits#ligne-l1");
  });
});

describe("label_reference_waiting's classes from the candidate's kind (review round 3)", () => {
  it("lists a return for an RMT or a SWP, that top-up (Q15) for a TOP, with or without the row's kind", () => {
    expect(LABEL_REFERENCE_WAITING_TAIL).toBe(
      "Rien n'est comptabilisé tant que la ligne n'est pas classée (retour de ce virement, règlement du client ou paiement d'un débiteur). Aucun écran ne permet encore de la classer : prévenez le support.",
    );
    expect(LABEL_REFERENCE_WAITING_TOP_UP_TAIL).toBe(
      "Rien n'est comptabilisé tant que la ligne n'est pas classée : règlement du client ou paiement d'un débiteur (ou, sans compte émetteur et du même montant, cet approvisionnement : question Q15). Aucun écran ne permet encore de la classer : prévenez le support.",
    );
    const help = (details: Record<string, unknown>) => n(checkLabel("label_reference_waiting", { details }).help);
    // an RMT (not P0: its run not booked) and a SWP: the current text, a return among the classes
    for (const [ref, kind] of [
      ["RMT0123456789AB", "payout"],
      ["SWP0123456789AC", "sweep"],
    ] as const) {
      for (const d of [{ p0: false, candidate_kind: kind, reference_from_label: ref }, { reference_from_label: ref }]) {
        expect(help(d), `${kind} ${JSON.stringify(d)}`).toBe(
          `Une ligne du relevé cite notre référence ${ref} dans son libellé. ${LABEL_REFERENCE_WAITING_TAIL}`,
        );
        expect(help(d)).not.toContain("approvisionnement");
      }
    }
    // a TOP: no return, that top-up (founder Q15) — from the row's candidate_kind, or from the reference alone (its
    // prefix is its transfer's kind: bank_transfer_prefix)
    for (const d of [
      { p0: false, candidate_kind: "top_up", reference_from_label: "TOP0123456789AD" },
      { reference_from_label: "TOP0123456789AD" },
      { p0: false, candidate_kind: "top_up" },
    ]) {
      const text = help(d);
      expect(text, JSON.stringify(d)).toContain(LABEL_REFERENCE_WAITING_TOP_UP_TAIL);
      expect(text).not.toContain("retour");
    }
    expect(help({ p0: false, candidate_kind: "top_up" })).toBe(
      `Une ligne du relevé cite l'un de nos approvisionnements dans son libellé. ${LABEL_REFERENCE_WAITING_TOP_UP_TAIL}`,
    );
    // the P0 row (a booked run's payout) keeps its text, a return among its classes
    expect(help({ p0: true, candidate_kind: "payout", run_number: "RV-2026-000012", reference_from_label: "RMT0123456789AB" }))
      .toContain(LABEL_REFERENCE_WAITING_TAIL);
    // the static help (no row read) is true of every kind
    expect(CHECK_LABEL.label_reference_waiting.help).toContain("retour de ce virement (RMT ou SWP)");
    expect(CHECK_LABEL.label_reference_waiting.help).toContain("pour un TOP sans compte émetteur et du même montant, cet approvisionnement : question Q15");
  });
});

describe("label_reference_waiting from its row's details (review round 1, MB-4, TUI-6)", () => {
  it("is prioritaire when the label cites the payout of a booked run (details.p0), and names it", () => {
    const p0 = checkLabel("label_reference_waiting", {
      details: { p0: true, run_status: "booked", candidate_kind: "payout", run_number: "RV-2026-000012",
                 reference_from_label: "RMT0123456789AB" },
    });
    expect(p0.label).toBe("Libellé citant notre virement, à classer (prioritaire)");
    expect(n(p0.help)).toBe(
      "Prioritaire : une ligne du relevé cite dans son libellé RMT0123456789AB, le virement du reversement RV-2026-000012 (comptabilisé) : ce virement est peut-être revenu sur le compte dédié. Rien n'est comptabilisé tant que la ligne n'est pas classée (retour de ce virement, règlement du client ou paiement d'un débiteur). Aucun écran ne permet encore de la classer : prévenez le support.",
    );
    const other = checkLabel("label_reference_waiting", {
      details: { p0: false, candidate_kind: "top_up", reference_from_label: "TOP0123456789AD" },
    });
    expect(other).not.toEqual(p0);
    expect(other.label).toBe("Libellé citant notre virement, à classer");
    // review round 3 (top-cited-line-lists-a-return-exit): a TOP has no return exit (plan §7.3)
    expect(other.help).toBe(
      `Une ligne du relevé cite notre approvisionnement TOP0123456789AD dans son libellé. ${LABEL_REFERENCE_WAITING_TOP_UP_TAIL}`,
    );
    // no details read: the static help
    expect(checkLabel("label_reference_waiting")).toEqual(CHECK_LABEL.label_reference_waiting);
    expect(checkLabel("label_reference_waiting", { details: {} })).toEqual(CHECK_LABEL.label_reference_waiting);
    // whichever the switch: 7e-2's rule does not read it
    expect(checkLabel("label_reference_waiting", { cancellationAfterDownload: true, details: { p0: true } }).label).toBe(
      "Libellé citant notre virement, à classer (prioritaire)",
    );
  });
});
