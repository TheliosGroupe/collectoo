import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { allocationErrorCode } from "./allocation";
import { CHECK_LABEL, checkLabel, debitErrorCode } from "./debits";
import {
  FULL_CHECK,
  coverErrorCode,
  coverPrompt,
  fullCheckErrorCode,
  parseAllocationRemitted,
  remittedHead,
  returnRemittedNote,
  reverseErrorCode,
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
  booked_on: "2026-11-03",
  amount_minor: "200000",
  paid_on: "2026-11-03",
  paid_how: "paid",
  paid_run_number: "RV-2026-000001",
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
  });
  it("says it per paid_how, never « versé » or « débité » for a set-off or a net nil", () => {
    expect(remittedHead(base)).toBe("Déjà reversé au client (reversement RV-2026-000001, débité le 03/11/2026).");
    expect(remittedHead({ ...base, paid_on: "2026-11-17", paid_run_number: "RV-2026-000004" })).toBe(
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
