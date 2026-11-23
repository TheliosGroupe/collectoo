import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { allocationErrorCode } from "./allocation";
import { CHECK_LABEL, checkLabel, debitErrorCode } from "./debits";
import {
  FULL_CHECK,
  advanceIdsParam,
  coverErrorCode,
  coverPrompt,
  fullCheckErrorCode,
  parseAdvanceIds,
  parseAllocationRemitted,
  remittedHead,
  returnRemittedNote,
  reverseErrorCode,
  reverseNotice,
  reverseRemittedEffect,
  reverseToast,
  type RemittedEntry,
} from "./remitted";
import { transferLineErrorCode, transferLineErrorText } from "./transfer-lines";
import { type RunPayout, runPayoutNotes } from "@/lib/remittance/runs";

/** the amounts as French text (money() spaces them with no-break spaces) */
const plain = (s: string | null) => (s === null ? null : s.replace(/[\u00a0\u202f]/g, " "));

const base: RemittedEntry = {
  entry_id: "00000000-0000-0000-0000-000000000001",
  account_id: "00000000-0000-0000-0000-000000000002",
  run_number: "RV-2026-000001",
  run_transfer: true,
  booked_on: "2026-11-03",
  amount_minor: "200000",
  paid_on: "2026-11-03",
  paid_how: "paid",
  paid_run_number: "RV-2026-000001",
  returned_via: null,
};

describe("M2c-7a checks (plan §3.7)", () => {
  it("labels the three new checks in French", () => {
    expect(CHECK_LABEL.remitted_reversal_uncovered).toEqual({
      label: "Annulation d'un encaissement déjà reversé sans avance du cabinet",
      help: "Un encaissement déjà versé au client a été annulé sans que le cabinet en fasse l'avance : la somme serait déduite des autres encaissements du client, une compensation faite sans l'avance ni la clause qui la prévoit. « Couvrir » enregistre l'avance.",
    });
    expect(CHECK_LABEL.advance_ledger).toEqual({
      label: "Avances du cabinet ≠ compte des avances",
      help: "Pour ce client, les avances non récupérées ne valent pas le solde du compte des avances à récupérer (I18).",
    });
    expect(CHECK_LABEL.advance_open).toEqual({
      label: "Avance du cabinet non récupérée depuis plus de 30 jours",
      help: "Le cabinet a avancé cette somme au client (encaissement repris après reversement, reversement au-delà du dû, virement hors reversement). Elle n'est pas encore récupérée.",
    });
  });
  it("rewords the overrun and double payout helps (no « pas encore géré »)", () => {
    expect(checkLabel("payout_overrun").help).toBe(
      "Un reversement débité dépassait ce qui restait dû au client : le cabinet lui a avancé la différence.",
    );
    expect(checkLabel("double_payout_open").help).toBe(
      "Avance du cabinet après un virement exécuté hors reversement.",
    );
    for (const code of ["payout_overrun", "double_payout_open", "advance_open"])
      expect(checkLabel(code).help).not.toContain("pas encore géré");
  });
  it("never says « qu'aucune clause ne permet » (L19 a)", () => {
    expect(CHECK_LABEL.remitted_reversal_uncovered.help).not.toContain("aucune clause");
  });
});

describe("LG009 and the lock wait (plan §3.7)", () => {
  const lg009 =
    "L'encaissement avait déjà été reversé au client : l'avance du cabinet n'a pas pu être enregistrée. Réessayez ; si cela continue, prévenez le support.";
  it("maps LG009 on a transfer line, a debit link and « Désimputer »", () => {
    const tl = transferLineErrorCode({
      message: "transfer line booking refused: posting_failed (LG009: ledger: reversal x of an entry remitted …)",
      code: "23514",
    });
    expect(tl).toBe("remitted_cover_failed");
    expect(transferLineErrorText(tl)).toBe(lg009);
    const dl = debitErrorCode("debit link refused: posting_failed (LG009: ledger: reversal x …)");
    expect(dl).toBe("remitted_cover_failed");
    expect(errorText(dl)).toBe(lg009);
    expect(
      allocationErrorCode("ledger: reversal x of an entry remitted to client y is not covered by an advance (gap 1)"),
    ).toBe("remitted_cover_failed");
  });
  it("keeps the other posting failures as before", () => {
    expect(debitErrorCode("debit link refused: posting_failed (LG007: overdrawn)")).toBe("link_posting_failed");
    expect(
      transferLineErrorCode({ message: "transfer line booking refused: posting_failed (P0001: LG008 …)", code: "23514" }),
    ).toBe("posting_failed");
  });
  it("words a lock wait of « Désimputer » as an operation on the transfers", () => {
    expect(reverseErrorCode({ code: "55P03", message: "canceling statement due to lock timeout" })).toBe(
      "transfers_busy",
    );
    expect(errorText("transfers_busy")).toBe("Opération en cours sur les virements : réessayez dans un instant.");
    expect(reverseErrorCode({ code: "P0001", message: "the allocation changed: reload the page" })).toBe(
      "allocation_changed",
    );
  });
});

describe("« Désimputer » of a remitted entry (plan §3.7, §3.2.1)", () => {
  it("parses the read and refuses another shape", () => {
    expect(parseAllocationRemitted([base])).toEqual([base]);
    expect(parseAllocationRemitted([{ ...base, amount_minor: 200000 }])).toBeNull();
    expect(parseAllocationRemitted({})).toBeNull();
    // review round 1 (M7A-MONEY-2): whether the remitted run had a payout transfer is part of the read
    const noTransfer: Record<string, unknown> = { ...base };
    delete noTransfer.run_transfer;
    expect(parseAllocationRemitted([noTransfer])).toBeNull();
    expect(parseAllocationRemitted([{ ...base, run_transfer: "true" }])).toBeNull();
    // review round 2: what came back first is part of the read too, one of its two values or null
    for (const via of ["run", "unplanned"] as const)
      expect(parseAllocationRemitted([{ ...base, returned_via: via }])).toEqual([{ ...base, returned_via: via }]);
    const noVia: Record<string, unknown> = { ...base };
    delete noVia.returned_via;
    expect(parseAllocationRemitted([noVia])).toBeNull();
    expect(parseAllocationRemitted([{ ...base, returned_via: "transfer" }])).toBeNull();
  });
  it("(review round 2) names an unplanned payout that came back, also in a run with its own transfer", () => {
    // 043 17 (i): E remitted in Y (a run with its own transfer), paid by an unplanned payout U that came back
    const back: RemittedEntry = {
      ...base,
      run_number: "RV-2026-000140",
      paid_on: null,
      paid_how: null,
      paid_run_number: null,
      returned_via: "unplanned",
    };
    expect(remittedHead(back)).toBe(
      "Compris dans le reversement RV-2026-000140 (le virement hors reversement qui l'avait payé est revenu, à verser de nouveau).",
    );
    expect(plain(returnRemittedNote([back], "EUR"))).toBe(
      "Paiement compris dans le reversement RV-2026-000140 (le virement hors reversement qui l'avait payé est revenu, à verser de nouveau) : au retour, le cabinet lui avance 2 000,00 €.",
    );
    for (const t of [remittedHead(back), returnRemittedNote([back], "EUR")]) {
      expect(t).not.toContain("reversé au client");
      expect(t).not.toContain("débité");
    }
    // then Z paid the re-queued item: the run had a transfer of its own, yet what came back was U's
    const paid: RemittedEntry = { ...back, paid_on: "2026-11-23", paid_how: "paid", paid_run_number: "RV-2026-000141" };
    expect(remittedHead(paid)).toBe(
      "Déjà reversé au client (reversement RV-2026-000141, débité le 23/11/2026, après le retour du virement hors reversement qui l'avait payé).",
    );
    expect(remittedHead(paid)).not.toContain("virement du reversement RV-2026-000140");
    expect(plain(returnRemittedNote([paid], "EUR"))).toBe(
      "Paiement déjà reversé au client (RV-2026-000141, après le retour du virement hors reversement qui l'avait payé) : au retour, le cabinet lui avance 2 000,00 €.",
    );
    // 043 17 (h), switch off: X's own payout came back, its re-execution came back too — not paid again
    const own: RemittedEntry = { ...base, paid_on: null, paid_how: null, paid_run_number: null, returned_via: "run" };
    expect(remittedHead(own)).toBe("Compris dans le reversement RV-2026-000001 (revenu, à verser de nouveau).");
    expect(remittedHead(own)).not.toContain("Déjà reversé");
  });
  it("(review round 3) words an entry an unplanned payout paid in full while its run's own payout came back", () => {
    // 043 17 (j): E remitted in Y (a run with its own transfer), paid in full by U (debited on 19/11, never back); Y's
    // payout came back with F's money, then W paid it: E is with the client through U, never through Y nor W
    const e: RemittedEntry = {
      ...base,
      run_number: "RV-2026-000088",
      booked_on: "2026-11-20",
      amount_minor: "40000",
      paid_on: "2026-11-19",
      paid_how: "unplanned",
      paid_run_number: null,
      returned_via: null,
    };
    expect(parseAllocationRemitted([e])).toEqual([e]);
    expect(parseAllocationRemitted([{ ...e, paid_how: "transfer" }])).toBeNull();
    expect(remittedHead(e)).toBe(
      "Déjà reversé au client (payé par le virement hors reversement débité le 19/11/2026).",
    );
    expect(plain(returnRemittedNote([e], "EUR"))).toBe(
      "Paiement déjà reversé au client (payé par le virement hors reversement débité le 19/11/2026) : au retour, le cabinet lui avance 400,00 €.",
    );
    for (const t of [remittedHead(e), returnRemittedNote([e], "EUR")]) {
      expect(t).not.toContain("à verser de nouveau");
      expect(t).not.toContain("RV-2026-000088");
      expect(t).not.toContain("20/11/2026");
    }
    // F, beside it in Y, waits for the re-queued net: both sentences on the sheet, the advance for both
    const f: RemittedEntry = {
      ...e,
      entry_id: "00000000-0000-0000-0000-000000000003",
      amount_minor: "25000",
      paid_on: null,
      paid_how: null,
      returned_via: "run",
    };
    expect(plain(reverseRemittedEffect([e, f], "EUR"))).toBe(
      "Déjà reversé au client (payé par le virement hors reversement débité le 19/11/2026). Compris dans le reversement RV-2026-000088 (revenu, à verser de nouveau). En désimputant, le cabinet lui en fait l'avance (650,00 €) : la somme n'est pas déduite de ses autres encaissements.",
    );
    // through rule 3 (the remitted run's own payout came back, its re-queued item paid by an unplanned payout), and
    // after an unplanned payout that had paid it came back: what came back is named, the run that carried it is not
    // said to have paid it
    const viaRun = remittedHead({ ...e, run_number: "RV-2026-000001", paid_on: "2026-11-21", returned_via: "run" });
    expect(viaRun).toBe(
      "Déjà reversé au client (payé par un virement hors reversement débité le 21/11/2026, après le retour du virement du reversement RV-2026-000001).",
    );
    const viaUnplanned = returnRemittedNote([{ ...e, paid_on: "2026-11-21", returned_via: "unplanned" }], "EUR");
    expect(plain(viaUnplanned)).toBe(
      "Paiement déjà reversé au client (payé par un autre virement hors reversement débité le 21/11/2026, après le retour de celui qui l'avait payé) : au retour, le cabinet lui avance 400,00 €.",
    );
    // never « payé par » without its date: no paid_on is the waiting sentence
    expect(remittedHead({ ...e, paid_on: null })).toBe(
      "Compris dans le reversement RV-2026-000088 (revenu, à verser de nouveau).",
    );
  });
  it("(review round 1, M7A-MONEY-2) names the payout that came back: the run's own, or one outside any run", () => {
    // run_settled_on rule 3: the remitted run's own payout came back, a later run paid the re-queued item
    expect(
      remittedHead({ ...base, paid_on: "2026-11-17", paid_run_number: "RV-2026-000004", returned_via: "run" }),
    ).toContain(
      "après le retour du virement du reversement RV-2026-000001",
    );
    // rule 4: the remitted run was an N = 0 run (no transfer): what came back was an unplanned payout
    const rule4 = remittedHead({
      ...base,
      run_transfer: false,
      returned_via: "unplanned",
      paid_on: "2026-11-21",
      paid_run_number: "RV-2026-000675",
      run_number: "RV-2026-000674",
    });
    expect(rule4).toBe(
      "Déjà reversé au client (reversement RV-2026-000675, débité le 21/11/2026, après le retour du virement hors reversement qui l'avait payé).",
    );
    expect(rule4).not.toContain("virement du reversement RV-2026-000674");
  });
  it("says it per paid_how, never « versé » or « débité » for a set-off or a net nil", () => {
    expect(remittedHead(base)).toBe("Déjà reversé au client (reversement RV-2026-000001, débité le 03/11/2026).");
    expect(
      remittedHead({ ...base, paid_on: "2026-11-17", paid_run_number: "RV-2026-000004", returned_via: "run" }),
    ).toBe(
      "Déjà reversé au client (reversement RV-2026-000004, débité le 17/11/2026, après le retour du virement du reversement RV-2026-000001).",
    );
    const setOff = remittedHead({ ...base, paid_how: "set_off" });
    expect(setOff).toBe("Déjà réglé au client par compensation dans le relevé RV-2026-000001 du 03/11/2026.");
    const netted = remittedHead({ ...base, paid_how: "netted" });
    expect(netted).toBe("Déjà compris dans le relevé RV-2026-000001 du 03/11/2026 (montant net nul).");
    for (const t of [setOff, netted]) {
      expect(t).not.toContain("versé");
      expect(t).not.toContain("débité");
    }
    expect(remittedHead({ ...base, paid_on: null, paid_how: null, paid_run_number: null })).toBe(
      "Compris dans le reversement RV-2026-000001 (revenu, à verser de nouveau).",
    );
  });
  it("adds the advance and that nothing is deducted from the client's other collections", () => {
    expect(plain(reverseRemittedEffect([base], "EUR"))).toBe(
      "Déjà reversé au client (reversement RV-2026-000001, débité le 03/11/2026). En désimputant, le cabinet lui en fait l'avance (2 000,00 €) : la somme n'est pas déduite de ses autres encaissements.",
    );
    expect(reverseRemittedEffect([], "EUR")).toBeNull();
    expect(reverseRemittedEffect([base], "EUR")).not.toContain("récupérée selon son mandat");
  });
  it("toasts the advance recorded", () => {
    expect(plain(reverseToast([{ amount_minor: "200000" }], "EUR"))).toBe(
      "Imputation annulée ; avance du cabinet de 2 000,00 € enregistrée.",
    );
    expect(reverseToast([], "EUR")).toBe("Imputation annulée.");
  });
  it("words a return of such a payment on « Débits et retours »", () => {
    expect(plain(returnRemittedNote([base], "EUR"))).toBe(
      "Paiement déjà reversé au client (RV-2026-000001) : au retour, le cabinet lui avance 2 000,00 €.",
    );
    expect(returnRemittedNote([], "EUR")).toBeNull();
  });
  it("(review round 1, tests-ui-1) words the return per paid_how: « reversé » only for a payout paid and kept", () => {
    const back = returnRemittedNote([{ ...base, paid_on: null, paid_how: null, paid_run_number: null }], "EUR");
    expect(plain(back)).toBe(
      "Paiement compris dans le reversement RV-2026-000001 (revenu, à verser de nouveau) : au retour, le cabinet lui avance 2 000,00 €.",
    );
    const setOff = returnRemittedNote([{ ...base, paid_how: "set_off" }], "EUR");
    expect(plain(setOff)).toBe(
      "Paiement déjà réglé au client par compensation dans le relevé RV-2026-000001 du 03/11/2026 : au retour, le cabinet lui avance 2 000,00 €.",
    );
    const netted = returnRemittedNote([{ ...base, paid_how: "netted" }], "EUR");
    expect(plain(netted)).toBe(
      "Paiement déjà compris dans le relevé RV-2026-000001 du 03/11/2026 (montant net nul) : au retour, le cabinet lui avance 2 000,00 €.",
    );
    for (const t of [back, setOff, netted]) {
      expect(t).not.toContain("reversé au client");
      expect(t).not.toContain("versé le");
      expect(t).not.toContain("débité");
    }
    // a payout paid through a later run, after its own came back (rule 3) or after an unplanned one did (rule 4)
    expect(
      plain(
        returnRemittedNote(
          [{ ...base, paid_on: "2026-11-17", paid_run_number: "RV-2026-000004", returned_via: "run" }],
          "EUR",
        ),
      ),
    ).toBe(
      "Paiement déjà reversé au client (RV-2026-000004, après le retour du virement du reversement RV-2026-000001) : au retour, le cabinet lui avance 2 000,00 €.",
    );
    expect(
      plain(
        returnRemittedNote(
          [
            {
              ...base,
              run_transfer: false,
              returned_via: "unplanned",
              paid_on: "2026-11-17",
              paid_run_number: "RV-2026-000004",
            },
          ],
          "EUR",
        ),
      ),
    ).toBe(
      "Paiement déjà reversé au client (RV-2026-000004, après le retour du virement hors reversement qui l'avait payé) : au retour, le cabinet lui avance 2 000,00 €.",
    );
    // two entries of different kinds: each clause once, one advance for the total
    expect(
      plain(returnRemittedNote([base, { ...base, entry_id: "x", amount_minor: "5000", paid_how: "set_off" }], "EUR")),
    ).toBe(
      "Paiement déjà reversé au client (RV-2026-000001) ; déjà réglé au client par compensation dans le relevé RV-2026-000001 du 03/11/2026 : au retour, le cabinet lui avance 2 050,00 €.",
    );
  });
});

describe("(review round 1, M7A-MONEY-3) the notice after « Désimputer » reads the advances back from the ledger", () => {
  const adv = "11111111-1111-4111-8111-111111111111";
  const rev = "22222222-2222-4222-8222-222222222222";
  it("carries ids in the URL, never an amount", () => {
    expect(advanceIdsParam([adv, adv])).toBe(`${adv},${adv}`);
    expect(parseAdvanceIds(`${adv},${adv}`)).toEqual([adv, adv]);
    expect(parseAdvanceIds("")).toEqual([]);
    expect(parseAdvanceIds(undefined)).toBeNull();
    expect(parseAdvanceIds("123456789")).toBeNull();
    expect(parseAdvanceIds([adv])).toBeNull();
    expect(parseAdvanceIds(Array.from({ length: 51 }, () => adv).join(","))).toBeNull();
  });
  it("totals only this payment's live advances, as the ledger holds them", () => {
    const rows = [
      { id: adv, amount_minor: "50000", cause_entry_id: rev, reversed: false },
      // another payment's reversal (a crafted or stale link): not counted
      { id: adv, amount_minor: "123456789", cause_entry_id: "33333333-3333-4333-8333-333333333333", reversed: false },
      // released since (its entry reversed): not counted
      { id: adv, amount_minor: "7000", cause_entry_id: rev, reversed: true },
    ];
    expect(plain(reverseNotice(rows, new Set([rev]), "EUR"))).toBe(
      "Imputation annulée ; avance du cabinet de 500,00 € enregistrée.",
    );
    expect(reverseNotice([], new Set([rev]), "EUR")).toBe("Imputation annulée.");
    // nothing of this payment was reversed: no notice at all
    expect(reverseNotice(rows, new Set(), "EUR")).toBeNull();
  });
});

describe("« Couvrir » and the full check (plan §3.7)", () => {
  it("prompts with the amount, the client and the date of the reversal", () => {
    expect(plain(coverPrompt("12000", "EUR", "Martin SAS", "2026-11-12"))).toBe(
      "Enregistrer l'avance du cabinet de 120,00 € au client Martin SAS pour l'annulation du 12/11/2026",
    );
  });
  it("maps the refusals", () => {
    expect(coverErrorCode("remitted cover refused: nothing_to_cover")).toBe("cover_nothing_to_cover");
    expect(errorText("cover_nothing_to_cover")).toBe("Rien à couvrir : l'avance existe déjà.");
    expect(coverErrorCode("remitted cover refused: gap_changed")).toBe("cover_gap_changed");
    expect(errorText("cover_gap_changed")).toBe("Le montant a changé : rechargez la page.");
    expect(coverErrorCode("remitted cover refused: over_covered")).toBe("cover_over_covered");
    expect(errorText("cover_over_covered")).toBe("L'avance dépasse l'encaissement annulé : prévenez le support.");
    expect(coverErrorCode("not allowed")).toBe("not_allowed");
  });
  it("names the full check, its help, its toast and its refusal", () => {
    expect(FULL_CHECK.label).toBe("Vérification complète des avances");
    expect(FULL_CHECK.help).toBe(
      "Les contrôles de chaque nuit relisent les annulations récentes ; le 1er du mois, ils relisent tous les reversements débités. Ce bouton lance cette relecture complète avec les contrôles, maintenant.",
    );
    expect(FULL_CHECK.toast).toBe("Vérification complète demandée : elle passe avec les contrôles lancés maintenant.");
    expect(fullCheckErrorCode("advance check refused: already_requested")).toBe("full_check_already_requested");
    expect(errorText("full_check_already_requested")).toBe(
      "Une vérification complète est déjà demandée : elle passe avec les prochains contrôles.",
    );
  });
  it("(review round 1, CC-3) words a lock wait of the request as checks in progress", () => {
    expect(fullCheckErrorCode("canceling statement due to lock timeout")).toBe("full_check_busy");
    expect(fullCheckErrorCode("could not obtain lock on row in relation")).toBe("full_check_busy");
    expect(errorText("full_check_busy")).toBe("Contrôles en cours : réessayez dans un instant.");
  });
});

describe("(review round 1, tests-ui-2) the refusal of a return while a run takes the advance back", () => {
  it("says what happens: not booked until that run is debited, then support", () => {
    const code = transferLineErrorCode({ code: "55000", message: "transfer line booking refused: advance_in_flight" });
    expect(code).toBe("advance_in_flight");
    expect(transferLineErrorText(code)).toBe(
      "L'avance liée à ce virement est en cours de récupération par un reversement validé : ce retour ne peut pas être comptabilisé tant que ce reversement n'est pas débité ; après son débit, prévenez le support.",
    );
    expect(transferLineErrorText(code)).not.toContain("se comptabilise après");
  });
});

describe("the run page's advances, per cause (plan §3.7, F5)", () => {
  const payout = (cause: string): RunPayout => ({
    transfers: [],
    payout_account_blocked: false,
    settled_on: null,
    settlement_minor: "0",
    commission_minor: "0",
    advances_recovered_minor: "0",
    advances: [{ cause, amount_minor: "5000", open_minor: "5000", created_on: "2026-11-12" }],
    unplanned: [],
    draft_unplanned: [],
  });
  it("words each cause with its recording date", () => {
    expect(runPayoutNotes(payout("remitted_reversal"), "EUR").map(plain)).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 : encaissement de ce reversement annulé ou repris (50,00 €)",
    ]);
    expect(runPayoutNotes(payout("payout_overrun"), "EUR").map(plain)).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 : reversement débité au-delà de ce qui restait dû (50,00 €)",
    ]);
    expect(runPayoutNotes(payout("double_payout"), "EUR").map(plain)).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 : virement exécuté hors reversement (50,00 €)",
    ]);
  });
  it("no longer says the recovery is not handled", () => {
    expect(runPayoutNotes(payout("payout_overrun"), "EUR").join(" ")).not.toContain("pas encore géré");
  });
});
