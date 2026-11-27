import { describe, expect, it } from "vitest";
import {
  DECISION_LABEL,
  LABEL_REFERENCE_DEBTOR_NOTE,
  RELAY_LABEL,
  debitReviewText,
  decidedLineKind,
  decisionLabel,
  heldReleaseEffect,
  labelReferenceExits,
  releaseEffect,
} from "./debits";
import { lineState, money } from "./statements";

/**
 * ADR-0014 « M2c-7e-3 review fixes » round 1: what « Débits et retours » and the statement's page say of a credit held
 * because its CSV label cites one of our transfers, once it has left « À classer » by one of its exits, and what
 * « Libérer » says of such a held copy by the transfer its label cites.
 */
const cited = {
  rmt: {
    transfer_id: "t1",
    kind: "payout",
    status: "returned",
    amount_minor: "100000",
    currency: "EUR",
    run_number: "RV-2026-000136",
  },
  top: { transfer_id: "t2", kind: "top_up", status: "booked", amount_minor: "4700", currency: "EUR" },
};
// a « Traités » row as public.debit_queue('traites') returns an exited line: its kind, the decision, no review
const decided = (decision: string, o: Partial<Record<string, unknown>> = {}) => ({
  direction: "credit",
  kind: "label_reference",
  amount_minor: "100000",
  counterparty_iban_end: "0185",
  end_to_end_id: null,
  original_end_to_end_id: null,
  payment_info_id: null,
  review_reason: null,
  candidates: [],
  decision,
  reference_from_label: "RMTBEA1BF27F3B0",
  label_transfer: cited.rmt,
  ...o,
});

describe("« Traités » after an exit (review round 1, TUI-1)", () => {
  it("never says that the line waits, nor that the credit is not the top-up it was booked as", () => {
    const rows = [
      decided("payout_returned"),
      decided("client_payment"),
      decided("relayed_payment"),
      decided("top_up", {
        amount_minor: "4700",
        counterparty_iban_end: null,
        reference_from_label: "TOP60CFADAE7025",
        label_transfer: cited.top,
      }),
    ];
    for (const r of rows) {
      const text = debitReviewText(r);
      expect(text, r.decision).toBeNull();
    }
  });

  it("still words the line while it is undecided (« À classer »)", () => {
    const text = debitReviewText(decided("payout_returned", { decision: null, label_transfer: { ...cited.rmt, status: "booked" } }));
    expect(text).toContain("Rien n'est comptabilisé tant que la ligne n'est pas classée");
  });
});

describe("« Traités »'s badge after an exit (review round 1, TUI-2)", () => {
  it("names a client's payment in French", () => {
    expect(DECISION_LABEL.client_payment).toBe("Règlement du client (facture ou avance du cabinet)");
    expect(decisionLabel("client_payment", "label_reference")).toBe(
      "Règlement du client (facture ou avance du cabinet)",
    );
    expect(decisionLabel("client_payment", "client_transfer_in")).toBe(
      "Règlement du client (facture ou avance du cabinet)",
    );
  });

  it("reads a released duplicate by the kind it was released as, never « relayé par le cabinet » for a debtor's own", () => {
    expect(decidedLineKind({ kind: "suspected_duplicate", held_kind: "label_reference" })).toBe("label_reference");
    expect(decidedLineKind({ kind: "suspected_duplicate", held_kind: null })).toBe("suspected_duplicate");
    expect(decidedLineKind({ kind: "label_reference", held_kind: null })).toBe("label_reference");
    expect(decisionLabel("relayed_payment", decidedLineKind({ kind: "suspected_duplicate", held_kind: "label_reference" }))).toBe(
      LABEL_REFERENCE_DEBTOR_NOTE,
    );
    expect(
      decisionLabel("relayed_payment", decidedLineKind({ kind: "suspected_duplicate", held_kind: "client_transfer_in" })),
    ).toBe(RELAY_LABEL.client);
    expect(
      decisionLabel("relayed_payment", decidedLineKind({ kind: "suspected_duplicate", held_kind: "own_transfer_in" })),
    ).toBe(RELAY_LABEL.servicer);
  });
});

describe("« Libérer » on a held copy citing our reference (review round 1, MB-1)", () => {
  // review round 2 (liberer-top-up-exit-not-open, R3): the cited transfer's status too — the fourth exit is named only
  // for a top-up still awaited (ordered here), as labelReferenceExits offers it; the round-2 block pins the others
  const effect = (kind: string | null, status: string | null = null) =>
    releaseEffect({
      direction: "credit",
      heldKind: "label_reference",
      amount: "47,00 €",
      labelTransferKind: kind,
      labelTransferStatus: status,
    });

  it("never offers a top-up's return, and names « C'est cet approvisionnement »", () => {
    expect(effect("top_up", "ordered")).toBe(
      "La ligne sera listée dans « À classer » : son libellé cite notre approvisionnement. Aucun paiement n'est créé ; classez-la ensuite (règlement du client ou paiement d'un débiteur, ou, sans compte émetteur et du même montant, « C'est cet approvisionnement »).",
    );
    for (const status of ["ordered", "in_file", "booked", "cancelled", null])
      expect(effect("top_up", status), String(status)).not.toContain("retour");
    // the exits the page then offers on such a line: never a return
    expect(
      labelReferenceExits({
        direction: "credit",
        kind: "label_reference",
        amount_minor: "4700",
        counterparty_iban_end: null,
        label_transfer: { transfer_id: "t2", kind: "top_up", status: "ordered", amount_minor: "4700" },
      }),
    ).not.toContain("return");
  });

  it("keeps the return of a payout or a sweep, and with no transfer read says what holds of every kind", () => {
    for (const kind of ["payout", "sweep"])
      expect(effect(kind), kind).toBe(
        "La ligne sera listée dans « À classer » : son libellé cite l'un de nos virements. Aucun paiement n'est créé ; classez-la ensuite (retour de ce virement, règlement du client ou paiement d'un débiteur).",
      );
    expect(effect(null)).toBe(
      "La ligne sera listée dans « À classer » : son libellé cite l'un de nos virements. Aucun paiement n'est créé ; classez-la ensuite (retour de ce virement s'il s'agit d'un reversement ou d'une quote-part, règlement du client ou paiement d'un débiteur, ou, pour un approvisionnement sans compte émetteur et du même montant, « C'est cet approvisionnement »).",
    );
  });
});

describe("the statement's page after an exit (review round 1, TUI-3)", () => {
  const state = (bookings: string[] | null, has_payment = false) =>
    lineState({ kind: "label_reference", direction: "credit", has_payment, bookings }).state;

  it("says the line is booked, and as what", () => {
    expect(state(["payout_returned"])).toBe("Comptabilisé · retour de notre reversement");
    expect(state(["sweep_returned"])).toBe("Comptabilisé · retour de la quote-part du cabinet");
    expect(state(["unplanned_payout_returned"])).toBe("Comptabilisé · retour d'un virement hors reversement");
    expect(state(["client_payment"])).toBe("Comptabilisé · règlement du client");
    expect(state(["top_up"])).toBe("Comptabilisé · approvisionnement par le compte propre");
    expect(state([], true)).toBe("Comptabilisé · à affecter");
    expect(lineState({ kind: "label_reference", direction: "credit", has_payment: false, bookings: ["client_payment"] }).tone).toBe("ok");
  });

  it("still says « à classer » with no booking, and words every booking kind of a line", () => {
    expect(state([])).toBe("Non comptabilisé · à classer");
    expect(state(null)).toBe("Non comptabilisé · à classer");
    expect(lineState({ kind: "transfer_out", direction: "debit", has_payment: false, bookings: ["payout", "fee"] }).state).toBe(
      "Comptabilisé · débit d'un reversement + frais bancaires",
    );
    for (const kind of [
      "payout",
      "sweep",
      "top_up",
      "payout_returned",
      "sweep_returned",
      "unplanned_payout",
      "unplanned_sweep",
      "unplanned_payout_returned",
      "unplanned_sweep_returned",
      "fee",
      "loss",
      "client_payment",
    ])
      expect(lineState({ kind: "other_debit", direction: "debit", has_payment: false, bookings: [kind] }).state, kind).not.toContain(
        "_",
      );
  });
});

/**
 * ADR-0014 « M2c-7e-3 review fixes » round 2 (liberer-top-up-exit-not-open): « Libérer » on a held copy citing our
 * top-up names « C'est cet approvisionnement » only when that exit exists after the release — the top-up still awaited
 * (ordered, or in a file), as labelReferenceExits and book_top_up_credit (top_up_not_open) require; a booked or a
 * cancelled top-up's copy is worded as « À classer » words it (labelReferenceText). The text is computed from the
 * « Doublons » row as public.debit_queue('doublons') returns it (heldReleaseEffect, the page's own mapping).
 */
describe("« Libérer » on a held copy citing our top-up, by its status (review round 2)", () => {
  type HeldRow = {
    direction: string;
    kind: string;
    held_kind: string | null;
    amount_minor: string;
    currency: string;
    counterparty_iban_end: string | null;
    reference_from_label: string | null;
    label_transfer: {
      transfer_id: string;
      kind: string;
      status: string | null;
      amount_minor: string;
      currency: string;
      run_number?: string;
    } | null;
  };
  // the second CSV copy of our no-IBAN top-up credit, held: its « Doublons » row
  const held = (status: string | null, o: Partial<HeldRow> = {}): HeldRow => ({
    direction: "credit",
    kind: "suspected_duplicate",
    held_kind: "label_reference",
    amount_minor: "4700",
    currency: "EUR",
    counterparty_iban_end: null,
    reference_from_label: "TOP60CFADAE7025",
    label_transfer: { transfer_id: "t2", kind: "top_up", status, amount_minor: "4700", currency: "EUR" },
    ...o,
  });
  // the same line once released: « À classer » reads it by the kind it was released as
  const released = (r: HeldRow) => ({ ...r, kind: "label_reference" });
  const FOURTH = "« C'est cet approvisionnement »";

  it("a booked top-up's copy: no fourth exit, and says the credit is not that top-up", () => {
    const r = held("booked");
    expect(heldReleaseEffect(r)).toBe(
      "La ligne sera listée dans « À classer » : son libellé cite notre approvisionnement, mais cet approvisionnement est déjà comptabilisé : sauf si la banque l'a exécuté deux fois, ce crédit n'est pas cet approvisionnement, sans doute un règlement du client ou le paiement d'un débiteur qui cite notre référence. Aucun paiement n'est créé ; classez-la ensuite (règlement du client ou paiement d'un débiteur).",
    );
    expect(heldReleaseEffect(r)).not.toContain(FOURTH);
    expect(labelReferenceExits(released(r))).toEqual(["client", "debtor"]);
  });

  it("a cancelled top-up's copy: no fourth exit, the cancelled sentence and the support", () => {
    const r = held("cancelled");
    expect(heldReleaseEffect(r)).toBe(
      "La ligne sera listée dans « À classer » : son libellé cite notre approvisionnement, mais cet approvisionnement a été annulé ; s'il a quand même été exécuté, c'est l'argent du cabinet. Ce peut aussi être un règlement du client ou le paiement d'un débiteur qui cite notre référence. Aucun paiement n'est créé ; classez-la ensuite (règlement du client ou paiement d'un débiteur). S'il s'agit de cet approvisionnement exécuté malgré son annulation, prévenez le support : Collectoo ne l'attend plus et ne le comptabilise pas sur cette ligne.",
    );
    expect(labelReferenceExits(released(r))).toEqual(["client", "debtor"]);
  });

  it("an awaited top-up's copy (ordered or in a file) names the fourth exit, which the released line then offers", () => {
    for (const status of ["ordered", "in_file"]) {
      const r = held(status);
      expect(heldReleaseEffect(r), status).toBe(
        "La ligne sera listée dans « À classer » : son libellé cite notre approvisionnement. Aucun paiement n'est créé ; classez-la ensuite (règlement du client ou paiement d'un débiteur, ou, sans compte émetteur et du même montant, « C'est cet approvisionnement »).",
      );
      expect(labelReferenceExits(released(r)), status).toEqual(["client", "debtor", "top_up"]);
    }
  });

  it("any other status, or none read: never the fourth exit, the plain support", () => {
    for (const status of ["returned", null]) {
      const r = held(status);
      expect(heldReleaseEffect(r), String(status)).toBe(
        "La ligne sera listée dans « À classer » : son libellé cite notre approvisionnement. Aucun paiement n'est créé ; classez-la ensuite (règlement du client ou paiement d'un débiteur). S'il s'agit de cet approvisionnement, prévenez le support : Collectoo ne le comptabilise pas sur cette ligne.",
      );
      expect(labelReferenceExits(released(r)), String(status)).toEqual(["client", "debtor"]);
    }
  });

  it("names the fourth exit exactly when the released line offers it (no sending account, its amount)", () => {
    for (const status of ["ordered", "in_file", "booked", "cancelled", "returned", null]) {
      const r = held(status);
      expect(heldReleaseEffect(r).includes(FOURTH), String(status)).toBe(
        labelReferenceExits(released(r)).includes("top_up"),
      );
      // never a top-up's return
      expect(heldReleaseEffect(r), String(status)).not.toContain("retour");
    }
  });

  it("words a payout's or a sweep's copy by its status: the return only once its debit is booked and not back", () => {
    const cites = (status: string | null, kind: string) =>
      held(status, {
        amount_minor: "100000",
        reference_from_label: "RMTBEA1BF27F3B0",
        label_transfer: {
          transfer_id: "t1",
          kind,
          status,
          amount_minor: "100000",
          currency: "EUR",
          run_number: "RV-2026-000136",
        },
      });
    const plain =
      "La ligne sera listée dans « À classer » : son libellé cite l'un de nos virements. Aucun paiement n'est créé ; classez-la ensuite (retour de ce virement, règlement du client ou paiement d'un débiteur).";
    const hedged =
      "La ligne sera listée dans « À classer » : son libellé cite l'un de nos virements. Aucun paiement n'est créé ; classez-la ensuite (retour de ce virement si son débit est comptabilisé et n'est pas déjà revenu, règlement du client ou paiement d'un débiteur).";
    for (const kind of ["payout", "sweep"]) {
      expect(heldReleaseEffect(cites("booked", kind)), kind).toBe(plain);
      expect(heldReleaseEffect(cites(null, kind)), kind).toBe(plain);
      // probe h1: book_transfer_line refuses already_returned or return_before_debit there (transfer_cancelled too),
      // unless a second (unplanned) debit of it is open — the sheet then offers that debit's return
      for (const status of ["returned", "ordered", "in_file", "cancelled"])
        expect(heldReleaseEffect(cites(status, kind)), `${kind} ${status}`).toBe(hedged);
      // the page still offers the sheet, which reads the options (the refusal, or a second debit's return)
      expect(labelReferenceExits(released(cites("returned", kind))), kind).toContain("return");
    }
  });

  it("keeps every other held reading's text (the page's mapping)", () => {
    const row = (o: { direction: string; kind: string; held_kind: string | null }) => ({
      ...o,
      amount_minor: "4700",
      currency: "EUR",
    });
    expect(heldReleaseEffect(row({ direction: "credit", kind: "suspected_duplicate", held_kind: "debtor_credit" }))).toBe(
      releaseEffect({ direction: "credit", heldKind: "debtor_credit", amount: money("4700", "EUR") }),
    );
    // the « Doublons » tab returning the reading in place of suspected_duplicate
    expect(heldReleaseEffect(row({ direction: "debit", kind: "other_debit", held_kind: null }))).toBe(
      releaseEffect({ direction: "debit", heldKind: "other_debit", amount: money("4700", "EUR") }),
    );
    // not told the reading: both outcomes
    expect(heldReleaseEffect(row({ direction: "credit", kind: "suspected_duplicate", held_kind: null }))).toBe(
      releaseEffect({ direction: "credit", heldKind: null, amount: money("4700", "EUR") }),
    );
  });
});

describe("assembly: the round verifiers' two lows", () => {
  it("(TUI-1 regression) a copy released from « Doublons possibles » still waits in « À classer », worded as such", () => {
    const text = debitReviewText(decided("released", { kind: "label_reference", label_transfer: { ...cited.rmt, status: "booked" } }));
    expect(text).not.toBeNull();
    expect(text).toContain("Rien n'est comptabilisé tant que la ligne n'est pas classée");
    expect(debitReviewText(decided("payout_returned"))).toBeNull();
  });
  it("(liberer-payout-copy-amount-not-hedged) « Libérer » offers no return for a copy whose amount is not the transfer's", () => {
    const row = {
      direction: "credit",
      kind: "suspected_duplicate",
      held_kind: "label_reference",
      amount_minor: "20000",
      currency: "EUR",
      label_transfer: { kind: "payout", status: "booked", amount_minor: "100000" },
    };
    const other = heldReleaseEffect(row);
    expect(other).toContain("elle ne pourra pas être comptabilisée comme son retour");
    expect(other).not.toContain("retour de ce virement");
    expect(other).toContain("règlement du client ou paiement d'un débiteur");
    const same = heldReleaseEffect({ ...row, amount_minor: "100000" });
    expect(same).toContain("retour de ce virement");
    expect(heldReleaseEffect({ ...row, label_transfer: { kind: "sweep", status: "booked", amount_minor: "100000" } })).not.toContain(
      "retour de ce virement",
    );
  });
});
