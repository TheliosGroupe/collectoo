import { describe, expect, it } from "vitest";
import {
  CANCELLED_SWEEP_DEBITED,
  CANCELLED_TRANSFER_LIVE_RUN,
  DEBIT_REVIEW,
  checkLabel,
  debitReviewText,
} from "@/lib/payments/debits";
import * as debits from "@/lib/payments/debits";
import {
  type TransferLineOptions,
  type TransferLineProposal,
  transferLineErrorText,
  transferLineEffects,
  transferLineRefusalText,
} from "@/lib/payments/transfer-lines";
import * as documents from "@/lib/remittance/documents";
import { runPayoutNotes } from "@/lib/remittance/runs";
import { transferBookingText } from "@/lib/remittance/transfers";

/**
 * M2c-6b-3a-2 (docs/design/m2c-6b-3-plan.md §2 E–J, §4 T13–T18): the late predecessor's texts — a payout cancelled out of
 * a downloaded file whose run is still in flight, executed late by the bank, booked as its run's payout. Each is true
 * both ways: raised only once cancellation after download is on (6b-3b), and where the switch off reaches the same
 * code, the words stay true there too. None says « ne peut pas encore être comptabilisé » where « Comptabiliser… » now
 * books the line, nor that a replacement already handed out can no longer leave the account.
 */
const FALSE_ONCE_E = /ne peut pas encore être comptabilisé|il ne peut pas encore être comptabilisé/;

const OPTIONS: TransferLineOptions = {
  class: "E",
  kind: "transfer_out",
  direction: "debit",
  amount_minor: "164000",
  booking_date: "2026-11-18",
  unsplit_ours: null,
  charges_minor: null,
  counterparty_iban_end: null,
  proposals: [],
  members: null,
  member_count: null,
  refusal: null,
  refusal_detail: null,
  pending_line_id: null,
  pending_held: false,
};

function lpProposal(extra: Record<string, unknown>): TransferLineProposal {
  const part = {
    n: 1,
    kind: "payout",
    transfer_id: "x",
    client_id: "c",
    returns_line_id: null,
    amount_minor: "164000",
    paid_minor: "0",
    advance_minor: "0",
    p_bound: null,
    late: false,
    end_to_end_id: "RMTAAAAAAAAAAAA",
    run_id: "r",
    run_number: "RV-2026-000001",
    status: "cancelled",
    client_name: "Martin SAS",
    settlement_minor: "36000",
    late_predecessor: true,
    ...extra,
  };
  return {
    action: "payout",
    request: [],
    parts: [part],
    preview: { ok: true, why: null, detail: null, parts: [part], drafts: [], supersedes_file: null, expected_text: "t" },
  } as unknown as TransferLineProposal;
}

describe("M2c-6b-3a-2 (E, T13, T16): the late predecessor in « Débits et retours »", () => {
  it("the queue's text for a cancelled payout whose run is in flight books it as its run's payout (hedged)", () => {
    expect(CANCELLED_TRANSFER_LIVE_RUN).not.toMatch(FALSE_ONCE_E);
    expect(CANCELLED_TRANSFER_LIVE_RUN).toContain("« Débit d'un reversement »");
    expect(CANCELLED_TRANSFER_LIVE_RUN).toContain("le reversement est comptabilisé comme payé");
    expect(CANCELLED_TRANSFER_LIVE_RUN).toContain("vérifiez-le auprès de la banque quand la ligne ne porte pas sa référence");
    expect(
      debitReviewText({
        direction: "debit",
        kind: "transfer_out",
        end_to_end_id: "RMTAAAAAAAAAAAA",
        review_reason: "cancelled_transfer_debited",
        candidates: [{ transfer_id: "x", kind: "payout", status: "cancelled", run_status: "sent" }],
      }),
    ).toBe(CANCELLED_TRANSFER_LIVE_RUN);
  });
  it("run_still_live (an unplanned payout of it, still refused) points at « Débit d'un reversement »", () => {
    const t = transferLineErrorText("run_still_live");
    expect(t).not.toMatch(FALSE_ONCE_E);
    expect(t).toContain("« Débit d'un reversement »");
    expect(transferLineRefusalText("run_still_live", "RV-2026-000001")).toContain("(reversement RV-2026-000001)");
  });
  it("reissue_in_downloaded_file: ask the bank, cancel that file on evidence, then book — the file named", () => {
    const t = transferLineRefusalText("reissue_in_downloaded_file", "TF-2026-000012");
    expect(t).toContain("déjà téléchargé");
    expect(t).toContain("faites annuler ce fichier, relevés à l'appui (deux personnes)");
    expect(t).toContain("(fichier TF-2026-000012)");
    expect(t).not.toMatch(/ne peut plus (quitter|partir)/);
  });
  it("« déjà débité » names both transfers it may be (6b-3a review, low)", () => {
    const t = transferLineErrorText("already_debited");
    expect(t).toContain("celui qu'il remplace ou celui qui le remplace");
  });
  it("the sheet: the run booked as paid, its transfer « Annulé », the replacement by case", () => {
    const none = transferLineEffects(OPTIONS, lpProposal({}), "EUR").join(" ");
    expect(none).toContain("Débit d'un reversement — virement annulé, exécuté en retard");
    expect(none).toContain("RV-2026-000001 (Martin SAS) est comptabilisé comme payé le 18/11/2026");
    expect(none).toContain("son virement reste « Annulé »");
    expect(none).not.toContain("remplacement");
    expect(none).not.toContain("passe à « Débité »");
    const ordered = transferLineEffects(OPTIONS, lpProposal({ cancels_transfer_id: "y" }), "EUR").join(" ");
    expect(ordered).toContain("Son virement de remplacement, pas encore remis à la banque, est annulé.");
    const generated = transferLineEffects(
      OPTIONS,
      lpProposal({ cancels_transfer_id: "y", supersedes_file_number: "TF-2026-000013" }),
      "EUR",
    ).join(" ");
    expect(generated).toContain("retiré du fichier TF-2026-000013");
    expect(generated).toContain("les autres virements de ce fichier repassent dans le prochain fichier");
    for (const t of [none, ordered, generated]) expect(t).not.toMatch(/ne peut plus (quitter|partir)/);
  });
});

describe("M2c-6b-3a-2 (T14): the cancelled_transfer_debited review by kind, both ways", () => {
  it("a payout's: booked as its run's payout while in flight, else « Virement hors reversement »", () => {
    const t = DEBIT_REVIEW.cancelled_transfer_debited;
    expect(t).toContain("comme le débit de son reversement s'il est encore en cours");
    expect(t).toContain("sinon comme « Virement hors reversement »");
  });
  it("a refund's: never booked yet (S25)", () => {
    const text = debitReviewText({
      direction: "debit",
      kind: "transfer_out",
      end_to_end_id: "RFDAAAAAAAAAAAA",
      review_reason: "cancelled_transfer_debited",
      candidates: [{ transfer_id: "q", kind: "refund", status: "cancelled" }],
    });
    expect(text).toBe((debits as Record<string, unknown>).CANCELLED_REFUND_DEBITED);
    expect(text).toContain("ne refaites pas ce remboursement");
  });
  it("a cancelled sweep's batch line (its PmtInf, no SWP id; the job's candidates carry the kind) — the sweep's text (6b-3a review, low)", () => {
    expect(
      debitReviewText({
        direction: "debit",
        kind: "other_debit",
        end_to_end_id: null,
        payment_info_id: "TF-2026-000011-2",
        review_reason: "cancelled_transfer_debited",
        candidates: [{ transfer_id: "s", kind: "sweep", status: "cancelled", amount_minor: "12000" }],
      } as Parameters<typeof debitReviewText>[0]),
    ).toBe(CANCELLED_SWEEP_DEBITED);
  });
});

describe("M2c-6b-3a-2 (T15): « Contrôles » for a payout's late predecessor (the switch on)", () => {
  it("a cancelled payout alerted: « Débit d'un reversement » while its run is in flight", () => {
    const h = checkLabel("transfer_already_debited", {
      cancellationAfterDownload: true,
      details: { kind: "payout", status: "cancelled" },
    }).help;
    expect(h).toContain("« Débit d'un reversement »");
    expect(h).not.toContain("son reversement encore en cours, prévenez le support");
  });
  it("its re-issue held (ordered): book that debit, the hold ends; in a downloaded file: that file cancelled first", () => {
    const ordered = checkLabel("transfer_already_debited", {
      cancellationAfterDownload: true,
      details: { kind: "payout", status: "ordered" },
    }).help;
    expect(ordered).toContain("la retenue cesse");
    expect(ordered).not.toContain("prévenez le support pour rattacher");
    const inFile = checkLabel("transfer_already_debited", {
      cancellationAfterDownload: true,
      details: { kind: "payout", status: "in_file" },
    }).help;
    expect(inFile).toContain("faites annuler ce fichier, relevés à l'appui (deux personnes)");
  });
  it("the switch off keeps its words", () => {
    const off = checkLabel("transfer_already_debited", { cancellationAfterDownload: false }).help;
    expect(off).toContain("prévenez le support pour rattacher ce débit");
  });
});

describe("M2c-6b-3a-2 (J): P = 0 because the sums were already deducted after another late transfer", () => {
  it("says so, never « rattaché à aucune somme »", () => {
    const options = { ...OPTIONS, proposals: [] };
    const part = {
      n: 1,
      kind: "unplanned_payout",
      transfer_id: "x2",
      client_id: "c",
      returns_line_id: null,
      amount_minor: "164000",
      paid_minor: "0",
      advance_minor: "164000",
      p_bound: "items",
      late: false,
      end_to_end_id: "RMTBBBBBBBBBBBB",
      run_id: "r2",
      run_number: "RV-2026-000002",
      status: "cancelled",
      client_name: "Martin SAS",
    };
    const proposal = {
      action: "unplanned_payout",
      request: [],
      parts: [part],
      preview: { ok: true, why: null, detail: null, parts: [part], drafts: [], supersedes_file: null, expected_text: "t" },
    } as unknown as TransferLineProposal;
    const t = transferLineEffects(options, proposal, "EUR").join(" ");
    expect(t).toContain("ont déjà été déduites");
    expect(t).not.toContain("n'est rattaché à aucune somme");
  });
});

describe("M2c-6b-3a-2 (T17, T18): the run page, « Virements » and the client space", () => {
  it("the run page: the late predecessor debited (and returned) — its transfer cancelled", () => {
    const notes = runPayoutNotes(
      {
        transfers: [
          { id: "y", status: "cancelled", debited_on: null, returned_on: null, line_id: null },
          {
            id: "x",
            status: "cancelled",
            amount_minor: "164000",
            debited_on: "2026-11-18",
            returned_on: "2026-11-20",
            line_id: "l",
            late_predecessor: true,
          },
        ],
        settled_on: null,
        settlement_minor: "0",
        commission_minor: "0",
        advances_recovered_minor: "0",
        advances: [],
        unplanned: [],
        draft_unplanned: [],
      },
      "EUR",
    );
    expect(notes).toContain("Débité de notre compte le 18/11/2026 (virement annulé, exécuté en retard par la banque)");
    expect(notes.some((n) => n.startsWith("Virement revenu impayé le 20/11/2026"))).toBe(true);
  });
  it("« Virements »: a cancelled transfer booked as its run's payout", () => {
    expect(
      transferBookingText("cancelled", {
        transfer_id: "x",
        debited_on: "2026-11-18",
        returned_on: null,
        unplanned_on: null,
      } as Parameters<typeof transferBookingText>[1]),
    ).toBe("Annulé — exécuté en retard par la banque le 18/11/2026, comptabilisé comme le débit de son reversement");
    expect(
      transferBookingText("cancelled", {
        transfer_id: "x",
        debited_on: "2026-11-18",
        returned_on: "2026-11-20",
        unplanned_on: null,
      } as Parameters<typeof transferBookingText>[1]),
    ).toContain(", revenu impayé le 20/11/2026");
  });
  it("the client space: a cancelled run whose transfer the bank refused, from the summary's per-run fact", () => {
    const cancelledRuns = (documents as Record<string, unknown>).cancelledRuns as (s: unknown) => Map<string, string>;
    const m = cancelledRuns({
      cancelled_runs: [
        { run_id: "a", transfer_outcome: "not_executed" },
        { run_id: "b", transfer_outcome: "never_handed_out" },
        { run_id: "c", transfer_outcome: "guess" },
      ],
    });
    expect([...m.entries()]).toEqual([
      ["a", "not_executed"],
      ["b", "never_handed_out"],
    ]);
    const view = (
      documents.statementRunView as unknown as (
        run: unknown,
        returned: unknown,
        unplanned: unknown,
        outcome: unknown,
      ) => { label: string }
    )({ status: "cancelled", net_minor: "164000" }, null, null, "not_executed");
    expect(view.label).toBe("Annulé : la banque n'a pas exécuté son virement (les relevés ne le montraient pas débité)");
    expect(documents.statementRunView({ status: "cancelled", net_minor: "164000" }, null, null).label).toBe(
      "Annulé avant la remise de son virement à la banque",
    );
  });
});

describe("M2c-6b-3a-2 review round 1: texts true of what ships", () => {
  it("pages-texts-6, LD-2: reissue_in_downloaded_file — the replacement's own debit is the run's; this one becomes « Virement hors reversement »", () => {
    const t = transferLineErrorText("reissue_in_downloaded_file");
    expect(t).toContain("son débit est celui du reversement (l'import le comptabilise)");
    expect(t).toContain("comptabilisez alors ce débit-ci comme « Virement hors reversement »");
    expect(t).not.toContain("ce débit-là");
  });
  it("pages-texts-6: the queue's text for a live run says « Comptabiliser… » first says what to do with a downloaded replacement's file", () => {
    expect(CANCELLED_TRANSFER_LIVE_RUN).toContain(
      "Si son virement de remplacement est déjà dans un fichier téléchargé, « Comptabiliser… » dit d'abord quoi faire de ce fichier.",
    );
  });
  it("pages-texts-3: a late predecessor's sheet opens with its own intro, never « comme l'import le fait »", () => {
    const effects = transferLineEffects(OPTIONS, lpProposal({}), "EUR");
    expect(effects[0]).toContain("l'import ne comptabilise jamais seul le débit d'un virement annulé");
    expect(effects.join(" ")).not.toContain("comme l'import le fait quand la ligne porte sa référence");
    // a live payout keeps the payout intro
    const live = transferLineEffects(OPTIONS, lpProposal({ late_predecessor: false, status: "in_file" }), "EUR");
    expect(live[0]).toContain("comme l'import le fait quand la ligne porte sa référence");
  });
  it("DP-3: an unplanned payout of a cancelled transfer whose run is booked nets the items its return put back", () => {
    const part = {
      n: 1,
      kind: "unplanned_payout",
      transfer_id: "x",
      client_id: "c",
      returns_line_id: null,
      amount_minor: "164000",
      paid_minor: "164000",
      advance_minor: "0",
      p_bound: "amount",
      late: false,
      end_to_end_id: "RMTAAAAAAAAAAAA",
      run_id: "r",
      run_number: "RV-2026-000001",
      status: "cancelled",
      run_status: "booked",
      client_name: "Martin SAS",
    };
    const proposal = {
      action: "unplanned_payout",
      request: [],
      parts: [part],
      preview: { ok: true, why: null, detail: null, parts: [part], drafts: [], supersedes_file: null, expected_text: "t" },
    } as unknown as TransferLineProposal;
    const t = transferLineEffects({ ...OPTIONS, proposals: [] }, proposal, "EUR").join(" ");
    expect(t).toContain("(sommes du reversement RV-2026-000001 remises à reverser par le retour de son virement)");
    expect(t).not.toContain("annulé, encore à reverser");
    const cancelledRun = transferLineEffects(
      { ...OPTIONS, proposals: [] },
      {
        ...proposal,
        preview: { ...proposal.preview, parts: [{ ...part, run_status: "cancelled" }] },
      } as unknown as TransferLineProposal,
      "EUR",
    ).join(" ");
    expect(cancelledRun).toContain("(sommes du reversement RV-2026-000001 annulé, encore à reverser)");
  });
  it("pages-texts-1, pages-texts-5: the run page names the reference the bank debited; a second execution is « une seconde fois »", () => {
    const notes = runPayoutNotes(
      {
        transfers: [
          { id: "y", status: "cancelled", end_to_end_id: "RMTBBBBBBBBBBBB", debited_on: null, returned_on: null, line_id: null },
          {
            id: "x",
            status: "cancelled",
            end_to_end_id: "RMTAAAAAAAAAAAA",
            amount_minor: "164000",
            debited_on: "2026-11-18",
            returned_on: null,
            line_id: "l",
            late_predecessor: true,
          },
        ],
        settled_on: null,
        settlement_minor: "0",
        commission_minor: "0",
        advances_recovered_minor: "0",
        advances: [],
        unplanned: [
          {
            line_id: "l2",
            kind: "unplanned_payout",
            amount_minor: "164000",
            on: "2026-11-19",
            paid_minor: "0",
            advance_minor: "164000",
            after_cancellation: false,
          },
        ],
        draft_unplanned: [],
      },
      "EUR",
    );
    expect(notes).toContain(
      "Débité de notre compte le 18/11/2026 sous la référence RMTAAAAAAAAAAAA (virement annulé, exécuté en retard par la banque)",
    );
    expect(notes.some((n) => n.includes("une seconde fois le 19/11/2026"))).toBe(true);
    expect(notes.some((n) => n.includes("après son annulation"))).toBe(false);
  });
  it("pages-texts-4: a cancelled run whose transfer may have been debited (debit_pending) — never « la banque n'a pas exécuté »", () => {
    const cancelledRuns = (documents as Record<string, unknown>).cancelledRuns as (s: unknown) => Map<string, string>;
    expect([...cancelledRuns({ cancelled_runs: [{ run_id: "a", transfer_outcome: "debit_pending" }] }).entries()]).toEqual([
      ["a", "debit_pending"],
    ]);
    const view = (
      documents.statementRunView as unknown as (
        run: unknown,
        returned: unknown,
        unplanned: unknown,
        outcome: unknown,
      ) => { label: string }
    )({ status: "cancelled", net_minor: "164000" }, null, null, "debit_pending");
    expect(view.label).toBe("Annulé — un débit de notre compte qui peut être son virement est en cours de vérification");
    expect(view.label).not.toContain("n'a pas exécuté");
  });
  it("pages-texts-5: « Virements » keeps a late predecessor's second execution", () => {
    expect(
      transferBookingText("cancelled", {
        transfer_id: "x",
        debited_on: "2026-11-18",
        returned_on: null,
        unplanned_on: "2026-11-19",
      } as Parameters<typeof transferBookingText>[1]),
    ).toBe(
      "Annulé — exécuté en retard par la banque le 18/11/2026, comptabilisé comme le débit de son reversement ; exécuté une seconde fois le 19/11/2026, hors reversement",
    );
  });
});

describe("M2c-6b-3a-2 review round 2: one run's payout executed twice, one copy back — texts true of what ships", () => {
  const returnPart = (extra: Record<string, unknown>) => ({
    n: 1,
    transfer_id: "y",
    client_id: "c",
    returns_line_id: "lx",
    amount_minor: "164000",
    paid_minor: "0",
    advance_minor: "164000",
    p_bound: null,
    late: false,
    end_to_end_id: "RMTBBBBBBBBBBBB",
    run_id: "r",
    run_number: "RV-2026-000001",
    status: "booked",
    client_name: "Martin SAS",
    returns_on: "2026-11-02",
    ...extra,
  });
  const returnProposal = (part: Record<string, unknown>) =>
    ({
      action: "returned",
      request: [],
      parts: [part],
      preview: { ok: true, why: null, detail: null, parts: [part], drafts: [], supersedes_file: null, expected_text: "t" },
    }) as unknown as TransferLineProposal;
  const CREDIT: TransferLineOptions = { ...OPTIONS, direction: "credit", kind: "return" };

  it("ld2-reissue-return-pays-twice: the run's payout's return closing another copy names both transfers and says the client keeps one", () => {
    const t = transferLineEffects(
      CREDIT,
      returnProposal(returnPart({ kind: "unplanned_payout_returned", closes_end_to_end_id: "RMTAAAAAAAAAAAA" })),
      "EUR",
    ).join(" ");
    expect(t).toContain(
      "Ce retour du virement RMTBBBBBBBBBBBB solde le virement RMTAAAAAAAAAAAA du même reversement, exécuté hors reversement le 02/11/2026",
    );
    expect(t).toContain("Martin SAS garde l'un des deux virements et n'a reçu ce reversement qu'une fois.");
    expect(t).toContain("l'avance du cabinet de");
    expect(t).toContain("rien n'est de nouveau dû à Martin SAS");
    // the unplanned payout's own return keeps its sentence alone
    const own = transferLineEffects(CREDIT, returnProposal(returnPart({ kind: "unplanned_payout_returned" })), "EUR");
    expect(own.join(" ")).not.toContain("du même reversement");
  });
  it("ld2-reissue-return-pays-twice: the other copy back too is the run's payout's return — its sums owed again", () => {
    const t = transferLineEffects(
      CREDIT,
      returnProposal(returnPart({ kind: "payout_returned", returned_end_to_end_id: "RMTAAAAAAAAAAAA" })),
      "EUR",
    ).join(" ");
    expect(t).toContain(
      "Le virement RMTAAAAAAAAAAAA du même reversement, exécuté hors reversement, revient aussi : son exécution a déjà été soldée par le retour du virement RMTBBBBBBBBBBBB ; ce retour-ci est donc celui du reversement, Martin SAS n'en a plus rien reçu.",
    );
    expect(t).toContain("RV-2026-000001 : ");
    expect(t).toContain("de nouveau dus à Martin SAS");
    const plain = transferLineEffects(CREDIT, returnProposal(returnPart({ kind: "payout_returned" })), "EUR");
    expect(plain.join(" ")).not.toContain("revient aussi");
  });
  it("ld2-reissue-return-pays-twice: the run page says which transfer came back when another's return closed an unplanned copy", () => {
    const notes = runPayoutNotes(
      {
        transfers: [],
        settled_on: null,
        settlement_minor: "0",
        commission_minor: "0",
        advances_recovered_minor: "0",
        advances: [],
        unplanned: [
          {
            line_id: "lx",
            kind: "unplanned_payout",
            amount_minor: "164000",
            on: "2026-10-28",
            paid_minor: "0",
            advance_minor: "164000",
            after_cancellation: true,
            returned: true,
            returned_by_end_to_end_id: "RMTBBBBBBBBBBBB",
          },
        ],
        draft_unplanned: [],
      },
      "EUR",
    );
    expect(notes).toContain(
      "Le virement RMTBBBBBBBBBBBB de ce reversement est revenu depuis : son retour solde ce virement hors reversement du 28/10/2026 (le client n'a reçu ce reversement qu'une fois) ; il est comptabilisé.",
    );
    expect(notes.some((n) => n.startsWith("Ce virement hors reversement du 28/10/2026 est revenu depuis"))).toBe(false);
  });
  it("ld2-reissue-return-pays-twice: the refusals and the job's review name the other transfer of the run (both ways true)", () => {
    expect(transferLineErrorText("unplanned_open")).toContain("Ce virement, ou un autre virement du même reversement");
    expect(transferLineErrorText("debit_pending")).toContain("ou d'un autre virement du même reversement");
    expect(transferLineErrorText("debit_pending")).toContain("ce retour sera alors celui du virement hors reversement");
    expect(DEBIT_REVIEW.return_debit_pending).toContain("ou celui d'un autre virement du même reversement");
  });
});
