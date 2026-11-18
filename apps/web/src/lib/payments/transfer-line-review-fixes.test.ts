// M2c-6b-2c review fixes (round 1; ADR-0014 « M2c-6b-2c review fixes »): what « Débits et retours », its sheets and
// the run page offer and say once the review's findings are closed — the links refused on the lines « Comptabiliser… »
// books (money-1, money-2, T5), the run's set-off worded part by part (pages-1), the draft's deduction (money-4), the
// IBANs as the page masks them (T1, pages-2), a lot's members by the line's direction (pages-3), the sweep's own label
// (pages-4), a pending debit held in « Doublons possibles » (pages-5), the unbooked lines' alert (legal-deadlines-3).
import { describe, expect, it } from "vitest";
import { runPayoutNotes, type RunPayout } from "../remittance/runs";
import { errorText } from "../boarding/forms";
import {
  checkLabel,
  DEBIT_REVIEW,
  debitReviewText,
  guardRefusalCode,
  linkGuarded,
  linkOffers,
  paymentLinksGuarded,
  QUEUE_UNREAD,
} from "./debits";
import { money } from "./statements";
import {
  memberInLine,
  parseTransferLineOptions,
  pendingLineNote,
  transferLineActionLabel,
  transferLineButton,
  transferLineEffects,
  type TransferLineOptions,
} from "./transfer-lines";

const EUR = "EUR";
const T = "00000000-0000-0000-0000-0000000000a9";

describe("the links « Comptabiliser… » replaces (money-1, money-2; T5)", () => {
  const row = (o: Record<string, unknown>) => ({
    direction: "debit",
    kind: "other_debit",
    amount_minor: "419840",
    end_to_end_id: null,
    original_end_to_end_id: null,
    payment_info_id: null,
    unsplit_ours: null,
    names_our_lot: false,
    review_reason: null as string | null,
    bookable_as: null as string | null,
    ...o,
  });
  const p02 = { payment_id: "p02", left_minor: "512000" };
  const p13 = { payment_id: "p13", left_minor: "1000000" };
  it("a debit a transfer of ours may be, to a client's payout IBAN or to our own account: guarded", () => {
    for (const reason of ["payout_amount_match", "client_payout_iban", "own_transfer_out"])
      expect(linkGuarded(row({ review_reason: reason, bookable_as: "n" })), reason).toBe(true);
    // the job's own review on such a line: guarded by what « Comptabiliser… » books (bookable_as)
    expect(linkGuarded(row({ review_reason: "no_candidate", bookable_as: "n" }))).toBe(true);
    expect(linkGuarded(row({ review_reason: null, bookable_as: null }))).toBe(false);
    expect(linkGuarded(row({ review_reason: "no_candidate", bookable_as: null }))).toBe(false);
  });
  it("a flagged return from a client's payout IBAN (bookable_as n): guarded; another credit not", () => {
    expect(linkGuarded(row({ direction: "credit", kind: "return", bookable_as: "n" }))).toBe(true);
    expect(linkGuarded(row({ direction: "credit", kind: "return", bookable_as: null }))).toBe(false);
    expect(linkGuarded(row({ direction: "credit", kind: "return", review_reason: "payout_amount_match" }))).toBe(false);
  });
  it("no « Retour du paiement … » nor loss on a guarded debit, whatever the payments listed", () => {
    for (const reason of ["payout_amount_match", "client_payout_iban", "own_transfer_out"]) {
      const offers = linkOffers(row({ review_reason: reason, bookable_as: "n" }), [p02, p13], []);
      expect(offers.returns, reason).toEqual([]);
      expect(offers.losses, reason).toEqual([]);
    }
    const ret = linkOffers(row({ kind: "return", bookable_as: "n" }), [{ ...p02, named: true, left_minor: "1" }], []);
    expect(ret).toEqual({ returns: [], losses: [], refunds: [] });
    // the same line without a transfer of ours to book: the payments of at least its amount
    expect(linkOffers(row({}), [p02, p13], []).returns.map((p) => p.payment_id)).toEqual(["p02", "p13"]);
  });
  it("a debit the bank flags as a return keeps « Retour du paiement … » and its loss (round 2)", () => {
    // « Comptabiliser… » never books it (bookable_as null, whatever a transfer of ours of its amount): the database lets
    // its return and loss through and debit_link_options lists the payments (037 p_return_kind)
    const flagged = row({ kind: "return", review_reason: "no_candidate", bookable_as: null });
    expect(linkGuarded(flagged)).toBe(false);
    const named = { ...p02, named: true, left_minor: "100000" };
    const offers = linkOffers(flagged, [p13, named], []);
    expect(offers.returns.map((p) => p.payment_id)).toEqual(["p13"]);
    expect(offers.losses.map((p) => p.payment_id)).toEqual(["p02"]);
  });
  it("« Remboursement revenu » on the guarded credit: exactly what debit_link_options lists (round 3)", () => {
    // the database lists only the refunds private.link_debit_guard lets through there: none but the refund sent to
    // that IBAN (037 p_guards' refund_back_credit, p_refund_client_iban's back_listed) — the page shows what it lists
    const credit = row({ direction: "credit", kind: "return", bookable_as: "n" });
    expect(linkOffers(credit, [], []).refunds).toEqual([]);
    expect(linkOffers(credit, [], [{ refund_request_id: "q1" }]).refunds).toEqual([{ refund_request_id: "q1" }]);
    expect(linkOffers({ ...credit, bookable_as: null }, [], [{ refund_request_id: "q1" }]).refunds).toEqual([
      { refund_request_id: "q1" },
    ]);
  });
});

describe("a debit of an ended payout's amount (round 3, other-debit-return-blocked-by-returned-payout-twin)", () => {
  const ended = (status: string, run_status = "booked") => ({ transfer_id: T, kind: "payout", status, run_status });
  const row = (o: Record<string, unknown>) => ({
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
  const p02 = { payment_id: "p02", left_minor: "512000" };
  const p13 = { payment_id: "p13", left_minor: "1000000" };
  it("« Retour du paiement … » when debit_link_options says the return passes (return_guard null)", () => {
    expect(paymentLinksGuarded(row({}), null)).toBe(false);
    expect(linkOffers(row({}), [p02, p13], [], null).returns.map((p) => p.payment_id)).toEqual(["p02", "p13"]);
    // still never classified without booking: « Comptabiliser… » books it if it is that payout
    expect(linkGuarded(row({}))).toBe(true);
  });
  it("none while the database refuses it, or before it was read", () => {
    for (const guard of ["payout_candidate", "client_payout_line", undefined]) {
      expect(paymentLinksGuarded(row({}), guard), String(guard)).toBe(true);
      expect(linkOffers(row({}), [p02, p13], [], guard).returns, String(guard)).toEqual([]);
    }
    // only « À classer »'s payout_amount_match rows: a debit to a client's payout IBAN stays guarded
    expect(linkOffers(row({ review_reason: "client_payout_iban", candidates: [] }), [p02], [], null).returns).toEqual([]);
  });
  it("the queue's reason never says « en cours » of a payout that is returned or cancelled", () => {
    for (const status of ["returned", "cancelled"]) {
      const text = debitReviewText(row({ candidates: [ended(status)] }), { return_guard: "client_payout_line" }) ?? "";
      expect(text, status).not.toContain("en cours");
      expect(text, status).toContain("annulé ou revenu");
      expect(text, status).toContain("« Comptabiliser… »");
      expect(text, status).not.toContain("Retour du paiement");
    }
    // the return offered: the text says so
    expect(debitReviewText(row({}), { return_guard: null })).toContain("« Retour du paiement … »");
    // a payout in flight among the candidates, or a cancelled payout whose run is still sent (that run's payout, ML-4):
    // « en cours »
    const inFlight = debitReviewText(row({ candidates: [{ ...ended("in_file"), run_status: "sent" }, ended("returned")] }));
    expect(inFlight).toContain("en cours");
    expect(inFlight).not.toContain("Retour du paiement");
    expect(debitReviewText(row({ candidates: [ended("cancelled", "sent")] }), { return_guard: "payout_candidate" })).toBe(
      DEBIT_REVIEW.payout_amount_match,
    );
  });
});

describe("the fee's and the explanation's refusal on a line « Comptabiliser… » does not offer (round 3)", () => {
  it("a flagged return of a payout's amount: its own words, never « Comptabiliser… »", () => {
    expect(guardRefusalCode("payout_candidate", true)).toBe("payout_candidate");
    expect(guardRefusalCode("payout_candidate", false)).toBe("payout_candidate_not_bookable");
    expect(guardRefusalCode("client_payout_line", false)).toBe("client_payout_line");
    const text = errorText("payout_candidate_not_bookable");
    expect(text).not.toContain("Comptabiliser");
    expect(text).not.toContain("comptabilisez");
    expect(text).toContain("« Retour du paiement … »");
    expect(errorText("payout_candidate")).toContain("« Comptabiliser… »");
    expect(errorText("payout_candidate")).not.toContain("virement du cabinet en cours (");
  });
});

describe("the run page (pages-1, money-4)", () => {
  const base: RunPayout = {
    transfers: [],
    payout_account_blocked: false,
    settled_on: "2026-11-16",
    settlement_minor: "26000",
    commission_minor: "36000",
    advances_recovered_minor: "0",
    advances: [],
    unplanned: [],
    draft_unplanned: [],
  };
  it("the commission set off is its own field, not D (a credit-note refund paid with the transfer lowers D)", () => {
    const notes = runPayoutNotes(base, EUR);
    expect(notes).toContain(`Commission réglée par compensation le 16/11/2026 : ${money("36000", EUR)}`);
    expect(notes.join(" ")).not.toContain(money("26000", EUR));
  });
  it("invoices and advances: each part with its amount", () => {
    const notes = runPayoutNotes({ ...base, settlement_minor: "41000", advances_recovered_minor: "5000" }, EUR);
    expect(notes).toContain(
      `Factures et avances réglées par compensation le 16/11/2026 : commission ${money("36000", EUR)}, avances du cabinet ${money("5000", EUR)}`,
    );
  });
  it("advances alone", () => {
    const notes = runPayoutNotes({ ...base, settlement_minor: "5000", commission_minor: "0", advances_recovered_minor: "5000" }, EUR);
    expect(notes).toContain(`Avances du cabinet récupérées par compensation le 16/11/2026 : ${money("5000", EUR)}`);
  });
  it("nothing set off: no sentence", () => {
    const notes = runPayoutNotes({ ...base, settlement_minor: "0", commission_minor: "0" }, EUR);
    expect(notes.join(" ")).not.toContain("compensation");
  });
  it("a draft deducts P, as the database returns it (0 < P < A)", () => {
    const notes = runPayoutNotes(
      { ...base, settled_on: null, draft_unplanned: [{ amount_minor: "120000", on: "2026-11-05", line_id: T,
                                                       statement_on: "2026-11-05" }] },
      EUR,
    );
    expect(notes).toContain(
      `Ce brouillon déduit ${money("120000", EUR)} déjà reçus par le client : virement exécuté hors reversement le 05/11/2026 (relevé du 05/11/2026).`,
    );
  });
});

/** An options read with one proposal of these parts (its preview ok). */
function options(o: {
  cls?: string;
  direction?: string;
  kind?: string;
  action: string;
  parts: Record<string, unknown>[];
  iban?: string | null;
  refusal?: string | null;
  pending?: string | null;
  pendingHeld?: boolean;
  members?: Record<string, unknown>[] | null;
}): TransferLineOptions {
  const parts = o.parts.map((p) => ({
    n: 1, kind: "payout", transfer_id: T, client_id: null, returns_line_id: null, amount_minor: "164000",
    paid_minor: "0", advance_minor: "0", p_bound: null, late: false, end_to_end_id: null, run_id: null,
    run_number: "RV-2026-000012", status: "in_file", client_name: "LILAS FINANCE", ...p,
  }));
  const parsed = parseTransferLineOptions({
    class: o.cls ?? "E", kind: o.kind ?? "transfer_out", direction: o.direction ?? "debit", amount_minor: "164000",
    booking_date: "2026-11-18", unsplit_ours: null, charges_minor: null, counterparty_iban_end: o.iban ?? null,
    proposals: o.refusal
      ? []
      : [{ action: o.action, request: [], parts,
           preview: { ok: true, why: null, detail: null, parts, drafts: [], supersedes_file: null, expected_text: "x" } }],
    members: o.members ?? null, member_count: o.members ? o.members.length : null,
    refusal: o.refusal ?? null, refusal_detail: null, pending_line_id: o.pending ?? null,
    pending_held: o.pendingHeld ?? false,
  });
  if (!parsed) throw new Error("unparsed");
  return parsed;
}
const effects = (o: TransferLineOptions) => transferLineEffects(o, o.proposals[0], EUR).join(" ");

describe("IBANs as the page masks them, never a country code it was not given (T1, pages-2)", () => {
  it("the payout account a return blocks: its last four, as the rest of the page", () => {
    const text = effects(options({ direction: "credit", kind: "return", action: "returned",
                                   parts: [{ kind: "payout_returned", payout_iban_end: "2606", blocks_account: true }] }));
    expect(text).toContain("son compte de reversement (IBAN …2606) est bloqué jusqu'à son remplacement ou sa reconfirmation");
    expect(text).not.toContain("FR76");
  });
  it("our own account in « Virement au compte propre »", () => {
    const text = effects(options({ cls: "N", action: "unplanned_sweep", iban: "0134",
                                   parts: [{ kind: "unplanned_sweep", transfer_id: null, share_after_minor: "1000" }] }));
    expect(text).toContain("Virement du compte dédié vers notre compte propre (IBAN …0134) sans ordre de Collectoo");
    expect(text).not.toContain("FR76");
  });
});

describe("a lot's members by the line's direction (pages-3)", () => {
  it("a credit returns its members", () => {
    expect(memberInLine({ transfer_id: T, in_proposal: true }, [{ kind: "payout_returned", transfer_id: T }],
                        { direction: "credit", decided: true })).toBe("revient par cette ligne");
    expect(memberInLine({ transfer_id: T, in_proposal: false }, [], { direction: "credit", decided: true })).toBe(
      "ne revient pas par cette ligne",
    );
  });
  it("a lot the options cannot split: which members the line holds is the bank's to confirm", () => {
    expect(memberInLine({ transfer_id: T, in_proposal: false }, [], { direction: "debit", decided: false })).toBe(
      "à confirmer par la banque",
    );
    expect(memberInLine({ transfer_id: T, in_proposal: true }, [{ kind: "payout", transfer_id: T }],
                        { direction: "debit", decided: true })).toBe("débit");
  });
});

describe("the sweep's debit has its own label (pages-4)", () => {
  it("« Débit de la quote-part du cabinet » when the proposal debits our sweep", () => {
    expect(transferLineActionLabel("payout", "N", [{ kind: "sweep" }])).toBe("Débit de la quote-part du cabinet");
    expect(transferLineActionLabel("payout", "E", [{ kind: "sweep" }, { kind: "fee" }])).toBe(
      "Débit de la quote-part du cabinet",
    );
    expect(transferLineActionLabel("payout", "E", [{ kind: "payout" }])).toBe("Débit d'un reversement");
    expect(transferLineButton("payout", "N")).toBe("Comptabiliser le débit");
  });
  it("the job's own_transfer_out review points to « Comptabiliser… », a sweep in flight first", () => {
    expect(DEBIT_REVIEW.own_transfer_out).toBe(
      "Virement émis vers l'un de nos comptes sans ordre de Collectoo : après vérification dans la banque, comptabilisez-le avec « Comptabiliser… » (débit de la quote-part du cabinet en cours de ce montant s'il y en a une, sinon « Virement au compte propre »).",
    );
  });
});

describe("a pending debit held in « Doublons possibles » (pages-5)", () => {
  it("the refusal says where the debit waits and what to do", () => {
    const held = options({ direction: "credit", kind: "return", action: "returned", parts: [],
                           refusal: "debit_pending", pending: T, pendingHeld: true });
    expect(held.pending_held).toBe(true);
    expect(pendingLineNote(held)).toEqual({
      text: "Ce débit attend dans « Doublons possibles » : décidez-le d'abord ; reconnu comme doublon, il ne compte plus et ce retour est repris automatiquement.",
      href: `/backoffice/encaissements/debits?onglet=doublons#ligne-${T}`,
      label: "Voir la ligne dans « Doublons possibles »",
    });
    const listed = options({ direction: "credit", kind: "return", action: "returned", parts: [],
                             refusal: "debit_pending", pending: T });
    expect(pendingLineNote(listed)).toEqual({
      text: null,
      href: `/backoffice/encaissements/debits?onglet=a-classer#ligne-${T}`,
      label: "Voir la ligne du débit",
    });
    expect(pendingLineNote(options({ action: "payout", parts: [{}] }))).toBeNull();
  });
});

describe("a queue the database could not read is said so (cs-1)", () => {
  it("never « Aucune ligne »", () => {
    expect(QUEUE_UNREAD).toContain("n'a pas pu être lue");
    expect(QUEUE_UNREAD).not.toContain("Aucune ligne");
  });
});

describe("the unbooked lines' alert says which lines it counts (legal-deadlines-3)", () => {
  it("our references, or a reference-less debit of the amount of a transfer of ours in flight", () => {
    expect(checkLabel("bank_line_unbooked").help).toBe(
      "Des débits ou retours de nos virements, ou des débits sans notre référence du montant d'un virement du cabinet en cours, attendent depuis plus d'un jour ouvré dans « Débits et retours ».",
    );
  });
});

describe("the sums a « Virement hors reversement » is netted from, by what became of its transfer (round 1)", () => {
  const unplanned = (status: string) =>
    effects(options({ action: "unplanned_payout", parts: [{ kind: "unplanned_payout", status, paid_minor: "164000",
                                                             advance_minor: "0", p_bound: "amount" }] }));
  it("a returned payout executed again: the sums its return put back, never « annulé »", () => {
    const text = unplanned("returned");
    expect(text).toContain(
      `${money("164000", EUR)} déjà reçus par LILAS FINANCE seront déduits de son prochain reversement (sommes du reversement RV-2026-000012 remises à reverser par le retour de son virement) ; avance du cabinet : ${money("0", EUR)}.`,
    );
    expect(text).not.toContain("RV-2026-000012 annulé");
  });
  it("a cancelled run's payout executed anyway: that run's sums", () => {
    expect(unplanned("cancelled")).toContain("(sommes du reversement RV-2026-000012 annulé, encore à reverser)");
  });
});
